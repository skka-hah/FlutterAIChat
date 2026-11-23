import 'dart:async';

import 'package:ai_chat/services/chat_backends/dsh/dsh_session_backend.dart';
import 'package:ai_chat/services/chat_backends/dsh/gateway_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const dshBackendId = 'dsh';

/// Debug connection supplied at runtime. The launch token is held in memory.
class DshDebugConnection {
  DshDebugConnection._(this.origin, this._token);

  /// Parses the launch URL supplied by the owner of the DSH host.
  factory DshDebugConnection.fromLaunchUrl(String launchUrl) {
    final uri = Uri.tryParse(launchUrl.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('Invalid DSH launch URL');
    }
    final tokens = uri.queryParametersAll['token'];
    if (tokens == null || tokens.length != 1 || tokens.single.isEmpty) {
      throw const FormatException('Missing DSH launch token');
    }
    return DshDebugConnection._(Uri.parse(uri.origin), tokens.single);
  }

  final Uri origin;
  final String _token;

  /// Whether applying these settings can keep the current connection.
  bool matches(DshDebugConnection? other) =>
      origin == other?.origin && _token == other?._token;
}

/// Whether this build can connect to a native DSH Gateway.
const dshDebugConnectionSupported = kDebugMode && !kIsWeb;

/// Runtime connection settings. These are intentionally excluded from storage.
final dshDebugConnectionProvider = StateProvider<DshDebugConnection?>(
  (ref) => null,
);

/// Chooses the backend for new conversations without changing the connection.
final dshDefaultForNewChatsProvider = StateProvider<bool>((ref) => false);

final _dshConnectionProvider =
    Provider<({DshTransport transport, DshSessionBackend backend})?>((ref) {
  if (!dshDebugConnectionSupported) return null;
  final config = ref.watch(dshDebugConnectionProvider);
  if (config == null) return null;
  final transport =
      DshGatewayTransport(origin: config.origin, token: config._token);
  final backend = DshSessionBackend(
    transport: transport,
    hostIdentity: config.origin.origin,
  );
  ref.onDispose(() => unawaited(backend.close()));
  return (transport: transport, backend: backend);
});

/// The configured DSH implementation and its owned transport.
final dshSessionBackendProvider = Provider<DshSessionBackend?>((ref) {
  return ref.watch(_dshConnectionProvider)?.backend;
});

/// Validates the current Gateway configuration with a read-only call.
final dshConnectionVerificationProvider =
    FutureProvider.autoDispose<void>((ref) async {
  final connection = ref.watch(_dshConnectionProvider);
  if (connection == null) throw DshTransportFailure.unavailable;
  final result = await connection.transport.call('session/list', {
    '_request': <String, Object?>{},
  });
  if (result['items'] is! List) throw DshTransportFailure.invalidProtocol;
});
