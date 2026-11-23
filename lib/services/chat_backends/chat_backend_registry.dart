import 'chat_backend_contract.dart';

/// Resolves one immutable backend implementation for each session backend ID.
class ChatBackendRegistry {
  ChatBackendRegistry(Iterable<ChatSessionBackend> backends)
      : _backends = _buildIndex(backends);

  final Map<String, ChatSessionBackend> _backends;

  static Map<String, ChatSessionBackend> _buildIndex(
    Iterable<ChatSessionBackend> backends,
  ) {
    final indexed = <String, ChatSessionBackend>{};
    for (final backend in backends) {
      if (indexed.containsKey(backend.backendId)) {
        throw ArgumentError('chat_backend_id_must_be_unique');
      }
      indexed[backend.backendId] = backend;
    }
    return Map.unmodifiable(indexed);
  }

  ChatSessionBackend resolve(String backendId) {
    final backend = _backends[backendId];
    if (backend == null) {
      throw StateError('chat_backend_not_registered:$backendId');
    }
    return backend;
  }

  bool contains(String backendId) => _backends.containsKey(backendId);
}
