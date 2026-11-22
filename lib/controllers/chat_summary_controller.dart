import 'dart:async';

import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/models/chat_group.dart';
import 'package:ai_chat/models/llm/base_llm.dart';
import 'package:ai_chat/models/llm/llm_config.dart';
import 'package:ai_chat/models/session/session_runtime_config.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_dependency_providers.dart';
import 'package:ai_chat/providers/chat_send_state_providers.dart';
import 'package:ai_chat/services/chat_service.dart';
import 'package:ai_chat/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class ChatSummaryController {
  Future<String?> summarizeAndUpdateTitle();

  void scheduleAutoSummary({int? groupId});

  void cancelAutoSummaryTimer({int? groupId});
}

class DefaultChatSummaryController implements ChatSummaryController {
  static const String _tag = 'ChatSummaryController';
  static const int _minMessagesForSummary = 6;
  static const int _inactivitySeconds = 30;

  final Ref _ref;
  final _autoSummaryTimers = <int, Timer>{};
  final _activeSummaries = <int>{};

  DefaultChatSummaryController(this._ref) {
    _ref.onDispose(() {
      for (final timer in _autoSummaryTimers.values) {
        timer.cancel();
      }
      _autoSummaryTimers.clear();
    });
  }

  @override
  Future<String?> summarizeAndUpdateTitle() async {
    final currentGroup = _ref.read(currentGroupProvider);
    if (currentGroup?.id == null) return null;
    return _summarizeGroup(
      currentGroup!,
      runtime: _ref.read(currentSessionRuntimeConfigProvider),
      prompt: _ref.read(systemPromptProvider),
    );
  }

  Future<String?> _summarizeGroup(
    ChatGroup group, {
    required SessionRuntimeConfig? runtime,
    required String? prompt,
  }) async {
    final groupId = group.id!;
    if (!_activeSummaries.add(groupId)) return null;

    try {
      final messages = _ref.read(messagesForGroupProvider(groupId));
      if (messages.isEmpty) return null;
      Logger.i(_tag, '开始生成对话摘要...');

      final completedMessages = messages
          .where((msg) => msg.status == MessageStatus.completed)
          .toList()
          .reversed
          .toList();

      if (completedMessages.isEmpty) return null;

      final chatService = _ref.read(chatServiceProvider);
      final summaryConfig =
          await _buildSummaryChatConfig(groupId, runtime, prompt);
      final llm = chatService.llm;
      final summary = llm is RuntimeConfigurableBaseLlm
          ? await (llm as RuntimeConfigurableBaseLlm)
              .summarizeConversationWithConfig(
              completedMessages,
              config: summaryConfig,
            )
          : await llm.summarizeConversation(completedMessages);

      final dbHelper = _ref.read(databaseProvider);
      await dbHelper.updateGroupTitle(groupId, summary, isSummarized: true);

      final selectedGroup = _ref.read(currentGroupProvider);
      if (selectedGroup?.id == groupId) {
        _ref.read(currentGroupProvider.notifier).state =
            selectedGroup!.copyWith(title: summary, isSummarized: true);
      }
      final groups = await dbHelper.getAllGroups();
      _ref.read(groupsProvider.notifier).setGroups(groups);

      Logger.i(_tag, '对话摘要生成成功: $summary');
      return summary;
    } catch (e) {
      Logger.e(_tag, '生成对话摘要失败', e);
      return null;
    } finally {
      _activeSummaries.remove(groupId);
    }
  }

  @override
  void scheduleAutoSummary({int? groupId}) {
    final target = groupId ?? _ref.read(currentGroupProvider)?.id;
    if (target == null) return;
    _autoSummaryTimers.remove(target)?.cancel();
    _autoSummaryTimers[target] =
        Timer(const Duration(seconds: _inactivitySeconds), () {
      _autoSummaryTimers.remove(target);
      unawaited(_checkAndTriggerAutoSummary(target));
    });
  }

  Future<void> _checkAndTriggerAutoSummary(int groupId) async {
    try {
      final group = await _ref.read(databaseProvider).getGroupById(groupId);
      if (group == null) return;

      if (group.isSummarized) {
        Logger.d(_tag, '分组已经生成过摘要，跳过自动摘要');
        return;
      }

      if (_ref.read(agentRunManagerProvider).mainTurnForGroup(groupId) !=
              null ||
          _activeSummaries.contains(groupId)) {
        Logger.d(_tag, '正在生成消息或摘要中，跳过自动摘要');
        return;
      }

      if (!_isDefaultTitle(group.title)) {
        Logger.d(_tag, '标题已自定义，跳过自动摘要');
        return;
      }

      final messages = _ref.read(messagesForGroupProvider(groupId));
      final completedMessages = messages
          .where((msg) => msg.status == MessageStatus.completed)
          .toList();

      if (completedMessages.length < _minMessagesForSummary) {
        Logger.d(_tag,
            '消息数量不足（${completedMessages.length}/$_minMessagesForSummary），跳过自动摘要');
        return;
      }

      Logger.i(_tag, '触发自动摘要...');
      final runtime = await _ref
          .read(sessionRuntimeConfigServiceProvider)
          .loadPersisted(groupId);
      await _summarizeGroup(group,
          runtime: runtime, prompt: group.systemPrompt);
    } catch (error) {
      Logger.e(_tag, '自动摘要失败', error);
    }
  }

  static final RegExp _defaultTitlePattern = RegExp(r'^新对话 \d+$');

  Future<ChatConfig> _buildSummaryChatConfig(
    int groupId,
    SessionRuntimeConfig? runtimeConfig,
    String? prompt,
  ) async {
    LLMConfig? runtimeConfigOverride;
    LLMConfig? sideRuntimeConfigOverride;
    if (runtimeConfig != null && runtimeConfig.groupId == groupId) {
      final resolver = _ref.read(sessionLlmConfigResolverProvider);
      runtimeConfigOverride = await resolver.resolve(runtimeConfig);
      sideRuntimeConfigOverride = await resolver.resolve(
        runtimeConfig,
        slot: SessionRuntimeSlot.side,
      );
    }
    return ChatConfig(
      systemPrompt: '',
      userSystemPrompt: prompt ?? '',
      runtimeConfigOverride: runtimeConfigOverride,
      sideRuntimeConfigOverride: sideRuntimeConfigOverride,
    );
  }

  @visibleForTesting
  static bool isDefaultTitle(String title) {
    return _defaultTitlePattern.hasMatch(title) ||
        title == 'AI Chat' ||
        title == '默认对话';
  }

  bool _isDefaultTitle(String title) => isDefaultTitle(title);

  @override
  void cancelAutoSummaryTimer({int? groupId}) {
    final target = groupId ?? _ref.read(currentGroupProvider)?.id;
    _autoSummaryTimers.remove(target)?.cancel();
  }
}
