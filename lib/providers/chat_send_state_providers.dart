import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'chat_collection_providers.dart';
import '../services/agent_run_manager.dart';

/// The app's shared quota and main-turn reservations.
final agentRunManagerProvider =
    Provider<AgentRunManager>((ref) => AgentRunManager());

enum ChatSendPhase {
  idle,
  queued,
  preparing,
  awaitingConfirmation,
  executingTool,
  streamingResponse,
}

class ChatSendState {
  /// Current lifecycle phase of the active send transaction.
  final ChatSendPhase phase;

  /// Whether the assistant is actively generating a streamed response.
  final bool isGenerating;

  /// Optional transient user-facing progress text for the active send.
  final String? statusText;

  const ChatSendState({
    required this.phase,
    required this.isGenerating,
    this.statusText,
  });

  const ChatSendState.idle()
      : phase = ChatSendPhase.idle,
        isGenerating = false,
        statusText = null;

  ChatSendState copyWith({
    ChatSendPhase? phase,
    bool? isGenerating,
    String? statusText,
    bool clearStatusText = false,
  }) {
    return ChatSendState(
      phase: phase ?? this.phase,
      isGenerating: isGenerating ?? this.isGenerating,
      statusText: clearStatusText ? null : (statusText ?? this.statusText),
    );
  }
}

class ChatSendStateNotifier extends StateNotifier<ChatSendState> {
  ChatSendStateNotifier() : super(const ChatSendState.idle());

  void setPhase(ChatSendPhase phase) {
    state = state.copyWith(
      phase: phase,
      clearStatusText: phase == ChatSendPhase.idle ||
          phase == ChatSendPhase.streamingResponse,
    );
  }

  void setGenerating(bool isGenerating) {
    state = state.copyWith(isGenerating: isGenerating);
  }

  void setStatusText(String? statusText) {
    state = state.copyWith(
      statusText: statusText,
      clearStatusText: statusText == null,
    );
  }

  void update({
    ChatSendPhase? phase,
    bool? isGenerating,
    String? statusText,
    bool clearStatusText = false,
  }) {
    final nextPhase = phase ?? state.phase;
    state = state.copyWith(
      phase: phase,
      isGenerating: isGenerating,
      statusText: statusText,
      clearStatusText: clearStatusText ||
          (statusText == null && nextPhase == ChatSendPhase.streamingResponse),
    );
  }
}

/// Mutable send state for a specific conversation.
final chatSendStateForGroupProvider =
    StateNotifierProvider.family<ChatSendStateNotifier, ChatSendState, int?>(
        (ref, groupId) {
  return ChatSendStateNotifier();
});

final chatSendStateProvider = Provider<ChatSendState>((ref) {
  return ref.watch(
      chatSendStateForGroupProvider(ref.watch(currentGroupProvider)?.id));
});

final selectedChatSendNotifierProvider = Provider<ChatSendStateNotifier>((ref) {
  return ref.watch(
      chatSendStateForGroupProvider(ref.watch(currentGroupProvider)?.id)
          .notifier);
});

final isGeneratingProvider = Provider<bool>((ref) {
  return ref.watch(chatSendStateProvider.select((state) => state.isGenerating));
});

final sendPhaseProvider = Provider<ChatSendPhase>((ref) {
  return ref.watch(chatSendStateProvider.select((state) => state.phase));
});
