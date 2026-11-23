import 'dart:async';

import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/chat_group.dart';
import 'package:ai_chat/models/chat/send_message_request.dart';
import 'package:ai_chat/models/interaction/ask_user_question_response.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_dependency_providers.dart';
import 'package:ai_chat/providers/chat_send_state_providers.dart';
import 'package:ai_chat/providers/chat_ui_providers.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/utils/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/chat_send_coordinator.dart';

/// Routes the existing local Agent lifecycle through the backend contract.
///
/// The underlying turn storage, scheduler, interaction checkpoints and event
/// processor remain owned by the local Agent implementation.
class LocalAgentSessionBackend implements ChatSessionBackend {
  LocalAgentSessionBackend(
    this._ref, {
    required ChatSendCoordinator Function() sendCoordinatorReader,
  }) : _sendCoordinatorReader = sendCoordinatorReader;

  static const String _tag = 'LocalAgentSessionBackend';

  final Ref _ref;
  final ChatSendCoordinator Function() _sendCoordinatorReader;

  @override
  String get backendId => localAgentBackendId;

  @override
  ChatBackendCapabilities capabilitiesFor(ChatBackendSession session) =>
      const ChatBackendCapabilities(
        canStop: true,
        canQueueInput: true,
        canSteer: true,
        canConfirmTools: true,
        canAnswerQuestions: true,
        canPaginateHistory: true,
        canAttachFiles: true,
        hasStreamingPreview: true,
      );

  @override
  Future<ChatBackendHistoryPage> loadHistory(
    ChatBackendSession session, {
    String? cursor,
    required int limit,
  }) async {
    final offset = int.tryParse(cursor ?? '0') ?? 0;
    final storage = _ref.read(databaseProvider);
    final messages = await storage.getMessagesByGroupWithPagination(
      groupId: session.appSessionId,
      limit: limit,
      offset: offset,
    );
    final count = await storage.getGroupMessageCount(session.appSessionId);
    final nextOffset = offset + messages.length;
    return ChatBackendHistoryPage(
      messages: messages,
      nextCursor: nextOffset < count ? '$nextOffset' : null,
    );
  }

  @override
  Future<void> deleteSession(ChatBackendSession session) async {
    // The local catalog deletion cascades through the local transcript tables.
  }

  @override
  Future<void> sendMessage(
    ChatBackendSession session,
    SendMessageRequest request,
    ChatBackendPresentationSink presentation, {
    required void Function() onTurnCompleted,
  }) async {
    if (_ref.read(currentGroupProvider)?.id != session.appSessionId) {
      throw StateError('local_agent_send_requires_selected_session');
    }
    await _sendCoordinatorReader().sendMessageRequest(
      request,
      scheduleAutoSummary: onTurnCompleted,
      cancelActiveStream: () => unawaited(stop(session, presentation)),
    );
  }

  @override
  Future<void> stop(
    ChatBackendSession session,
    ChatBackendPresentationSink presentation,
  ) async {
    final groupId = session.appSessionId;
    final manager = _ref.read(agentRunManagerProvider);
    final run = manager.mainTurnForGroup(groupId);
    if (run != null) {
      manager.cancel(run.runId);
      return;
    }
    if (_ref.read(currentGroupProvider)?.id != groupId) return;

    final subscription = _ref.read(streamSubscriptionProvider);
    if (subscription != null) {
      unawaited(subscription.cancel());
      _ref.read(streamSubscriptionProvider.notifier).state = null;
    }
    final cancelActiveSend = _ref.read(activeSendCancellationProvider);
    if (cancelActiveSend != null) {
      unawaited(cancelActiveSend());
    }

    final sendState = _ref.read(chatSendStateForGroupProvider(groupId));
    if (!sendState.isGenerating) return;
    _ref.read(chatSendStateForGroupProvider(groupId).notifier).update(
          isGenerating: false,
          phase: ChatSendPhase.idle,
        );
    final messages = _ref.read(messagesForGroupProvider(groupId));
    final assistantIndex = messages
        .lastIndexWhere((message) => message.role == MessageRole.assistant);
    if (assistantIndex == -1) return;

    final assistant = messages[assistantIndex];
    if (assistant.status == MessageStatus.generating && assistant.id != null) {
      _ref
          .read(messagesForGroupProvider(groupId).notifier)
          .updateMessageStatus(assistant.id!, MessageStatus.interrupted);
      await _ref.read(databaseProvider).updateMessageStatus(
            assistant.id!,
            MessageStatus.interrupted,
          );
    }
  }

  @override
  Future<void> resolveInteraction(
    ChatBackendSession session,
    ChatBackendInteractionReference interaction, {
    required String action,
    Map<String, Object?> payload = const {},
    required ChatBackendPresentationSink presentation,
  }) async {
    if (interaction.backendId != backendId ||
        session.backendId != backendId ||
        interaction.appSessionId != session.appSessionId ||
        _ref.read(currentGroupProvider)?.id != session.appSessionId) {
      return;
    }
    final messageId = interaction.messageId;
    if (messageId == null) return;
    final message = _ref
            .read(messagesForGroupProvider(session.appSessionId))
            .where((item) => item.id == messageId)
            .firstOrNull ??
        interaction.sourceMessage;
    if (message == null) return;

    switch (action) {
      case 'confirm_tool':
        await _sendCoordinatorReader().confirmToolInvocation(
          message,
          trustTool: payload['trustTool'] == true,
        );
        break;
      case 'cancel_tool':
        await _sendCoordinatorReader().cancelToolInvocation(message);
        break;
      case 'answer_question':
        final responseJson = payload['response'];
        if (responseJson is! Map) return;
        await _sendCoordinatorReader().submitQuestionAnswers(
          message,
          response: AskUserQuestionResponse.fromJson(
            Map<String, dynamic>.from(responseJson),
          ),
        );
        break;
      default:
        Logger.w(_tag, 'unsupported local interaction action=$action');
    }
  }
}
