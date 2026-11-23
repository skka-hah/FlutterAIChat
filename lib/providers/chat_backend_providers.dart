import 'package:ai_chat/models/chat_group.dart';
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/chat/runtime_streaming_preview_state.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_send_state_providers.dart';
import 'package:ai_chat/providers/chat_ui_providers.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Backend-neutral pending interactions for one session.
final chatBackendPendingInteractionsForSessionProvider =
    StateProvider.family<List<ChatBackendPendingInteraction>, int>(
        (ref, sessionId) {
  return const <ChatBackendPendingInteraction>[];
});

/// Incremented when a session is deleted so late backend events are ignored.
final chatBackendPresentationGenerationProvider =
    StateProvider.family<int, int>(
  (ref, sessionId) => 0,
);

final activeChatBackendPendingInteractionProvider =
    Provider<ChatBackendPendingInteraction?>((ref) {
  final sessionId = ref.watch(currentGroupProvider)?.id;
  if (sessionId == null) return null;
  final interactions =
      ref.watch(chatBackendPendingInteractionsForSessionProvider(sessionId));
  return interactions.isEmpty ? null : interactions.last;
});

ChatBackendSession _backendSessionFor(ChatGroup group) => ChatBackendSession(
      appSessionId: group.id!,
      backendId: group.backendId,
      backendSessionId: group.backendSessionId,
    );

final chatBackendPresentationSinkProvider =
    Provider.family<RiverpodChatBackendPresentationSink, ChatBackendSession>(
  (ref, session) => RiverpodChatBackendPresentationSink(ref, session),
);

/// Adapts backend output to the existing per-session timeline/send providers.
class RiverpodChatBackendPresentationSink
    implements ChatBackendPresentationSink {
  RiverpodChatBackendPresentationSink(this._ref, this.session)
      : _generation = _ref.read(
            chatBackendPresentationGenerationProvider(session.appSessionId)),
        assert(session.appSessionId > 0);

  final Ref _ref;
  final ChatBackendSession session;
  final int _generation;

  bool get _isCurrent =>
      _ref.read(
          chatBackendPresentationGenerationProvider(session.appSessionId)) ==
      _generation;

  @override
  void replaceHistory(ChatBackendHistoryPage page) {
    if (!_isCurrent) return;
    _ref
        .read(messagesForGroupProvider(session.appSessionId).notifier)
        .setMessages(page.messages);
    if (_ref.read(currentGroupProvider)?.id == session.appSessionId) {
      _ref.read(hasMoreMessagesProvider.notifier).state = page.hasMore;
    }
  }

  @override
  void addMessage(ChatMessage message) {
    if (!_isCurrent) return;
    _ref
        .read(messagesForGroupProvider(session.appSessionId).notifier)
        .addMessage(message);
  }

  @override
  void replaceMessage(ChatMessage message) {
    if (!_isCurrent) return;
    _ref
        .read(messagesForGroupProvider(session.appSessionId).notifier)
        .replaceMessage(message);
  }

  @override
  void setStreamingPreview(RuntimeStreamingPreviewState preview) {
    if (!_isCurrent) return;
    final controller = _ref.read(
      runtimeStreamingPreviewForGroupProvider(session.appSessionId).notifier,
    );
    controller.replaceSnapshot(preview);
  }

  @override
  void setExecutionState(
    ChatBackendExecutionState state, {
    String? statusText,
  }) {
    if (!_isCurrent) return;
    final notifier =
        _ref.read(chatSendStateForGroupProvider(session.appSessionId).notifier);
    final phase = switch (state) {
      ChatBackendExecutionState.idle => ChatSendPhase.idle,
      ChatBackendExecutionState.queued => ChatSendPhase.queued,
      ChatBackendExecutionState.preparing => ChatSendPhase.preparing,
      ChatBackendExecutionState.awaitingInteraction =>
        ChatSendPhase.awaitingConfirmation,
      ChatBackendExecutionState.executing => ChatSendPhase.executingTool,
      ChatBackendExecutionState.streaming => ChatSendPhase.streamingResponse,
    };
    notifier.update(
      phase: phase,
      isGenerating: state == ChatBackendExecutionState.executing ||
          state == ChatBackendExecutionState.streaming,
      statusText: statusText,
      clearStatusText: statusText == null,
    );
  }

  @override
  void setPendingInteractions(
    List<ChatBackendPendingInteraction> interactions,
  ) {
    if (!_isCurrent) return;
    _ref
        .read(chatBackendPendingInteractionsForSessionProvider(
                session.appSessionId)
            .notifier)
        .state = List.unmodifiable(interactions);
  }
}

ChatBackendSession chatBackendSessionFor(ChatGroup group) {
  final sessionId = group.id;
  if (sessionId == null) {
    throw StateError('chat_backend_session_requires_persisted_session');
  }
  return _backendSessionFor(group);
}
