import 'package:ai_chat/controllers/chat_controller.dart';
import 'package:ai_chat/controllers/chat_interaction_coordinator.dart';
import 'package:ai_chat/controllers/chat_preferences_controller.dart';
import 'package:ai_chat/controllers/chat_send_coordinator.dart';
import 'package:ai_chat/controllers/chat_session_coordinator.dart';
import 'package:ai_chat/controllers/chat_summary_controller.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_backend_providers.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_registry.dart';
import 'package:ai_chat/services/chat_backends/local_agent_session_backend.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export '../controllers/chat_controller.dart';
export '../controllers/chat_interaction_coordinator.dart';
export '../controllers/chat_preferences_controller.dart';
export '../controllers/chat_send_coordinator.dart';
export '../controllers/chat_session_coordinator.dart';
export '../controllers/chat_summary_controller.dart';
export '../services/chat_backends/chat_backend_contract.dart';
export '../services/chat_backends/chat_backend_registry.dart';
export 'chat_backend_providers.dart';
export '../services/tool_ui_renderer_registry.dart';
export 'chat_collection_providers.dart';
export 'chat_dependency_providers.dart';
export 'chat_interaction_providers.dart';
export 'chat_send_state_providers.dart';
export 'chat_ui_providers.dart';

final chatSendCoordinatorProvider = Provider<ChatSendCoordinator>((ref) {
  return DefaultChatSendCoordinator(
    ref,
    onTurnCompleted: (groupId) => ref
        .read(chatSummaryControllerProvider)
        .scheduleAutoSummary(groupId: groupId),
  );
});

/// Runtime backend implementations available to sessions in this app process.
final chatSessionBackendRegistryProvider = Provider<ChatBackendRegistry>((ref) {
  return ChatBackendRegistry([
    LocalAgentSessionBackend(
      ref,
      sendCoordinatorReader: () => ref.read(chatSendCoordinatorProvider),
    ),
  ]);
});

/// Capabilities of the currently selected session's fixed backend.
final chatBackendCapabilitiesProvider =
    Provider<ChatBackendCapabilities>((ref) {
  final group = ref.watch(currentGroupProvider);
  if (group?.id == null) {
    return const ChatBackendCapabilities(
      canStop: true,
      canQueueInput: true,
      canSteer: true,
      canConfirmTools: true,
      canAnswerQuestions: true,
      canPaginateHistory: true,
      canAttachFiles: true,
      hasStreamingPreview: true,
    );
  }
  final backend = ref.watch(chatSessionBackendRegistryProvider).resolve(
        group!.backendId,
      );
  return backend.capabilitiesFor(chatBackendSessionFor(group));
});

final chatSessionCoordinatorProvider = Provider<ChatSessionCoordinator>((ref) {
  return DefaultChatSessionCoordinator(
    ref,
    backendRegistry: ref.read(chatSessionBackendRegistryProvider),
  );
});

final chatSummaryControllerProvider = Provider<ChatSummaryController>((ref) {
  return DefaultChatSummaryController(ref);
});

final chatInteractionCoordinatorProvider =
    Provider<ChatInteractionCoordinator>((ref) {
  return DefaultChatInteractionCoordinator(
    ref,
    submitQuestionToBackend: (message, response) async {
      final group = ref.read(currentGroupProvider);
      if (group?.id == null) return;
      final session = chatBackendSessionFor(group!);
      final payload = message.payloadJson ?? const <String, dynamic>{};
      final interaction = ChatBackendInteractionReference(
        backendId: session.backendId,
        executionId: payload['agentTurnId']?.toString() ??
            payload['executionId']?.toString() ??
            'unknown',
        interactionId: payload['interactionId']?.toString() ??
            message.id?.toString() ??
            'unknown',
        kind: 'ask_user_question',
        appSessionId: session.appSessionId,
        messageId: message.id,
        payload: Map<String, Object?>.from(payload),
        sourceMessage: message,
      );
      await ref
          .read(chatSessionBackendRegistryProvider)
          .resolve(
            session.backendId,
          )
          .resolveInteraction(
            session,
            interaction,
            action: 'answer_question',
            payload: {'response': response.toJson()},
            presentation: RiverpodChatBackendPresentationSink(ref, session),
          );
    },
  );
});

final chatPreferencesControllerProvider =
    Provider<ChatPreferencesController>((ref) {
  return DefaultChatPreferencesController(ref);
});

final chatControllerProvider = Provider<ChatController>((ref) {
  return ChatController(
    ref,
    sendCoordinator: ref.read(chatSendCoordinatorProvider),
    sessionCoordinator: ref.read(chatSessionCoordinatorProvider),
    summaryController: ref.read(chatSummaryControllerProvider),
    preferencesController: ref.read(chatPreferencesControllerProvider),
    backendRegistry: ref.read(chatSessionBackendRegistryProvider),
  );
});
