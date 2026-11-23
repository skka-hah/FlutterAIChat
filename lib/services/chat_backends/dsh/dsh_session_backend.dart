import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:ai_chat/models/chat/send_message_request.dart';
import 'package:ai_chat/models/chat_message.dart';

import '../chat_backend_contract.dart';
import 'dsh_projection.dart';
import 'gateway_transport.dart';

/// DSH owns the conversation journal, inbox, and interaction decisions.
final class DshSessionBackend
    implements
        ChatSessionBackend,
        ChatBackendSessionCreator,
        ChatBackendSessionObserver {
  DshSessionBackend(
      {required DshTransport transport, required String hostIdentity})
      : _transport = transport,
        _hostIdentity = hostIdentity;

  static const id = 'dsh';
  static const _retry = Duration(seconds: 2);
  final DshTransport _transport;
  final String _hostIdentity;
  final _sessions = <String, _ObservedSession>{};
  final _pending = <String, _Interaction>{};
  StreamSubscription<DshJson>? _events;
  Completer<void>? _ready;
  String? _eventClientId;
  Timer? _eventRetry;
  bool _closed = false;

  @override
  String get backendId => id;

  @override
  ChatBackendCapabilities capabilitiesFor(ChatBackendSession session) =>
      const ChatBackendCapabilities(
        canStop: true,
        canConfirmTools: true,
        canAnswerQuestions: true,
        canPaginateHistory: true,
        hasStreamingPreview: true,
      );

  @override
  Future<String> createSession() async {
    final result = await _call('create', const {});
    final sessionId = result['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw DshTransportFailure.invalidProtocol;
    }
    return jsonEncode([_hostIdentity, sessionId]);
  }

  String _sessionId(ChatBackendSession session) {
    final binding = session.backendSessionId;
    final Object? value;
    try {
      value = binding == null ? null : jsonDecode(binding);
    } on FormatException {
      throw DshTransportFailure.invalidProtocol;
    }
    if (session.backendId != id ||
        value is! List ||
        value.length != 2 ||
        value.first != _hostIdentity ||
        value.last is! String ||
        (value.last as String).isEmpty) {
      throw StateError('DSH session belongs to a different host');
    }
    return value.last as String;
  }

  DshJson _address(String sessionId) => {
        'kind': 'session',
        'sessionId': sessionId,
      };

  Future<DshJson> _call(String method, DshJson request) =>
      _transport.call('session/$method', {'request': request});

  @override
  Future<ChatBackendHistoryPage> loadHistory(
    ChatBackendSession session, {
    String? cursor,
    required int limit,
  }) async =>
      (await _readHistory(_sessionId(session), cursor, limit)).page;

  @override
  Future<void> loadOlderHistory(
    ChatBackendSession session, {
    required String cursor,
    required int limit,
  }) async {
    final observed = _sessions[_sessionId(session)];
    if (observed == null || observed.historyCursor != cursor) return;
    final result = await _readHistory(observed.id, cursor, limit);
    if (!_isObserved(observed) || observed.historyCursor != cursor) return;
    observed.remember(result.records);
    observed.projection.prependHistory(result.records);
    _publishWindow(observed, result.page.nextCursor);
  }

  Future<({ChatBackendHistoryPage page, List<DshJson> records})> _readHistory(
    String sessionId,
    String? cursor,
    int limit,
  ) async {
    final parts = cursor?.split(':');
    var through = parts == null ? null : int.parse(parts.first);
    var before = parts == null ? null : int.parse(parts.last);
    final collected = <DshJson>[];
    while (true) {
      final page = await _call('events', {
        'address': _address(sessionId),
        if (through != null) 'throughSeq': through,
        if (before != null) 'beforeSeq': before,
        'maxMessages': limit,
      });
      through ??= page['cursor'] as int;
      final records = (page['records'] as List).cast<DshJson>();
      final next = _nextCursor(records, hasMore: page['hasMore'] == true);
      if (next != null && before != null && next >= before) {
        throw DshTransportFailure.invalidProtocol;
      }
      collected.addAll(records);
      final messages = DshProjection.projectHistory(collected);
      if (messages.isNotEmpty || next == null) {
        return (
          page: ChatBackendHistoryPage(
            messages: messages,
            nextCursor: next == null ? null : '$through:$next',
          ),
          records: collected,
        );
      }
      before = next;
    }
  }

  int? _nextCursor(List records, {required bool hasMore}) {
    if (!hasMore) return null;
    if (records.isEmpty) throw DshTransportFailure.invalidProtocol;
    return records.first['event']['seq'] as int;
  }

  @override
  void observeSession(
    ChatBackendSession session,
    ChatBackendPresentationSink presentation,
  ) {
    final sessionId = _sessionId(session);
    final existing = _sessions[sessionId];
    if (existing != null) {
      existing.presentation = presentation;
      _publishInteractions(existing);
      return;
    }
    final observed = _ObservedSession(session, sessionId, presentation);
    _sessions[sessionId] = observed;
    _openEvents();
    _follow(observed);
  }

  void _follow(_ObservedSession observed) {
    if (_closed || _sessions[observed.id] != observed) return;
    observed.subscription = _transport
        .open('session/follow', {
          'request': {
            'address': _address(observed.id),
            'assistantStream': true,
            'maxMessages': 20,
          },
        })
        .asyncMap((frame) => _applyFrame(observed, frame))
        .listen((_) {},
            onError: (Object _) => _reopenFollow(observed),
            onDone: () => _reopenFollow(observed),
            cancelOnError: true);
  }

  void _reopenFollow(_ObservedSession observed) {
    if (_closed || _sessions[observed.id] != observed) return;
    if (observed.reconnect?.isActive == true) return;
    observed.presentation.setExecutionState(
      ChatBackendExecutionState.idle,
      statusText: 'DSH reconnecting',
    );
    observed.reconnect = Timer(_retry, () => _follow(observed));
  }

  bool _isObserved(_ObservedSession session) =>
      !_closed && identical(_sessions[session.id], session);

  Future<void> _applyFrame(_ObservedSession session, DshJson frame) async {
    if (!_isObserved(session)) return;
    final snapshot = frame['type'] == 'snapshot';
    final durable = frame['type'] == 'event';
    final priorTerminal = session.projection.lastTerminal;
    final before = session.projection.cursor;
    if (snapshot) {
      await _fillReconnectGap(session, frame, before);
      if (!_isObserved(session)) return;
    }
    session.projection.applyFrame(frame);
    if (snapshot) {
      final records = (frame['records'] as List).cast<DshJson>();
      session.remember(records);
      session.projection.prependHistory(session.records.values);
      final first = session.projection.firstSequence;
      _publishWindow(session,
          first == null || first == 0 ? null : '${frame['cursor']}:$first');
    } else if (durable && session.projection.cursor > before) {
      session.remember([frame]);
      for (final message in session.projection.messages) {
        final previous = session.published[message.id];
        if (identical(previous, message)) continue;
        session.published[message.id!] = message;
        if (previous == null) {
          session.presentation.addMessage(message);
        } else {
          session.presentation.replaceMessage(message);
        }
      }
    }
    if (snapshot || durable || frame['type'] == 'assistant-stream') {
      session.presentation.setStreamingPreview(session.projection.preview);
    }
    final terminal = session.projection.lastTerminal;
    _publishInteractions(session,
        terminal: terminal != priorTerminal ? terminal?.reason : null);
  }

  void _publishWindow(_ObservedSession session, String? nextCursor) {
    final messages = session.projection.messages;
    session.historyCursor = nextCursor;
    session.presentation.replaceHistory(ChatBackendHistoryPage(
      messages: messages,
      nextCursor: nextCursor,
    ));
    session.published
      ..clear()
      ..addEntries(messages.map((message) => MapEntry(message.id!, message)));
  }

  Future<void> _fillReconnectGap(
    _ObservedSession session,
    DshJson snapshot,
    int previousCursor,
  ) async {
    if (snapshot['cursor'] is! int) throw DshTransportFailure.invalidProtocol;
    final through = snapshot['cursor'] as int;
    if (through < previousCursor) {
      session.records.clear();
      return;
    }
    final records = (snapshot['records'] as List).cast<DshJson>();
    var before = _nextCursor(records, hasMore: snapshot['hasMore'] == true);
    while (_isObserved(session) &&
        previousCursor >= 0 &&
        before != null &&
        before > previousCursor + 1) {
      final page = await _call('events', {
        'address': _address(session.id),
        'throughSeq': through,
        'beforeSeq': before,
        'maxMessages': 50,
      });
      final older = (page['records'] as List).cast<DshJson>();
      final next = _nextCursor(older, hasMore: page['hasMore'] == true);
      if (next != null && next >= before) {
        throw DshTransportFailure.invalidProtocol;
      }
      session.remember(older);
      before = next;
    }
  }

  @override
  Future<void> sendMessage(
    ChatBackendSession session,
    SendMessageRequest request,
    ChatBackendPresentationSink presentation, {
    required void Function() onTurnCompleted,
  }) async {
    final text = request.text;
    if (text.trim().isEmpty ||
        request.attachments.isNotEmpty ||
        request.additionalStartMessages.isNotEmpty) {
      throw ArgumentError('DSH currently accepts a single text input');
    }
    final sessionId = _sessionId(session);
    observeSession(session, presentation);
    final observed = _sessions[sessionId]!;
    final ready = _ready;
    if (ready != null) await ready.future.timeout(const Duration(seconds: 15));
    final requestId = observed.requests.putIfAbsent(text, _newRequestId);
    final receipt = await _call('prompt', {
      'sessionId': sessionId,
      'requestId': requestId,
      'mode': 'queue',
      'content': [
        {'type': 'text', 'text': text}
      ],
    });
    if (receipt['accepted'] != true) throw DshTransportFailure.invalidProtocol;
    observed.requests.remove(text);
  }

  @override
  Future<void> stop(ChatBackendSession session,
      ChatBackendPresentationSink presentation) async {
    final receipt = await _call('cancel', {'sessionId': _sessionId(session)});
    if (receipt['accepted'] != true) throw DshTransportFailure.invalidProtocol;
  }

  @override
  Future<void> deleteSession(ChatBackendSession session) async {
    final sessionId = _sessionId(session);
    final observed = _sessions.remove(sessionId);
    observed?.reconnect?.cancel();
    await observed?.subscription?.cancel();
    final abandoned =
        _pending.values.where((entry) => entry.sessionId == sessionId).toList();
    for (final entry in abandoned) {
      _pending.remove(entry.eventId);
      unawaited(
          _reply(entry.eventId, {'kind': 'next'}).catchError((Object _) {}));
    }
  }

  void _openEvents() {
    if (_closed || _events != null) return;
    _ready ??= Completer<void>();
    _events = _transport.open(r'$events', {}).listen(
      _eventFrame,
      onError: (Object _) => _reopenEvents(),
      onDone: _reopenEvents,
      cancelOnError: true,
    );
  }

  void _reopenEvents() {
    _events = null;
    _eventClientId = null;
    _pending.clear();
    for (final session in _sessions.values) {
      _publishInteractions(session);
    }
    if (_closed || _eventRetry?.isActive == true) return;
    _eventRetry = Timer(_retry, _openEvents);
  }

  void _eventFrame(DshJson frame) {
    final eventId = frame['eventId'];
    if (frame['type'] == 'ready' && frame['clientId'] is String) {
      _eventClientId = frame['clientId'] as String;
      _ready?.complete();
      _ready = null;
      return;
    }
    if (eventId is! String) return;
    if (frame['type'] == 'cancel') {
      final removed = _pending.remove(eventId);
      final session = _sessions[removed?.sessionId];
      if (session != null) _publishInteractions(session);
      return;
    }
    if (frame['type'] != 'waterfall') return;
    final session = _sessions[frame['agentId']];
    final request = frame['request'];
    final isApproval = frame['event'] == 'approval/request';
    final isQuestion = frame['event'] == 'user-questions/request';
    if (session == null ||
        request is! DshJson ||
        (!isApproval && !isQuestion) ||
        (isQuestion && request['questions'] is! List)) {
      unawaited(_reply(eventId, {'kind': 'next'}).catchError((Object _) {}));
      return;
    }
    final interaction = ChatBackendPendingInteraction(
      reference: ChatBackendInteractionReference(
        backendId: id,
        executionId: session.id,
        interactionId: eventId,
        kind: isApproval ? 'approval' : 'question',
        appSessionId: session.session.appSessionId,
        payload: {
          if (isApproval && request['toolName'] is String)
            'toolName': request['toolName'],
        },
      ),
      title: isApproval ? 'Tool approval' : 'Question',
      prompt: isApproval ? _approvalReason(request) : '',
      actions: isApproval ? const ['allow-once', 'reject'] : const ['cancel'],
      questions: isQuestion
          ? (request['questions'] as List)
              .whereType<DshJson>()
              .map(_question)
              .toList()
          : const [],
    );
    _pending[eventId] = _Interaction(session.id, eventId, interaction);
    _publishInteractions(session);
  }

  String _approvalReason(DshJson request) {
    final display = request['displayReason'];
    if (display is DshJson) {
      for (final key in ['zh-CN', 'zh', 'en']) {
        final value = display[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    }
    final reason = request['reason'];
    return reason is String ? reason.trim() : '';
  }

  ChatBackendQuestion _question(DshJson data) => ChatBackendQuestion(
        id: data['id'] as String,
        prompt: data['question'] as String,
        header: data['header'] as String?,
        detail: data['detail'] as String?,
        multiSelect: data['multiSelect'] == true,
        allowCustom: (data['intent'] as DshJson?)?['kind'] != 'approval',
        options: [
          for (final option
              in (data['options'] as List? ?? []).whereType<DshJson>())
            ChatBackendQuestionOption(
              label: option['label'] as String,
              description: option['description'] as String?,
            ),
        ],
      );

  void _publishInteractions(_ObservedSession session, {String? terminal}) {
    final interactions = [
      for (final entry in _pending.values)
        if (entry.sessionId == session.id) entry.presentation,
    ];
    session.presentation.setPendingInteractions(interactions);
    final state = interactions.isNotEmpty
        ? ChatBackendExecutionState.awaitingInteraction
        : session.projection.state;
    session.presentation.setExecutionState(
      state,
      statusText:
          terminal != null && terminal != 'completed' && terminal != 'aborted'
              ? 'DSH turn ended ($terminal)'
              : null,
    );
  }

  @override
  Future<void> resolveInteraction(
    ChatBackendSession session,
    ChatBackendInteractionReference interaction, {
    required String action,
    Map<String, Object?> payload = const {},
    required ChatBackendPresentationSink presentation,
  }) async {
    final sessionId = _sessionId(session);
    final entry = _pending[interaction.interactionId];
    if (entry == null ||
        entry.sessionId != sessionId ||
        interaction.appSessionId != session.appSessionId ||
        interaction.backendId != id ||
        entry.responding) {
      return;
    }
    final DshJson outcome;
    if (entry.presentation.reference.kind == 'approval') {
      if (action != 'allow-once' && action != 'reject') return;
      outcome = {
        'kind': 'result',
        'value': action == 'allow-once' ? 'allowed-once' : 'rejected'
      };
    } else if (action == 'answer' && payload['answers'] is List) {
      outcome = {
        'kind': 'result',
        'value': {'answers': payload['answers']}
      };
    } else if (action == 'cancel') {
      outcome = {
        'kind': 'rejected',
        'error': {
          'name': 'Error',
          'message': 'Question dismissed',
          'code': 'ASK_CANCELLED'
        }
      };
    } else {
      return;
    }
    entry.responding = true;
    try {
      await _reply(entry.eventId, outcome);
    } finally {
      entry.responding = false;
    }
    if (_pending[entry.eventId] == entry) _pending.remove(entry.eventId);
    final observed = _sessions[sessionId];
    if (observed != null) _publishInteractions(observed);
  }

  Future<void> _reply(String eventId, DshJson outcome) async {
    final clientId = _eventClientId;
    if (clientId == null) throw DshTransportFailure.disconnected;
    await _transport.call(r'$events/result', {
      'clientId': clientId,
      'eventId': eventId,
      'outcome': outcome,
    });
  }

  /// Releases the shared connection and all per-session subscriptions.
  Future<void> close() async {
    _closed = true;
    _eventRetry?.cancel();
    await _events?.cancel();
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _pending.clear();
    for (final session in sessions) {
      session.reconnect?.cancel();
      await session.subscription?.cancel();
    }
    await _transport.close();
  }
}

class _ObservedSession {
  _ObservedSession(this.session, this.id, this.presentation);

  final ChatBackendSession session;
  final String id;
  ChatBackendPresentationSink presentation;
  late final projection = DshProjection(sessionId: id);
  final published = <int, ChatMessage>{};
  final records = <int, DshJson>{};
  String? historyCursor;
  final requests = <String, String>{};
  StreamSubscription<void>? subscription;
  Timer? reconnect;

  void remember(Iterable<DshJson> frames) {
    for (final frame in frames) {
      final event = frame['event'];
      if (event is DshJson && event['seq'] is int) {
        records[event['seq'] as int] = frame;
      }
    }
  }
}

class _Interaction {
  _Interaction(this.sessionId, this.eventId, this.presentation);

  final String sessionId;
  final String eventId;
  final ChatBackendPendingInteraction presentation;
  bool responding = false;
}

String _newRequestId() {
  final random = Random.secure();
  return List.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
