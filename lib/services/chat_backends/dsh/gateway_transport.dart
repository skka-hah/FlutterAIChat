import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Named arguments and JSON objects returned by DSH Gateway.
typedef DshJson = Map<String, dynamic>;

/// Command and subscription transport shared by DSH backend implementations.
abstract interface class DshTransport {
  /// Invokes one endpoint with its complete, named argument object.
  ///
  /// A missing or null result is represented by an empty map. Scalar results
  /// are represented by a map with a single `value` entry.
  Future<DshJson> call(String endpoint, DshJson args);

  /// Opens a subscription on the current connection generation. Reopen after
  /// a disconnect to read a new baseline.
  Stream<DshJson> open(String endpoint, DshJson args);

  /// Releases the connection and all subscriptions.
  Future<void> close();
}

/// An operation failed without exposing credentials, endpoint URLs or payloads.
enum DshTransportFailure implements Exception {
  closed,
  disconnected,
  unauthorized,
  unavailable,
  timedOut,
  rejected,
  invalidProtocol,
}

/// Native HTTP and WebSocket implementation of the DSH Web Gateway protocol.
final class DshGatewayTransport implements DshTransport {
  DshGatewayTransport({required Uri origin, required String token})
      : _origin = origin,
        _token = token {
    if (!{'http', 'https'}.contains(origin.scheme) ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        (origin.path.isNotEmpty && origin.path != '/') ||
        origin.hasQuery ||
        origin.hasFragment ||
        token.isEmpty) {
      throw ArgumentError('Expected a DSH origin and a launch token');
    }
  }

  static const _timeout = Duration(seconds: 15);
  static final _endpoint = RegExp(r'^[a-zA-Z0-9_$-]+(?:/[a-zA-Z0-9_$-]+)*$');

  final Uri _origin;
  final String _token;
  final _random = Random.secure();
  _GatewayConnection? _connection;
  Future<_GatewayConnection>? _connecting;
  HttpClient? _connectingClient;
  bool _closed = false;
  int _nextStreamId = 0;

  Future<_GatewayConnection> _requireConnection() async {
    if (_closed) throw DshTransportFailure.closed;
    final current = _connection;
    if (current != null) return current;
    final opening = _connecting;
    if (opening != null) return opening;

    final attempt = _connect();
    _connecting = attempt;
    try {
      return await attempt;
    } finally {
      _connecting = null;
    }
  }

  Future<_GatewayConnection> _connect() async {
    final http = HttpClient()..connectionTimeout = _timeout;
    _connectingClient = http;
    try {
      final req = await http.getUrl(_origin.replace(
        path: '/connect',
        queryParameters: {'token': _token, 'interactions': 'answer'},
      ));
      req.followRedirects = false;
      final res = await req.close().timeout(_timeout);
      await res.drain<void>().timeout(_timeout);
      if (res.statusCode == HttpStatus.unauthorized ||
          res.statusCode == HttpStatus.forbidden) {
        throw DshTransportFailure.unauthorized;
      }
      if (res.statusCode != HttpStatus.found || res.cookies.length != 1) {
        throw DshTransportFailure.invalidProtocol;
      }
      final cookie = res.cookies.single;
      final headers = {
        'Cookie': '${cookie.name}=${cookie.value}',
        'Origin': _origin.origin,
      };
      final mux = _origin.replace(
        scheme: _origin.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/remote.mux',
      );
      final socket = await WebSocket.connect(
        mux.toString(),
        headers: headers,
        customClient: http,
      ).timeout(_timeout);
      if (_closed) {
        await _closeSocket(socket);
        throw DshTransportFailure.closed;
      }

      final connection = _GatewayConnection(http, socket, headers);
      _connection = connection;
      socket.listen(
        (frame) => _receive(connection, frame),
        onError: (Object _) => unawaited(_drop(connection)),
        onDone: () => unawaited(_drop(connection)),
        cancelOnError: true,
      );
      return connection;
    } on DshTransportFailure {
      http.close(force: true);
      rethrow;
    } on TimeoutException {
      http.close(force: true);
      throw DshTransportFailure.timedOut;
    } on Object {
      http.close(force: true);
      throw _closed
          ? DshTransportFailure.closed
          : DshTransportFailure.unavailable;
    } finally {
      _connectingClient = null;
    }
  }

  @override
  Future<DshJson> call(String endpoint, DshJson args) async {
    _validateEndpoint(endpoint);
    final connection = await _requireConnection();
    final rpcId = _uuid();
    try {
      final req = await connection.http
          .postUrl(_origin.replace(path: '/api/$endpoint'))
          .timeout(_timeout);
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      connection.headers.forEach(req.headers.set);
      req.write(jsonEncode({
        'type': 'client-request',
        'rpcId': rpcId,
        'method': endpoint,
        'payload': {'args': args},
      }));
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>().timeout(_timeout);
        if (res.statusCode == HttpStatus.unauthorized) {
          unawaited(_drop(connection));
          throw DshTransportFailure.unauthorized;
        }
        if (res.statusCode == HttpStatus.forbidden) {
          throw DshTransportFailure.unauthorized;
        }
        throw DshTransportFailure.rejected;
      }
      final body = await res.transform(utf8.decoder).join().timeout(_timeout);
      final envelope = jsonDecode(body);
      if (envelope is! DshJson ||
          envelope['type'] != 'server-response' ||
          envelope['rpcId'] != rpcId) {
        throw DshTransportFailure.invalidProtocol;
      }
      final result = envelope['result'];
      if (result is! DshJson || result['ok'] is! bool) {
        throw DshTransportFailure.invalidProtocol;
      }
      if (result['ok'] != true) throw DshTransportFailure.rejected;
      _checkCurrent(connection);
      final value = result['value'];
      return switch (value) {
        null => <String, dynamic>{},
        DshJson value => value,
        _ => {'value': value},
      };
    } on DshTransportFailure {
      rethrow;
    } on FormatException {
      throw DshTransportFailure.invalidProtocol;
    } on TimeoutException {
      throw DshTransportFailure.timedOut;
    } on Object {
      _checkCurrent(connection);
      throw DshTransportFailure.unavailable;
    }
  }

  @override
  Stream<DshJson> open(String endpoint, DshJson args) {
    _GatewayConnection? connection;
    String? streamId;
    var cancelled = false;
    late StreamController<DshJson> controller;
    controller = StreamController<DshJson>(
      onListen: () async {
        try {
          _validateEndpoint(endpoint);
          final id = '${++_nextStreamId}';
          final encodedArgs = jsonEncode({
            'type': 'open',
            'streamId': id,
            'endpoint': endpoint,
            'payload': {'args': args},
          });
          final active = await _requireConnection();
          if (cancelled) return;
          _checkCurrent(active);
          connection = active;
          streamId = id;
          active.streams[id] = controller;
          active.socket.add(encodedArgs);
        } on Object catch (error) {
          connection?.streams.remove(streamId);
          if (cancelled) return;
          controller.addError(
            error is DshTransportFailure
                ? error
                : DshTransportFailure.unavailable,
          );
          unawaited(controller.close());
        }
      },
      onCancel: () {
        cancelled = true;
        final active = connection;
        final id = streamId;
        if (active == null || id == null || active.streams.remove(id) == null) {
          return;
        }
        try {
          active.socket.add(jsonEncode({'type': 'cancel', 'streamId': id}));
        } on Object {
          unawaited(_drop(active));
        }
      },
    );
    return controller.stream;
  }

  void _receive(_GatewayConnection connection, Object? raw) {
    if (!identical(_connection, connection)) return;
    try {
      final frame = raw is String ? jsonDecode(raw) : null;
      if (frame is! DshJson || frame['streamId'] is! String) {
        throw DshTransportFailure.invalidProtocol;
      }
      final id = frame['streamId'] as String;
      final controller = connection.streams[id];
      if (controller == null) return;
      switch (frame['type']) {
        case 'item' when frame['value'] is DshJson:
          controller.add(frame['value'] as DshJson);
        case 'end':
          connection.streams.remove(id);
          unawaited(controller.close());
        case 'error':
          connection.streams.remove(id);
          controller.addError(DshTransportFailure.rejected);
          unawaited(controller.close());
        default:
          throw DshTransportFailure.invalidProtocol;
      }
    } on Object {
      unawaited(_drop(connection, DshTransportFailure.invalidProtocol));
    }
  }

  void _validateEndpoint(String endpoint) {
    if (!_endpoint.hasMatch(endpoint)) {
      throw DshTransportFailure.invalidProtocol;
    }
  }

  void _checkCurrent(_GatewayConnection connection) {
    if (_closed) throw DshTransportFailure.closed;
    if (!identical(_connection, connection)) {
      throw DshTransportFailure.disconnected;
    }
  }

  Future<void> _drop(
    _GatewayConnection connection, [
    DshTransportFailure reason = DshTransportFailure.disconnected,
  ]) async {
    if (!identical(_connection, connection)) return;
    _connection = null;
    for (final stream in connection.streams.values) {
      stream.addError(reason);
      unawaited(stream.close());
    }
    connection.streams.clear();
    connection.http.close(force: true);
    await _closeSocket(connection.socket);
  }

  Future<void> _closeSocket(WebSocket socket) async {
    try {
      await socket.close().timeout(_timeout);
    } on Object {
      // The connection has already been retired.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connectingClient?.close(force: true);
    final connection = _connection;
    if (connection != null) {
      await _drop(connection, DshTransportFailure.closed);
    }
    try {
      await _connecting;
    } on DshTransportFailure {
      // A pending connection closes its own HTTP client.
    }
  }

  String _uuid() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

final class _GatewayConnection {
  _GatewayConnection(this.http, this.socket, this.headers);

  final HttpClient http;
  final WebSocket socket;
  final Map<String, String> headers;
  final streams = <String, StreamController<DshJson>>{};
}
