import 'dart:async';

import 'package:ai_chat/controllers/chat_preferences_controller.dart';
import 'package:ai_chat/controllers/chat_send_coordinator.dart';
import 'package:ai_chat/models/chat/send_message_request.dart';
import 'package:ai_chat/models/interaction/ask_user_question_response.dart';
import 'package:ai_chat/controllers/chat_session_coordinator.dart';
import 'package:ai_chat/controllers/chat_summary_controller.dart';
import 'package:ai_chat/models/chat_group.dart';
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_dependency_providers.dart';
import 'package:ai_chat/providers/chat_send_state_providers.dart';
import 'package:ai_chat/providers/chat_ui_providers.dart';
import 'package:ai_chat/providers/chat_backend_providers.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_registry.dart';
import 'package:ai_chat/services/chat_backends/local_agent_session_backend.dart';
import 'package:ai_chat/models/response/message_content_type.dart';
import 'package:ai_chat/services/session_context_service.dart';
import 'package:ai_chat/utils/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ChatController {
  final Ref _ref;
  final ChatSendCoordinator _sendCoordinator;
  final ChatSessionCoordinator _sessionCoordinator;
  final ChatSummaryController _summaryController;
  final ChatPreferencesController _preferencesController;
  final ChatBackendRegistry _backendRegistry;

  ChatController(
    this._ref, {
    required ChatSendCoordinator sendCoordinator,
    required ChatSessionCoordinator sessionCoordinator,
    required ChatSummaryController summaryController,
    required ChatPreferencesController preferencesController,
    ChatBackendRegistry? backendRegistry,
  })  : _sendCoordinator = sendCoordinator,
        _sessionCoordinator = sessionCoordinator,
        _summaryController = summaryController,
        _preferencesController = preferencesController,
        _backendRegistry = backendRegistry ??
            ChatBackendRegistry([
              LocalAgentSessionBackend(
                _ref,
                sendCoordinatorReader: () => sendCoordinator,
              ),
            ]);

  Future<void> loadGroups() async {
    await _sessionCoordinator.loadGroups();
  }

  Future<void> loadCurrentGroup() async {
    await _sessionCoordinator.loadCurrentGroup();
  }

  Future<void> createNewGroup() async {
    await _sessionCoordinator.createNewGroup();
  }

  Future<void> deleteGroup(int id) async {
    _summaryController.cancelAutoSummaryTimer(groupId: id);
    await _sessionCoordinator.deleteGroup(id);
  }

  Future<void> loadMessages() async {
    await _sessionCoordinator.loadMessages();
  }

  Future<void> loadMoreMessages() async {
    await _sessionCoordinator.loadMoreMessages();
  }

  Future<void> sendMessage(String text) async {
    await sendMessageRequest(
      SendMessageRequest(text: text),
    );
  }

  Future<void> sendMessageRequest(SendMessageRequest request) async {
    Logger.i(
      'ChatController',
      'sendMessageRequest called',
    );
    try {
      final group = _ref.read(currentGroupProvider);
      if (group?.id == null) {
        await _sendCoordinator.sendMessageRequest(
          request,
          scheduleAutoSummary: _summaryController.scheduleAutoSummary,
          cancelActiveStream: cancelStreamSubscription,
        );
      } else {
        final session = chatBackendSessionFor(group!);
        await _backendRegistry.resolve(session.backendId).sendMessage(
              session,
              request,
              RiverpodChatBackendPresentationSink(_ref, session),
              onTurnCompleted: () => _summaryController.scheduleAutoSummary(
                groupId: session.appSessionId,
              ),
            );
      }
      Logger.i(
        'ChatController',
        'sendMessageRequest completed',
      );
    } catch (error, stackTrace) {
      Logger.e('ChatController', 'sendMessageRequest failed', error);
      Logger.e('ChatController', 'sendMessageRequest stack trace', stackTrace);
      rethrow;
    }
  }

  Future<void> cancelToolInvocation(ChatMessage message) async {
    await resolveBackendInteraction(message, action: 'cancel_tool');
  }

  Future<void> confirmToolInvocation(
    ChatMessage message, {
    bool trustTool = false,
  }) async {
    await resolveBackendInteraction(
      message,
      action: 'confirm_tool',
      payload: {'trustTool': trustTool},
    );
  }

  void cancelStreamSubscription() {
    final group = _ref.read(currentGroupProvider);
    if (group?.id != null) {
      final session = chatBackendSessionFor(group!);
      unawaited(
        _backendRegistry
            .resolve(session.backendId)
            .stop(session, RiverpodChatBackendPresentationSink(_ref, session)),
      );
      return;
    }
    final subscription = _ref.read(streamSubscriptionProvider);
    if (subscription != null) {
      unawaited(subscription.cancel());
      _ref.read(streamSubscriptionProvider.notifier).state = null;
    }

    final cancelActiveSend = _ref.read(activeSendCancellationProvider);
    if (cancelActiveSend != null) {
      unawaited(cancelActiveSend());
    }

    if (!_ref.read(isGeneratingProvider)) return;
    _ref.read(selectedChatSendNotifierProvider).update(
          isGenerating: false,
          phase: ChatSendPhase.idle,
        );

    final messages = _ref.read(messagesProvider);
    if (messages.isEmpty) return;

    final lastIndex = messages
        .lastIndexWhere((message) => message.role == MessageRole.assistant);
    if (lastIndex == -1) return;

    final aiMessage = messages[lastIndex];
    if (aiMessage.status == MessageStatus.generating) {
      _ref
          .read(selectedMessagesNotifierProvider)
          .updateMessageStatus(aiMessage.id!, MessageStatus.interrupted);

      final dbHelper = _ref.read(databaseProvider);
      if (aiMessage.id != null) {
        dbHelper.updateMessageStatus(aiMessage.id!, MessageStatus.interrupted);
      }
    }
  }

  Future<void> resolveBackendInteraction(
    ChatMessage message, {
    required String action,
    Map<String, Object?> payload = const {},
  }) async {
    final group = _ref.read(currentGroupProvider);
    if (group?.id == null) {
      switch (action) {
        case 'confirm_tool':
          await _sendCoordinator.confirmToolInvocation(
            message,
            trustTool: payload['trustTool'] == true,
          );
          return;
        case 'cancel_tool':
          await _sendCoordinator.cancelToolInvocation(message);
          return;
        case 'answer_question':
          final responseJson = payload['response'];
          if (responseJson is Map) {
            await _sendCoordinator.submitQuestionAnswers(
              message,
              response: AskUserQuestionResponse.fromJson(
                Map<String, dynamic>.from(responseJson),
              ),
            );
          }
          return;
      }
      return;
    }
    final session = chatBackendSessionFor(group!);
    final sourcePayload = message.payloadJson ?? const <String, dynamic>{};
    final interaction = ChatBackendInteractionReference(
      backendId: session.backendId,
      executionId: sourcePayload['agentTurnId']?.toString() ??
          sourcePayload['executionId']?.toString() ??
          'unknown',
      interactionId: sourcePayload['interactionId']?.toString() ??
          message.id?.toString() ??
          'unknown',
      kind: switch (message.contentType) {
        MessageContentType.toolInvocation ||
        MessageContentType.actionConfirmation =>
          'tool_confirmation',
        MessageContentType.askUserQuestionPrompt => 'ask_user_question',
        _ => message.contentType.wireName,
      },
      appSessionId: session.appSessionId,
      messageId: message.id,
      payload: Map<String, Object?>.from(sourcePayload),
      sourceMessage: message,
    );
    await _backendRegistry.resolve(session.backendId).resolveInteraction(
          session,
          interaction,
          action: action,
          payload: payload,
          presentation: RiverpodChatBackendPresentationSink(_ref, session),
        );
  }

  Future<void> submitQuestionAnswers(
    ChatMessage message, {
    required AskUserQuestionResponse response,
  }) async {
    await resolveBackendInteraction(
      message,
      action: 'answer_question',
      payload: {'response': response.toJson()},
    );
  }

  Future<void> resolveBackendPendingInteraction(
    ChatBackendPendingInteraction interaction, {
    required String action,
    Map<String, Object?> payload = const {},
  }) async {
    final group = _ref.read(currentGroupProvider);
    if (group?.id == null ||
        group!.backendId != interaction.reference.backendId ||
        group.id != interaction.reference.appSessionId) {
      return;
    }
    final session = chatBackendSessionFor(group);
    await _backendRegistry.resolve(session.backendId).resolveInteraction(
          session,
          interaction.reference,
          action: action,
          payload: payload,
          presentation: RiverpodChatBackendPresentationSink(_ref, session),
        );
  }

  Future<void> setSystemPrompt(String? prompt) async {
    await _preferencesController.setSystemPrompt(prompt);
  }

  Future<void> selectGroup(ChatGroup group) async {
    await _sessionCoordinator.selectGroup(group);
  }

  Future<void> updateCurrentGroupWorkspace(String? workspaceId) async {
    await _sessionCoordinator.updateCurrentGroupWorkspace(workspaceId);
  }

  Future<ManualSessionCompactionResult> compactCurrentSession() async {
    final currentGroup = _ref.read(currentGroupProvider);
    final groupId = currentGroup?.id;
    if (groupId == null) {
      throw StateError('current_group_missing');
    }

    _ref.read(selectedChatSendNotifierProvider).update(
          phase: ChatSendPhase.preparing,
          isGenerating: false,
          statusText: '正在压缩历史上下文',
        );
    try {
      final result = await _ref
          .read(sessionContextServiceProvider)
          .compactCompletedHistoryForGroup(
            groupId: groupId,
          );
      if (result.didCompactHistory) {
        await _sessionCoordinator.loadMessages();
      }
      return result;
    } finally {
      _ref.read(selectedChatSendNotifierProvider).update(
            phase: ChatSendPhase.idle,
            isGenerating: false,
            clearStatusText: true,
          );
    }
  }

  Future<String?> summarizeAndUpdateTitle() async {
    return _summaryController.summarizeAndUpdateTitle();
  }

  void cancelAutoSummaryTimer() {
    _summaryController.cancelAutoSummaryTimer();
  }
}
