import 'dart:async';
import 'dart:convert';

import 'package:ai_chat/models/chat/runtime_streaming_preview_state.dart';
import 'package:ai_chat/models/chat/send_message_request.dart';
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/services/chat_backends/dsh/dsh_session_backend.dart';
import 'package:ai_chat/services/chat_backends/dsh/gateway_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('routes live output and interaction replies to their own session',
      (tester) async {
    final transport = _Transport();
    final backend =
        DshSessionBackend(transport: transport, hostIdentity: 'host');
    addTearDown(backend.close);
    final a = _session(1, 'a');
    final b = _session(2, 'b');
    final aView = _Presentation();
    final bView = _Presentation();
    backend.observeSession(a, aView);
    backend.observeSession(b, bView);

    transport.events.add({'type': 'ready', 'clientId': 'client-1'});
    transport.follow('a').add(_snapshot([]));
    transport.follow('b').add(_snapshot([]));
    await tester.pump();

    await backend.sendMessage(
      a,
      const SendMessageRequest(text: 'Input A'),
      aView,
      onTurnCompleted: () {},
    );
    await backend.sendMessage(
      b,
      const SendMessageRequest(text: 'Input B'),
      bView,
      onTurnCompleted: () {},
    );
    expect(transport.calls.map((call) => call.args['request']['sessionId']),
        ['a', 'b']);

    transport.follow('a')
      ..add(_turnStart(0))
      ..add(_message(1, 'Input A', user: true))
      ..add(_message(2, 'Answer A'));
    transport.follow('b')
      ..add(_turnStart(0))
      ..add(_message(1, 'Input B', user: true))
      ..add(_message(2, 'Answer B'));
    transport.events.add(_approval('approval-a', 'a'));
    transport.events.add(_question('question-b', 'b'));
    await tester.pump();

    expect(aView.messages.map((row) => row.text), ['Input A', 'Answer A']);
    expect(bView.messages.map((row) => row.text), ['Input B', 'Answer B']);
    final aApproval = aView.pending.single.reference;
    final bQuestion = bView.pending.single;
    expect(aApproval.appSessionId, a.appSessionId);
    expect(bQuestion.reference.appSessionId, b.appSessionId);
    expect(bQuestion.questions.single.options.single.label, 'Choice');
    expect(bView.state, ChatBackendExecutionState.awaitingInteraction);

    await backend.resolveInteraction(
      b,
      aApproval,
      action: 'allow-once',
      presentation: bView,
    );
    expect(transport.replies, isEmpty);
    await backend.resolveInteraction(
      a,
      aApproval,
      action: 'allow-once',
      presentation: aView,
    );
    await backend.resolveInteraction(
      b,
      bQuestion.reference,
      action: 'answer',
      payload: {
        'answers': [
          {
            'id': 'choice',
            'selected': ['Choice'],
          },
        ],
      },
      presentation: bView,
    );
    expect(transport.replies, [
      {
        'clientId': 'client-1',
        'eventId': 'approval-a',
        'outcome': {'kind': 'result', 'value': 'allowed-once'},
      },
      {
        'clientId': 'client-1',
        'eventId': 'question-b',
        'outcome': {
          'kind': 'result',
          'value': {
            'answers': [
              {
                'id': 'choice',
                'selected': ['Choice'],
              },
            ],
          },
        },
      },
    ]);
    expect(aView.pending, isEmpty);
    expect(bView.pending, isEmpty);

    transport.events.add(_approval('cancelled-a', 'a'));
    await tester.pump();
    final cancelled = aView.pending.single.reference;
    transport.events.add({'type': 'cancel', 'eventId': 'cancelled-a'});
    await tester.pump();
    await backend.resolveInteraction(
      a,
      cancelled,
      action: 'reject',
      presentation: aView,
    );
    expect(aView.pending, isEmpty);
    expect(transport.replies, hasLength(2));

    await backend.stop(a, aView);
    expect(transport.calls.last.endpoint, 'session/cancel');
    expect(transport.calls.last.args['request'], {'sessionId': 'a'});
    expect(bView.messages.last.text, 'Answer B');
  });

  test('fills a reconnect gap and deduplicates the snapshot overlap', () async {
    final transport = _Transport();
    final backend =
        DshSessionBackend(transport: transport, hostIdentity: 'host');
    addTearDown(backend.close);
    final session = _session(1, 'a');
    final view = _Presentation();
    backend.observeSession(session, view);
    final firstFollow = transport.follow('a');
    firstFollow.add(_snapshot([_message(0, 'First', user: true)]));
    await Future<void>.delayed(Duration.zero);
    expect(view.messages.map((row) => row.text), ['First']);

    final reopened = Completer<StreamController<DshJson>>();
    transport.followOpened = (id, stream) {
      if (id == 'a') reopened.complete(stream);
    };
    firstFollow.addError(DshTransportFailure.disconnected);
    final nextFollow =
        await reopened.future.timeout(const Duration(seconds: 5));
    expect(nextFollow, isNot(same(firstFollow)));

    transport.history.add({
      'cursor': 3,
      'hasMore': false,
      'records': [
        _message(0, 'First', user: true),
        _message(1, 'Recovered reply'),
        _message(2, 'Recovered input', user: true),
      ],
    });
    nextFollow
      ..add(_snapshot([_message(3, 'After reconnect')], hasMore: true))
      ..add(_message(3, 'Duplicate event'))
      ..add(_message(4, 'Live reply'));
    await Future<void>.delayed(Duration.zero);

    expect(transport.calls.single.endpoint, 'session/events');
    expect(transport.calls.single.args['request'], {
      'address': {'kind': 'session', 'sessionId': 'a'},
      'throughSeq': 3,
      'beforeSeq': 3,
      'maxMessages': 50,
    });
    expect(view.messages.map((row) => row.text), [
      'First',
      'Recovered reply',
      'Recovered input',
      'After reconnect',
      'Live reply',
    ]);
    expect(view.cursor, isNull);
  });

  test('continues a backwards page past records with no visible messages',
      () async {
    final transport = _Transport();
    final backend =
        DshSessionBackend(transport: transport, hostIdentity: 'host');
    addTearDown(backend.close);
    transport.history.addAll([
      {
        'cursor': 6,
        'hasMore': true,
        'records': [_turnStart(4)],
      },
      {
        'cursor': 6,
        'hasMore': false,
        'records': [_message(2, 'Older message', user: true)],
      },
    ]);

    final page = await backend.loadHistory(
      _session(1, 'a'),
      cursor: '6:5',
      limit: 20,
    );
    expect(page.messages.single.text, 'Older message');
    expect(page.nextCursor, isNull);
    expect(
      transport.calls.map((call) => call.args['request']['throughSeq']),
      [6, 6],
    );
    expect(
      transport.calls.map((call) => call.args['request']['beforeSeq']),
      [5, 4],
    );
  });
}

ChatBackendSession _session(int appId, String dshId) => ChatBackendSession(
      appSessionId: appId,
      backendId: DshSessionBackend.id,
      backendSessionId: jsonEncode(['host', dshId]),
    );

DshJson _snapshot(List<DshJson> records, {bool hasMore = false}) => {
      'type': 'snapshot',
      'cursor': records.isEmpty ? -1 : records.last['event']['seq'],
      'records': records,
      'hasMore': hasMore,
      'assistantStream': {'revision': 0},
    };

DshJson _turnStart(int sequence) => {
      'type': 'event',
      'event': {
        'seq': sequence,
        'time': 1700000000000 + sequence,
        'type': 'turn/start',
        'data': {'turn': 1},
      },
    };

DshJson _message(int sequence, String text, {bool user = false}) {
  final message = {
    'id': 'message-$sequence',
    if (user) 'source': {'kind': 'user'},
    'content': [
      {'type': 'text', 'text': text},
    ],
  };
  return {
    'type': 'event',
    'event': {
      'seq': sequence,
      'time': 1700000000000 + sequence,
      'surfaceOp': 'append',
      'type': user ? 'user/message' : 'assistant/message',
      'data': user ? message : {'turn': 1, 'step': 0, 'message': message},
    },
  };
}

DshJson _approval(String id, String session) => {
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': id,
      'agentId': session,
      'request': {'toolName': 'example'},
    };

DshJson _question(String id, String session) => {
      'type': 'waterfall',
      'event': 'user-questions/request',
      'eventId': id,
      'agentId': session,
      'request': {
        'questions': [
          {
            'id': 'choice',
            'question': 'Select a choice',
            'options': [
              {'label': 'Choice'},
            ],
          },
        ],
      },
    };

final class _Transport implements DshTransport {
  final events = StreamController<DshJson>();
  final _follows = <String, StreamController<DshJson>>{};
  final _followStreams = <StreamController<DshJson>>[];
  final calls = <({String endpoint, DshJson args})>[];
  final history = <DshJson>[];
  void Function(String id, StreamController<DshJson> stream)? followOpened;

  StreamController<DshJson> follow(String id) => _follows[id]!;

  List<DshJson> get replies => [
        for (final call in calls)
          if (call.endpoint == r'$events/result') call.args,
      ];

  @override
  Future<DshJson> call(String endpoint, DshJson args) async {
    calls.add((endpoint: endpoint, args: args));
    return switch (endpoint) {
      'session/prompt' || 'session/cancel' => {'accepted': true},
      'session/events' => history.removeAt(0),
      r'$events/result' => {},
      _ => throw StateError('Unexpected test endpoint'),
    };
  }

  @override
  Stream<DshJson> open(String endpoint, DshJson args) {
    if (endpoint == r'$events') return events.stream;
    if (endpoint != 'session/follow') {
      throw StateError('Unexpected test stream');
    }
    final id = args['request']['address']['sessionId'] as String;
    final stream = StreamController<DshJson>();
    _follows[id] = stream;
    _followStreams.add(stream);
    followOpened?.call(id, stream);
    return stream.stream;
  }

  @override
  Future<void> close() async {
    if (events.hasListener || _followStreams.isNotEmpty) {
      await events.close();
    }
    for (final stream in _followStreams) {
      await stream.close();
    }
  }
}

final class _Presentation implements ChatBackendPresentationSink {
  final messages = <ChatMessage>[];
  List<ChatBackendPendingInteraction> pending = [];
  ChatBackendExecutionState? state;
  String? cursor;

  @override
  void addMessage(ChatMessage message) => messages.add(message);

  @override
  void replaceMessage(ChatMessage message) {
    messages[messages.indexWhere((row) => row.id == message.id)] = message;
  }

  @override
  void replaceHistory(ChatBackendHistoryPage page) {
    messages
      ..clear()
      ..addAll(page.messages);
    cursor = page.nextCursor;
  }

  @override
  void setExecutionState(ChatBackendExecutionState state,
      {String? statusText}) {
    this.state = state;
  }

  @override
  void setPendingInteractions(
      List<ChatBackendPendingInteraction> interactions) {
    pending = interactions;
  }

  @override
  void setStreamingPreview(RuntimeStreamingPreviewState preview) {}
}
