import 'dart:collection';
import 'dart:convert';

import 'package:ai_chat/models/chat/runtime_streaming_preview_state.dart';
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/interaction/ask_user_question_response.dart';
import 'package:ai_chat/models/llm/streaming_message_event.dart';
import 'package:ai_chat/models/response/message_content_type.dart';
import 'package:ai_chat/models/tool/tool_invocation.dart';
import 'package:ai_chat/models/tool/tool_result.dart';

import '../chat_backend_contract.dart';

/// One session's durable journal and transient assistant preview.
class DshProjection {
  DshProjection({this.sessionId = ''});

  final String sessionId;
  final _records = SplayTreeMap<int, Map<String, dynamic>>();
  final _messages = SplayTreeMap<int, ChatMessage>();
  final _toolCalls = <(Object?, Object?, String), int>{};
  final _runningTools = <(Object?, Object?, String)>{};
  int _cursor = -1;
  int _revision = -1;
  _AssistantAttempt? _attempt;

  /// Latest durable sequence covered by the live subscription.
  int get cursor => _cursor;

  /// Earliest loaded sequence, including events that have no visible row.
  int? get firstSequence => _records.firstKey();

  /// Latest active turn, if its end is absent.
  int? activeTurn;

  /// Latest durable turn outcome, independent of connection state.
  ({int turn, String reason, int sequence})? lastTerminal;

  /// Visible activity classified from committed tool events and live frames.
  ChatBackendExecutionState get state {
    final attempt = _attempt;
    if (attempt != null && !attempt.settled) {
      return ChatBackendExecutionState.streaming;
    }
    if (_runningTools.isNotEmpty) return ChatBackendExecutionState.executing;
    return activeTurn == null
        ? ChatBackendExecutionState.idle
        : ChatBackendExecutionState.preparing;
  }

  List<ChatMessage> get messages => List.unmodifiable(_messages.values);

  RuntimeStreamingPreviewState get preview {
    final attempt = _attempt;
    if (attempt == null || attempt.settled || attempt.blocks.isEmpty) {
      return const RuntimeStreamingPreviewState();
    }
    return RuntimeStreamingPreviewState(messages: [
      RuntimeStreamingPreviewMessage(
        messageId: 'dsh:$sessionId:${attempt.id}',
        responseId: attempt.id,
        createdAt: attempt.blocks.values.first.createdAt,
        updatedAt: attempt.updatedAt,
        blocks: List.unmodifiable(attempt.blocks.values),
      ),
    ]);
  }

  /// Replaces the live window and restores the current assistant attempt.
  void replaceSnapshot(Map<String, dynamic> snapshot) {
    _records.clear();
    _appendRecords(snapshot['records']);
    _cursor = _requiredInt(snapshot, 'cursor');
    _rebuild();
    final stream = _map(snapshot['assistantStream']);
    _revision = stream == null ? -1 : _requiredInt(stream, 'revision');
    final opening = _map(stream?['activeAttempt']);
    _attempt = opening == null ? null : _AssistantAttempt.fromBaseline(opening);
    final attempt = _attempt;
    if (attempt != null) {
      for (final event in _records.values) {
        if (_settlesAttempt(event, attempt)) {
          attempt.settled = true;
        }
      }
    }
  }

  /// Adds older durable records without changing the live cursor or preview.
  void prependHistory(Iterable<Object?> records) {
    _appendRecords(records);
    _rebuild();
  }

  /// Projects standalone history without changing the live window.
  static List<ChatMessage> projectHistory(Iterable<Object?> records) {
    final projection = DshProjection();
    projection.prependHistory(records);
    return projection.messages;
  }

  /// Applies one frame after a snapshot. Gaps require a new snapshot.
  void applyFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case 'snapshot':
        replaceSnapshot(frame);
      case 'event':
        final event = _requiredMap(frame, 'event');
        final seq = _requiredInt(event, 'seq');
        if (seq <= _cursor) return;
        if (seq != _cursor + 1) {
          throw const FormatException('DSH durable sequence gap');
        }
        _cursor = seq;
        _records[seq] = event;
        _projectEvent(event);
        final attempt = _attempt;
        if (attempt != null && _settlesAttempt(event, attempt)) {
          attempt.settled = true;
        }
        if (event['type'] == 'turn/end') _attempt = null;
      case 'assistant-stream':
        _applyAssistant(_requiredMap(frame, 'frame'));
    }
  }

  static bool _settlesAttempt(
      Map<String, dynamic> event, _AssistantAttempt attempt) {
    final type = event['type'];
    final data = _map(event['data']);
    return (type == 'assistant/message' || type == 'assistant/attempt') &&
        _requiredInt(event, 'seq') > attempt.startedAfterSeq &&
        data?['turn'] == attempt.turn &&
        data?['step'] == attempt.step;
  }

  void _appendRecords(Object? records) {
    if (records is! Iterable) {
      throw const FormatException('Expected DSH history records');
    }
    for (final record in records) {
      final wrapper = _map(record);
      if (wrapper == null || wrapper['type'] != 'event') continue;
      final event = _requiredMap(wrapper, 'event');
      final seq = _requiredInt(event, 'seq');
      _records.putIfAbsent(seq, () => event);
    }
  }

  void _rebuild() {
    _messages.clear();
    _toolCalls.clear();
    _runningTools.clear();
    activeTurn = null;
    lastTerminal = null;
    for (final event in _records.values) {
      _projectEvent(event);
    }
  }

  void _projectEvent(Map<String, dynamic> event) {
    final data = _map(event['data']);
    if (data == null) return;
    final seq = _requiredInt(event, 'seq');
    final time = _time(event['time']);
    switch (event['type']) {
      case 'turn/start':
        activeTurn = _requiredInt(data, 'turn');
      case 'turn/end':
        final turn = _requiredInt(data, 'turn');
        if (activeTurn == turn) activeTurn = null;
        _runningTools.removeWhere((call) => call.$1 == turn);
        final reason = _map(data['reason'])?['kind'];
        if (reason is String) {
          lastTerminal = (turn: turn, reason: reason, sequence: seq);
        }
      case 'user/message':
        if (event['surfaceOp'] != 'append') return;
        final source = _map(data['source']);
        if (source?['kind'] != 'user') return;
        final value = _content(data['content'], 'text');
        if (value.isEmpty) return;
        _messages[seq] = ChatMessage(
          id: seq + 1,
          role: MessageRole.user,
          timestamp: time,
          status: MessageStatus.completed,
          text: value,
          payloadJson: {
            if (data['id'] is String) 'dshMessageId': data['id'],
            if (source?['rpcId'] is String) 'dshRequestId': source?['rpcId'],
          },
        );
      case 'assistant/message':
        if (event['surfaceOp'] != 'append') return;
        final message = _requiredMap(data, 'message');
        final content = message['content'];
        final answer = _content(content, 'text');
        final reasoning = _content(content, 'reasoning');
        if (answer.isEmpty && reasoning.isEmpty) return;
        _messages[seq] = ChatMessage(
          id: seq + 1,
          role: MessageRole.assistant,
          timestamp: time,
          status: data['interrupted'] == true
              ? MessageStatus.interrupted
              : MessageStatus.completed,
          text: answer,
          reasoningContent: reasoning.isEmpty ? null : reasoning,
          payloadJson: {
            if (message['id'] is String) 'dshMessageId': message['id'],
          },
        );
      case 'tool/call':
        final id = data['callId'];
        final name = data['name'];
        if (id is! String || name is! String || name.isEmpty) return;
        final invocation = ToolInvocation(
          toolName: name,
          arguments: _toolArguments(data['arguments']),
          status: ToolInvocationStatus.running,
          summary: name,
          requiresConfirmation: false,
          providerCallId: id,
        );
        final call = (data['turn'], data['step'], id);
        _toolCalls[call] = seq;
        _runningTools.add(call);
        _messages[seq] = ChatMessage(
          id: seq + 1,
          text: name,
          role: MessageRole.assistant,
          timestamp: time,
          contentType: MessageContentType.toolInvocation,
          payloadJson: invocation.toJson(),
        );
      case 'tool/result':
        if (event['surfaceOp'] != 'append') return;
        final message = _requiredMap(data, 'message');
        final source = _map(message['source']);
        final id = source?['callId'];
        if (id is! String) return;
        final call = (data['turn'], data['step'], id);
        final callSeq = _toolCalls[call];
        _runningTools.remove(call);
        final invocation = _messages[callSeq];
        final name =
            invocation?.payloadJson?['toolName'] as String? ?? 'DSH tool';
        final value = _content(message['content'], 'text');
        final key = callSeq ?? seq;
        if (name == 'ask_user_question' && message['isError'] != true) {
          final answers = _questionAnswers(value);
          if (answers != null) {
            final arguments = _map(invocation?.payloadJson?['arguments']);
            _messages[key] = ChatMessage(
              id: key + 1,
              text: '已提交答案',
              role: MessageRole.assistant,
              timestamp: invocation?.timestamp ?? time,
              status: MessageStatus.completed,
              contentType: MessageContentType.askUserQuestionResult,
              payloadJson: {
                'submittedAnswers': answers.toJson(),
                if (arguments?['questions'] is List)
                  'questions': arguments!['questions'],
              },
            );
            return;
          }
        }
        final result = ToolResult(
          toolName: name,
          status: message['isError'] == true
              ? ToolExecutionStatus.failure
              : ToolExecutionStatus.success,
          summary: value.isEmpty ? name : value,
          providerCallId: id,
        );
        _messages[key] = ChatMessage(
          id: key + 1,
          text: result.summary,
          role: MessageRole.assistant,
          timestamp: invocation?.timestamp ?? time,
          status: MessageStatus.completed,
          contentType: MessageContentType.toolResult,
          payloadJson: result.toJson(),
        );
    }
  }

  void _applyAssistant(Map<String, dynamic> frame) {
    final revision = _requiredInt(frame, 'revision');
    if (revision <= _revision) return;
    if (_revision >= 0 && revision != _revision + 1) {
      throw const FormatException('DSH assistant revision gap');
    }
    _revision = revision;
    final id = frame['attemptId'];
    if (id is! String) throw const FormatException('Missing DSH attempt ID');
    if (frame['type'] == 'start') {
      _attempt = _AssistantAttempt(
        id,
        _requiredInt(frame, 'turn'),
        _requiredInt(frame, 'step'),
        _requiredInt(frame, 'startedAfterSeq'),
      );
      return;
    }
    final attempt = _attempt;
    if (attempt == null || attempt.id != id) return;
    final index = _requiredInt(frame, 'index');
    if (index != attempt.nextIndex) {
      throw const FormatException('DSH assistant chunk gap');
    }
    switch (frame['type']) {
      case 'chunk':
        attempt.nextIndex++;
        if (!attempt.settled) {
          attempt.addChunk(_requiredMap(frame, 'chunk'), _time(frame['time']));
        }
      case 'end':
        final outcome = _requiredMap(frame, 'outcome');
        if (outcome['kind'] == 'committed' &&
            _requiredInt(outcome, 'seq') > _cursor) {
          // Keep the preview until the durable settlement arrives.
          return;
        }
        _attempt = null;
    }
  }
}

class _AssistantAttempt {
  _AssistantAttempt(this.id, this.turn, this.step, this.startedAfterSeq);

  factory _AssistantAttempt.fromBaseline(Map<String, dynamic> opening) {
    final attempt = _AssistantAttempt(
      opening['attemptId'] as String,
      _requiredInt(opening, 'turn'),
      _requiredInt(opening, 'step'),
      _requiredInt(opening, 'startedAfterSeq'),
    );
    final stream = opening['stream'];
    if (stream is! List) {
      throw const FormatException('Missing DSH preview stream');
    }
    final count = _requiredInt(opening, 'nextIndex');
    for (final raw in stream) {
      if (attempt.nextIndex >= count) break;
      final record = _map(raw);
      if (record == null) continue;
      if (record['type'] == 'chunk') {
        attempt.addChunk(_requiredMap(record, 'chunk'), _time(record['time']));
        attempt.nextIndex++;
        continue;
      }
      final type = switch (record['type']) {
        'text-chunks' => 'text-delta',
        'reasoning-chunks' => 'reasoning-delta',
        'tool-call-chunks' => 'tool-call-delta',
        _ => throw const FormatException('Unknown DSH compact chunk record'),
      };
      final tool = type == 'tool-call-delta';
      final parts = record[tool ? 'args' : 'texts'];
      final deltas = record['dt'];
      if (parts is! List ||
          deltas is! List ||
          deltas.length != parts.length - 1) {
        throw const FormatException('Invalid DSH compact chunk record');
      }
      var time = _requiredInt(record, 'time0');
      for (var i = 0; i < parts.length && attempt.nextIndex < count; i++) {
        if (i > 0) time += deltas[i - 1] as int;
        attempt.addChunk({
          'type': type,
          'index': record['index'],
          if (tool) ...{
            'id': record['id'],
            'name': record['name'],
            'argumentsDelta': parts[i],
          } else
            'text': parts[i],
        }, _time(time));
        attempt.nextIndex++;
      }
    }
    if (attempt.nextIndex != count) {
      throw const FormatException('Incomplete DSH preview baseline');
    }
    return attempt;
  }

  final String id;
  final int turn;
  final int step;
  final int startedAfterSeq;
  final blocks = SplayTreeMap<int, RuntimeStreamingPreviewBlock>();
  int nextIndex = 0;
  bool settled = false;
  DateTime updatedAt = _time(0);

  void addChunk(Map<String, dynamic> chunk, DateTime time) {
    final index = chunk['index'];
    if (index is! int) return;
    final type = chunk['type'];
    final end = type == 'block-end' ? _map(chunk['block']) : null;
    final kind = switch (type) {
      'block-start' => chunk['blockType'],
      'block-end' => end?['type'],
      'text-delta' => 'text',
      'reasoning-delta' => 'reasoning',
      'tool-call-delta' => 'tool-call',
      _ => null,
    };
    final blockType = switch (kind) {
      'text' => StreamingContentBlockType.text,
      'reasoning' => StreamingContentBlockType.thinking,
      'tool-call' => StreamingContentBlockType.toolUse,
      _ => null,
    };
    if (blockType == null) return;
    final previous = blocks[index];
    final tool = blockType == StreamingContentBlockType.toolUse;
    final text = (type == 'block-end'
        ? (end?[tool ? 'arguments' : 'text'])
        : chunk[tool ? 'argumentsDelta' : 'text']) as String?;
    blocks[index] = RuntimeStreamingPreviewBlock(
      contentBlockId: '$id:$index',
      blockType: blockType,
      createdAt: previous?.createdAt ?? time,
      updatedAt: time,
      isCompleted: type == 'block-end',
      text: type == 'block-end'
          ? text ?? previous?.text ?? ''
          : '${previous?.text ?? ''}${text ?? ''}',
      toolUseId: (end?['id'] ?? chunk['id']) as String? ?? previous?.toolUseId,
      toolName:
          (end?['name'] ?? chunk['name']) as String? ?? previous?.toolName,
    );
    updatedAt = time;
  }
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;

Map<String, dynamic> _requiredMap(Map<String, dynamic> value, String key) =>
    _map(value[key]) ?? (throw FormatException('Missing DSH object: $key'));

int _requiredInt(Map<String, dynamic> value, String key) {
  final result = value[key];
  if (result is! int) throw FormatException('Missing DSH integer: $key');
  return result;
}

DateTime _time(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value is int ? value : 0);

String _content(Object? value, String type) {
  if (value is! List) return '';
  return value
      .map(_map)
      .where((block) => block?['type'] == type)
      .map((block) => block?['text'])
      .whereType<String>()
      .join();
}

Map<String, dynamic> _toolArguments(Object? raw) {
  if (raw is! String) return const {};
  try {
    return _map(jsonDecode(raw)) ?? const {};
  } on FormatException {
    return const {};
  }
}

AskUserQuestionResponse? _questionAnswers(String text) {
  final answers = _toolArguments(text)['answers'];
  if (answers is! List || answers.isEmpty) return null;
  final selectedById = <String, List<String>>{};
  final customById = <String, String>{};
  final textById = <String, String>{};
  for (final value in answers) {
    final answer = _map(value);
    final id = answer?['id'];
    final selected = answer?['selected'];
    final custom = answer?['custom'];
    if (id is! String ||
        id.isEmpty ||
        selected is! List ||
        selected.any((value) => value is! String) ||
        (custom != null && custom is! String) ||
        textById.containsKey(id)) {
      return null;
    }
    selectedById[id] = selected.cast<String>();
    if (custom is String && custom.isNotEmpty) customById[id] = custom;
    textById[id] = [
      ...selectedById[id]!,
      if (customById.containsKey(id)) customById[id]!,
    ].join(', ');
  }
  return AskUserQuestionResponse(
    answersByQuestionId: textById,
    selectedOptionLabelsByQuestionId: selectedById,
    freeTextAnswersByQuestionId: customById,
  );
}
