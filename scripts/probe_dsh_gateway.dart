import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _timeout = Duration(seconds: 15);

typedef Json = Map<String, dynamic>;

Json _object(Object? value) {
  if (value is! Json) throw const FormatException('Expected a JSON object');
  return value;
}

String _uuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// Keep the launch token out of the command line and suppress host payloads.
Future<void> main() async {
  final url = Uri.tryParse(Platform.environment['DSH_PROBE_ORIGIN'] ?? '');
  final token = Platform.environment['DSH_PROBE_TOKEN'];
  if (url == null ||
      !{'http', 'https'}.contains(url.scheme) ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      (url.path.isNotEmpty && url.path != '/') ||
      url.hasQuery ||
      url.hasFragment ||
      token == null ||
      token.isEmpty) {
    stderr.writeln(
        'Set DSH_PROBE_ORIGIN and DSH_PROBE_TOKEN. Use an origin URL.');
    exitCode = 2;
    return;
  }

  final http = HttpClient()..connectionTimeout = _timeout;
  WebSocket? socket;
  StreamIterator<dynamic>? frames;
  var stage = 'token exchange';
  try {
    final connect = await http.getUrl(url.replace(
      path: '/connect',
      queryParameters: {'token': token, 'interactions': 'answer'},
    ));
    connect.followRedirects = false;
    final exchange = await connect.close().timeout(_timeout);
    await exchange.drain<void>().timeout(_timeout);
    if (exchange.statusCode != 302 || exchange.cookies.length != 1) {
      throw StateError('Unexpected exchange response');
    }
    final sessionCookie = exchange.cookies.single;
    final cookie = '${sessionCookie.name}=${sessionCookie.value}';

    stage = 'authenticated WebSocket';
    final mux = url.replace(
      scheme: url.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/remote.mux',
    );
    final ws = await WebSocket.connect(
      mux.toString(),
      headers: {'Cookie': cookie, 'Origin': url.origin},
      customClient: http,
    ).timeout(_timeout);
    socket = ws;
    final incoming = StreamIterator(ws);
    frames = incoming;

    Future<Json> nextItem(String streamId,
        [Duration timeout = _timeout]) async {
      final watch = Stopwatch()..start();
      while (await incoming.moveNext().timeout(timeout - watch.elapsed)) {
        final frame = _object(jsonDecode(incoming.current as String));
        if (frame['streamId'] != streamId) continue;
        if (frame['type'] != 'item') throw StateError('Stream did not open');
        return _object(frame['value']);
      }
      throw StateError('Gateway disconnected');
    }

    Future<Json> firstItem(String streamId, String endpoint, Json args) {
      ws.add(jsonEncode({
        'type': 'open',
        'streamId': streamId,
        'endpoint': endpoint,
        'payload': {'args': args},
      }));
      return nextItem(streamId);
    }

    Future<Json> call(String endpoint, Json request) async {
      final rpcId = _uuid();
      final req = await http.postUrl(url.replace(path: '/api/$endpoint'));
      req.followRedirects = false;
      req.headers
        ..contentType = ContentType.json
        ..set('Cookie', cookie)
        ..set('Origin', url.origin);
      req.write(jsonEncode({
        'type': 'client-request',
        'rpcId': rpcId,
        'method': endpoint,
        'payload': {
          'args': {'request': request}
        },
      }));
      final response = await req.close().timeout(_timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode != 200) throw StateError('RPC HTTP failure');
      final envelope = _object(jsonDecode(body));
      final result = _object(envelope['result']);
      if (envelope['type'] != 'server-response' ||
          envelope['rpcId'] != rpcId ||
          result['ok'] != true) {
        throw StateError('RPC rejected');
      }
      return _object(result['value']);
    }

    stage = 'forwarded event readiness';
    final ready = await firstItem('events', r'$events', {});
    if (ready['type'] != 'ready' || ready['clientId'] is! String) {
      throw StateError('Missing event readiness');
    }
    stdout.writeln('PASS token exchange, WebSocket and event readiness');

    stage = 'session creation';
    final created = await call('session/create', {});
    final sessionId = created['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('Missing session identity');
    }
    final address = {'kind': 'session', 'sessionId': sessionId};
    stage = 'session snapshot';
    final snapshot = await firstItem('follow', 'session/follow', {
      'request': {'address': address, 'assistantStream': true},
    });
    if (snapshot['type'] != 'snapshot' ||
        snapshot['cursor'] is! int ||
        snapshot['assistantStream'] is! Json) {
      throw StateError('Missing opening snapshot');
    }

    stage = 'session history';
    final history = await call('session/events', {
      'address': address,
      'throughSeq': snapshot['cursor'],
    });
    if (history['cursor'] != snapshot['cursor'] ||
        history['records'] is! List) {
      throw StateError('History did not match snapshot cut');
    }
    stdout.writeln('PASS session creation, opening snapshot and history');

    final mode = Platform.environment['DSH_PROBE_MODE'];
    if (mode == 'reply' || mode == 'stop') {
      stage = 'prompt admission';
      final receipt = await call('session/prompt', {
        'sessionId': sessionId,
        'requestId': _uuid(),
        'mode': 'queue',
        'content': [
          {
            'type': 'text',
            'text': mode == 'stop'
                ? 'Write a numbered list of 200 ordinary household objects.'
                : 'Reply with the single word OK. Do not use tools.',
          },
        ],
      });
      if (receipt['accepted'] != true) throw StateError('Prompt not accepted');
      stage = 'assistant stream and turn terminal';
      const timeout = Duration(seconds: 90);
      final watch = Stopwatch()..start();
      var receivedChunk = false;
      while (watch.elapsed < timeout) {
        final frame = await nextItem('follow', timeout - watch.elapsed);
        if (frame['type'] == 'assistant-stream' &&
            _object(frame['frame'])['type'] == 'chunk' &&
            !receivedChunk) {
          receivedChunk = true;
          if (mode == 'stop') {
            stage = 'turn cancellation';
            final cancellation = await call('session/cancel', {
              'sessionId': sessionId,
            });
            if (cancellation['accepted'] != true) {
              throw StateError('Cancellation not accepted');
            }
            stage = 'cancelled turn terminal';
          }
        }
        if (frame['type'] != 'event') continue;
        final event = _object(frame['event']);
        if (event['type'] != 'turn/end') continue;
        final reason = _object(_object(event['data'])['reason']);
        if (!receivedChunk ||
            reason['kind'] != (mode == 'stop' ? 'aborted' : 'completed')) {
          throw StateError('Unexpected turn terminal');
        }
        stage = 'done';
        break;
      }
      if (stage != 'done') throw TimeoutException('No turn terminal');
      stdout.writeln('PASS prompt, stream and $mode terminal');
    }
    ws.add(jsonEncode({'type': 'cancel', 'streamId': 'follow'}));
  } on Object {
    stderr.writeln('FAIL $stage. Details omitted to protect host data.');
    exitCode = 1;
  } finally {
    try {
      await socket?.close().timeout(_timeout);
    } on Object {
      http.close(force: true);
    } finally {
      await frames?.cancel();
      http.close(force: true);
    }
  }
}
