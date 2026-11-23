import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/chat/runtime_streaming_preview_state.dart';
import 'package:ai_chat/models/chat/send_message_request.dart';

/// Stable application-side identity plus the opaque identity owned by a
/// conversation backend.
class ChatBackendSession {
  const ChatBackendSession({
    required this.appSessionId,
    required this.backendId,
    this.backendSessionId,
  });

  /// Local catalog key used to select this session in the Flutter app.
  final int appSessionId;

  /// Backend that owns this session's execution and history.
  final String backendId;

  /// Backend-owned session key, when the backend needs a separate identity.
  final String? backendSessionId;
}

/// Capabilities used to expose only controls supported by a session backend.
class ChatBackendCapabilities {
  const ChatBackendCapabilities({
    this.canStop = false,
    this.canQueueInput = false,
    this.canSteer = false,
    this.canConfirmTools = false,
    this.canAnswerQuestions = false,
    this.canPaginateHistory = false,
    this.canAttachFiles = false,
    this.hasStreamingPreview = false,
  });

  final bool canStop;
  final bool canQueueInput;
  final bool canSteer;
  final bool canConfirmTools;
  final bool canAnswerQuestions;
  final bool canPaginateHistory;
  final bool canAttachFiles;
  final bool hasStreamingPreview;
}

/// Backend-owned identity for a pending interaction or an active execution.
///
/// These identifiers are opaque to shared UI and must be sent back to the
/// backend that created them.
class ChatBackendInteractionReference {
  const ChatBackendInteractionReference({
    required this.backendId,
    required this.executionId,
    required this.interactionId,
    required this.kind,
    this.appSessionId,
    this.messageId,
    this.payload = const {},
    this.sourceMessage,
  });

  final String backendId;
  final String executionId;
  final String interactionId;
  final String kind;
  final int? appSessionId;
  final int? messageId;
  final Map<String, Object?> payload;
  final ChatMessage? sourceMessage;
}

/// Presentation data for an interaction owned by one backend execution.
class ChatBackendPendingInteraction {
  const ChatBackendPendingInteraction({
    required this.reference,
    required this.title,
    required this.prompt,
    this.actions = const <String>[],
  });

  final ChatBackendInteractionReference reference;
  final String title;
  final String prompt;
  final List<String> actions;
}

/// App-facing run state emitted by a backend without exposing engine states.
enum ChatBackendExecutionState {
  idle,
  queued,
  preparing,
  awaitingInteraction,
  executing,
  streaming,
}

/// Writes one backend's visible output into that session's shared projection.
abstract interface class ChatBackendPresentationSink {
  void replaceHistory(ChatBackendHistoryPage page);

  void addMessage(ChatMessage message);

  void replaceMessage(ChatMessage message);

  void setStreamingPreview(RuntimeStreamingPreviewState preview);

  void setExecutionState(
    ChatBackendExecutionState state, {
    String? statusText,
  });

  void setPendingInteractions(List<ChatBackendPendingInteraction> interactions);
}

/// A page of backend-owned history mapped to the shared timeline message
/// model. The cursor is opaque to the application.
class ChatBackendHistoryPage {
  const ChatBackendHistoryPage({
    required this.messages,
    this.nextCursor,
  });

  final List<ChatMessage> messages;
  final String? nextCursor;

  bool get hasMore => nextCursor != null;
}

/// Session execution and history boundary shared by local and external
/// backends. Implementations own their run lifecycle and persistence.
abstract interface class ChatSessionBackend {
  String get backendId;

  ChatBackendCapabilities capabilitiesFor(ChatBackendSession session);

  Future<ChatBackendHistoryPage> loadHistory(
    ChatBackendSession session, {
    String? cursor,
    required int limit,
  });

  Future<void> sendMessage(
    ChatBackendSession session,
    SendMessageRequest request,
    ChatBackendPresentationSink presentation, {
    required void Function() onTurnCompleted,
  });

  Future<void> deleteSession(ChatBackendSession session);

  Future<void> stop(
    ChatBackendSession session,
    ChatBackendPresentationSink presentation,
  );

  Future<void> resolveInteraction(
    ChatBackendSession session,
    ChatBackendInteractionReference interaction, {
    required String action,
    Map<String, Object?> payload = const {},
    required ChatBackendPresentationSink presentation,
  });
}
