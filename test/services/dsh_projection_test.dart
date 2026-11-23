import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/response/message_content_type.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/services/chat_backends/dsh/dsh_projection.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Json = Map<String, dynamic>;

_Json _event(int seq, String type, _Json data, {String? surfaceOp}) => {
      'type': 'event',
      'event': {
        'type': type,
        'seq': seq,
        'time': 1700000000000 + seq,
        'data': data,
        if (surfaceOp != null) 'surfaceOp': surfaceOp,
      },
    };

_Json _snapshot(List<_Json> records, {_Json? attempt}) => {
      'type': 'snapshot',
      'cursor': records.isEmpty ? -1 : records.last['event']['seq'],
      'records': records,
      'assistantStream': {
        'revision': 4,
        if (attempt != null) 'activeAttempt': attempt,
      },
    };

_Json _transient(_Json frame) => {'type': 'assistant-stream', 'frame': frame};

void main() {
  test('reconnect resumes compact preview and durable settlement takes over',
      () {
    final projection = DshProjection(sessionId: 'session-1');
    final turnStart = _event(0, 'turn/start', {'turn': 1});
    projection.applyFrame(_snapshot([
      turnStart
    ], attempt: {
      'attemptId': 'attempt-1',
      'startedAfterSeq': 0,
      'turn': 1,
      'step': 0,
      'nextIndex': 2,
      'stream': [
        {
          'type': 'text-chunks',
          'time0': 1700000000000,
          'index': 0,
          'dt': [2],
          'texts': ['Hel', 'lo'],
        },
      ],
    }));
    expect(projection.preview.messages.single.blocks.single.text, 'Hello');
    expect(projection.state, ChatBackendExecutionState.streaming);

    final chunk = _transient({
      'type': 'chunk',
      'attemptId': 'attempt-1',
      'revision': 5,
      'index': 2,
      'time': 1700000000003,
      'chunk': {'type': 'text-delta', 'index': 0, 'text': '!'},
    });
    projection
      ..applyFrame(chunk)
      ..applyFrame(chunk);
    expect(projection.preview.messages.single.blocks.single.text, 'Hello!');

    final answer = _event(
        1,
        'assistant/message',
        {
          'turn': 1,
          'step': 0,
          'interrupted': true,
          'message': {
            'id': 'answer-1',
            'content': [
              {'type': 'text', 'text': 'Hello!'},
            ],
          },
        },
        surfaceOp: 'append');
    projection.applyFrame(answer);
    expect(projection.preview.isEmpty, isTrue);
    expect(projection.messages.single.status, MessageStatus.interrupted);
    expect(
      projection.messages.single.id,
      DshProjection.projectHistory([turnStart, answer]).single.id,
    );
    projection.applyFrame(_transient({
      'type': 'end',
      'attemptId': 'attempt-1',
      'revision': 6,
      'index': 3,
      'outcome': {
        'kind': 'committed',
        'eventType': 'assistant/message',
        'seq': 1
      },
    }));
    projection.applyFrame(_event(2, 'turn/end', {
      'turn': 1,
      'reason': {'kind': 'aborted'},
    }));
    expect(projection.state, ChatBackendExecutionState.idle);
    expect(projection.lastTerminal, (turn: 1, reason: 'aborted', sequence: 2));
  });

  test('structured question results replay as shared answer cards', () {
    final call = _event(2, 'tool/call', {
      'turn': 1,
      'step': 0,
      'callId': 'question-call',
      'name': 'ask_user_question',
      'arguments': '{"questions":[{"id":"color","question":"Choose a color"}]}',
    });
    final result = _event(
      3,
      'tool/result',
      {
        'turn': 1,
        'step': 0,
        'message': {
          'source': {'kind': 'tool', 'callId': 'question-call'},
          'content': [
            {
              'type': 'text',
              'text':
                  '{"answers":[{"id":"color","selected":["Blue"],"custom":"Navy"}]}',
            },
          ],
        },
      },
      surfaceOp: 'append',
    );
    final projection = DshProjection()..applyFrame(_snapshot([call]));
    final originalId = projection.messages.single.id;
    projection.applyFrame(result);
    final card = projection.messages.single;
    expect(card.id, originalId);
    expect(card.contentType, MessageContentType.askUserQuestionResult);
    expect(card.payloadJson?['questions'], [
      {'id': 'color', 'question': 'Choose a color'},
    ]);
    expect(card.payloadJson?['submittedAnswers']['answersByQuestionId'],
        {'color': 'Blue, Navy'});
    expect(DshProjection.projectHistory([call, result]).single.payloadJson,
        card.payloadJson);
  });

  test('tool results update the original row and ignore compacted replacements',
      () {
    final toolCall = _event(2, 'tool/call', {
      'turn': 1,
      'step': 0,
      'callId': 'call-1',
      'name': 'example',
      'arguments': '{}',
    });
    final user = _event(
        1,
        'user/message',
        {
          'id': 'user-1',
          'source': {'kind': 'user', 'rpcId': 'request-1'},
          'content': [
            {'type': 'text', 'text': 'Question'},
          ],
        },
        surfaceOp: 'append');
    final result = _event(
        3,
        'tool/result',
        {
          'turn': 1,
          'step': 0,
          'message': {
            'source': {'kind': 'tool', 'callId': 'call-1'},
            'content': [
              {'type': 'text', 'text': 'Result'},
            ],
          },
        },
        surfaceOp: 'append');
    final replacement = _event(4, 'user/message', {
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': 'Compacted'},
      ],
    });
    replacement['event']['surfaceOp'] = {
      'op': 'replace',
      'startSeq': 1,
      'endSeq': 1,
    };
    final projection = DshProjection()..applyFrame(_snapshot([user, toolCall]));
    final toolId = projection.messages.last.id;
    expect(projection.state, ChatBackendExecutionState.executing);

    projection
      ..applyFrame(result)
      ..applyFrame(replacement);
    expect(projection.messages.map((row) => row.text), ['Question', 'Result']);
    expect(projection.messages.last.id, toolId);
    expect(projection.messages.last.contentType, MessageContentType.toolResult);
    expect(
      DshProjection.projectHistory([user, toolCall, result, replacement])
          .map((row) => row.id),
      projection.messages.map((row) => row.id),
    );
  });
}
