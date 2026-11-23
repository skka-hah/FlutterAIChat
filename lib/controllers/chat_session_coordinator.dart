import 'package:ai_chat/models/chat_group.dart';
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/providers/chat_collection_providers.dart';
import 'package:ai_chat/providers/chat_dependency_providers.dart';
import 'package:ai_chat/providers/chat_send_state_providers.dart';
import 'package:ai_chat/providers/chat_ui_providers.dart';
import 'package:ai_chat/services/agent_run_manager.dart';
import 'package:ai_chat/providers/chat_backend_providers.dart';
import 'package:ai_chat/services/chat_backends/chat_backend_registry.dart';
import 'package:ai_chat/utils/logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract class ChatSessionCoordinator {
  Future<void> loadGroups();

  Future<void> loadCurrentGroup();

  Future<void> createNewGroup();

  Future<void> deleteGroup(int id);

  Future<void> loadMessages();

  Future<void> loadMoreMessages();

  Future<void> selectGroup(ChatGroup group);

  Future<void> updateCurrentGroupWorkspace(String? workspaceId);
}

class DefaultChatSessionCoordinator implements ChatSessionCoordinator {
  static const String _tag = 'ChatSessionCoordinator';
  static const int _pageSize = 20;

  final Ref _ref;
  final ChatBackendRegistry _backendRegistry;
  final Map<int, String?> _externalHistoryCursors = {};
  int _selectionVersion = 0;
  int _historyVersion = 0;
  bool _isRefreshingHistory = false;

  DefaultChatSessionCoordinator(
    this._ref, {
    required ChatBackendRegistry backendRegistry,
  }) : _backendRegistry = backendRegistry;

  @override
  Future<void> loadGroups() async {
    final selection = _selectionVersion;
    try {
      final dbHelper = _ref.read(databaseProvider);
      final groups = await dbHelper.getAllGroups();
      _ref.read(groupsProvider.notifier).setGroups(groups);
      if (selection == _selectionVersion) {
        await loadCurrentGroup();
      }
    } catch (e) {
      Logger.e(_tag, '加载分组失败', e);
    }
  }

  @override
  Future<void> loadCurrentGroup() async {
    final selection = _selectionVersion;
    try {
      final dbHelper = _ref.read(databaseProvider);
      final latestGroup = await dbHelper.getLatestGroup();
      if (selection != _selectionVersion) return;

      if (latestGroup != null) {
        final now = DateTime.now();
        final lastMessageTime = latestGroup.lastMessageAt;
        final isSameDay = now.year == lastMessageTime.year &&
            now.month == lastMessageTime.month &&
            now.day == lastMessageTime.day;
        final timeDiff = now.difference(lastMessageTime);

        if (!isSameDay && timeDiff.inHours >= 5) {
          await createNewGroup();
        } else {
          await selectGroup(latestGroup);
        }
      } else {
        await createNewGroup();
      }
    } catch (e) {
      Logger.e(_tag, '加载当前分组失败', e);
    }
  }

  @override
  Future<void> createNewGroup() async {
    final groups = _ref.read(groupsProvider);
    final newGroup = ChatGroup(
      title: '新对话 ${groups.length + 1}',
      systemPrompt: _ref.read(systemPromptProvider),
    );
    final currentRuntime = _ref.read(currentSessionRuntimeConfigProvider);
    final selection = _showGroup(newGroup);
    try {
      final draftRuntime = await _ref
          .read(sessionRuntimeConfigServiceProvider)
          .createDraftRuntime(currentRuntime: currentRuntime);
      if (_isSelected(selection, newGroup.id)) {
        _ref.read(currentSessionRuntimeConfigProvider.notifier).state =
            draftRuntime;
      }
    } catch (e) {
      Logger.e(_tag, '创建新分组失败', e);
    } finally {
      if (_isSelected(selection, newGroup.id)) {
        _ref.read(isInitializingProvider.notifier).state = false;
      }
    }
  }

  int _showGroup(ChatGroup group) {
    final selection = ++_selectionVersion;
    _isRefreshingHistory = false;
    _ref.read(isInitializingProvider.notifier).state = true;
    _ref.read(isLoadingMoreProvider.notifier).state = false;
    _ref.read(hasMoreMessagesProvider.notifier).state = false;
    if (group.id == null) {
      _ref.read(messagesForGroupProvider(null).notifier).clearMessages();
    }
    _ref.read(currentSessionRuntimeConfigProvider.notifier).state = null;
    _ref.read(systemPromptProvider.notifier).state = group.systemPrompt;
    _ref.read(currentGroupProvider.notifier).state = group;
    return selection;
  }

  bool _isSelected(int selection, int? groupId) =>
      selection == _selectionVersion &&
      _ref.read(currentGroupProvider)?.id == groupId;

  @override
  Future<void> deleteGroup(int id) async {
    try {
      final dbHelper = _ref.read(databaseProvider);
      final manager = _ref.read(agentRunManagerProvider);
      final queue = _ref.read(followUpDispatchQueueProvider(id));
      queue.takeAllForNextTurn(id);
      final run = manager.mainTurnForGroup(id);
      if (run != null) {
        if (run.phase == AgentRunPhase.suspended) {
          manager.releaseSuspendedTurn(groupId: id, turnId: run.turnId!);
        } else {
          manager.cancel(run.runId);
          await run.done;
        }
      }
      final group = await dbHelper.getGroupById(id);
      if (group != null && group.backendId != localAgentBackendId) {
        final session = chatBackendSessionFor(group);
        final backend = _backendRegistry.resolve(session.backendId);
        _ref
            .read(chatBackendPresentationGenerationProvider(id).notifier)
            .state++;
        final presentation = RiverpodChatBackendPresentationSink(_ref, session);
        await backend.stop(session, presentation);
        await _backendRegistry
            .resolve(session.backendId)
            .deleteSession(session);
      }
      await dbHelper.deleteGroup(id);
      _ref.invalidate(followUpDispatchQueueProvider(id));
      _ref.invalidate(fileToolHostAdaptersForGroupProvider(id));
      _ref.invalidate(messagesForGroupProvider(id));
      _ref.invalidate(chatSendStateForGroupProvider(id));
      _ref.invalidate(runtimeAssistantDraftForGroupProvider(id));
      _ref.invalidate(runtimeStreamingPreviewForGroupProvider(id));
      _ref.read(groupsProvider.notifier).setGroups(
            _ref.read(groupsProvider).where((group) => group.id != id).toList(),
          );

      final currentGroup = _ref.read(currentGroupProvider);
      if (currentGroup?.id != id) {
        return;
      }

      final selection = _selectionVersion;
      final latestGroup = await dbHelper.getLatestGroup();
      if (!_isSelected(selection, id)) return;
      if (latestGroup != null) {
        await selectGroup(latestGroup);
        return;
      }

      await createNewGroup();
    } catch (e) {
      Logger.e(_tag, '删除分组失败', e);
    }
  }

  @override
  Future<void> loadMessages() async {
    final groupId = _ref.read(currentGroupProvider)?.id;
    if (groupId == null) return;
    final selection = _selectionVersion;
    final history = ++_historyVersion;
    _isRefreshingHistory = true;
    _ref.read(isLoadingMoreProvider.notifier).state = false;

    try {
      Logger.d(_tag, '开始加载历史消息...');
      final dbHelper = _ref.read(databaseProvider);
      final provider = messagesForGroupProvider(groupId);
      final group = _ref.read(currentGroupProvider)!;
      if (group.backendId != localAgentBackendId) {
        final session = chatBackendSessionFor(group);
        final page =
            await _backendRegistry.resolve(session.backendId).loadHistory(
                  session,
                  limit: _pageSize,
                );
        if (!_isSelected(selection, groupId) || history != _historyVersion) {
          return;
        }
        _externalHistoryCursors[groupId] = page.nextCursor;
        RiverpodChatBackendPresentationSink(_ref, session).replaceHistory(page);
        return;
      }
      final previous = _ref.read(provider);
      final previousById = {
        for (final message in previous) message.id: message
      };
      final messages = await dbHelper.getMessagesByGroup(groupId);
      if (!_isSelected(selection, groupId) || history != _historyVersion) {
        return;
      }
      final totalCount = await dbHelper.getGroupMessageCount(groupId);
      if (!_isSelected(selection, groupId) || history != _historyVersion) {
        return;
      }

      final merged = {for (final message in messages) message.id: message};
      final unsaved = <ChatMessage>[];
      for (final message in _ref.read(provider)) {
        if (message.id == null) {
          unsaved.add(message);
        } else if (!identical(previousById[message.id], message) ||
            !previousById.containsKey(message.id)) {
          merged[message.id] = message;
        }
      }
      _ref.read(provider.notifier).setMessages([...merged.values, ...unsaved]);
      _ref.read(hasMoreMessagesProvider.notifier).state =
          totalCount > messages.length;
      Logger.i(_tag, '成功加载 ${messages.length} 条历史消息');
    } catch (e) {
      Logger.e(_tag, '加载历史消息失败', e);
    } finally {
      if (_isSelected(selection, groupId) && history == _historyVersion) {
        _isRefreshingHistory = false;
        _ref.read(isInitializingProvider.notifier).state = false;
      }
    }
  }

  @override
  Future<void> loadMoreMessages() async {
    final currentGroup = _ref.read(currentGroupProvider);
    if (currentGroup?.id == null) return;
    final groupId = currentGroup!.id!;

    if (_isRefreshingHistory ||
        _ref.read(isLoadingMoreProvider) ||
        !_ref.read(hasMoreMessagesProvider)) {
      return;
    }

    final selection = _selectionVersion;
    final history = _historyVersion;
    _ref.read(isLoadingMoreProvider.notifier).state = true;

    try {
      final dbHelper = _ref.read(databaseProvider);
      final currentCount = _ref.read(messagesProvider).length;
      final group = currentGroup;
      if (group.backendId != localAgentBackendId) {
        final session = chatBackendSessionFor(group);
        final cursor = _externalHistoryCursors[groupId];
        if (cursor == null) {
          _ref.read(hasMoreMessagesProvider.notifier).state = false;
          return;
        }
        final page =
            await _backendRegistry.resolve(session.backendId).loadHistory(
                  session,
                  cursor: cursor,
                  limit: _pageSize,
                );
        if (!_isSelected(selection, groupId) || history != _historyVersion) {
          return;
        }
        if (page.messages.isEmpty) {
          _externalHistoryCursors[groupId] = null;
          _ref.read(hasMoreMessagesProvider.notifier).state = false;
          return;
        }
        _ref
            .read(selectedMessagesNotifierProvider)
            .insertMessages(0, page.messages);
        _externalHistoryCursors[groupId] = page.nextCursor;
        _ref.read(hasMoreMessagesProvider.notifier).state = page.hasMore;
        return;
      }
      final totalCount = await dbHelper.getGroupMessageCount(groupId);
      if (!_isSelected(selection, groupId) || history != _historyVersion) {
        return;
      }
      final newMessages = await dbHelper.getMessagesByGroupWithPagination(
        groupId: groupId,
        limit: _pageSize,
        offset: currentCount,
      );
      if (!_isSelected(selection, groupId) || history != _historyVersion) {
        return;
      }

      if (newMessages.isEmpty) {
        _ref.read(hasMoreMessagesProvider.notifier).state = false;
        return;
      }

      _ref
          .read(selectedMessagesNotifierProvider)
          .insertMessages(0, newMessages);
      _ref.read(hasMoreMessagesProvider.notifier).state =
          totalCount > currentCount + newMessages.length;
    } catch (e) {
      Logger.e(_tag, '加载更多消息失败', e);
    } finally {
      if (_isSelected(selection, groupId) && history == _historyVersion) {
        _ref.read(isLoadingMoreProvider.notifier).state = false;
      }
    }
  }

  @override
  Future<void> selectGroup(ChatGroup group) async {
    final selection = _showGroup(group);
    final groupId = group.id;
    if (groupId == null) {
      _ref.read(isInitializingProvider.notifier).state = false;
      return;
    }
    try {
      final runtime = await _ref
          .read(sessionRuntimeConfigServiceProvider)
          .loadPersisted(groupId);
      if (!_isSelected(selection, groupId)) return;
      _ref.read(currentSessionRuntimeConfigProvider.notifier).state = runtime;
      await loadMessages();
    } catch (e) {
      if (_isSelected(selection, groupId)) {
        _ref.read(isInitializingProvider.notifier).state = false;
      }
      rethrow;
    }
  }

  @override
  Future<void> updateCurrentGroupWorkspace(String? workspaceId) async {
    final currentGroup = _ref.read(currentGroupProvider);
    if (currentGroup == null) {
      return;
    }

    final normalizedWorkspaceId =
        workspaceId?.trim().isEmpty ?? true ? null : workspaceId!.trim();
    if (currentGroup.workspaceId == normalizedWorkspaceId) {
      return;
    }

    final updatedGroup =
        currentGroup.copyWith(workspaceId: normalizedWorkspaceId);
    _ref.read(currentGroupProvider.notifier).state = updatedGroup;

    final groups = _ref.read(groupsProvider);
    final nextGroups = groups
        .map(
          (group) => group.id == currentGroup.id ? updatedGroup : group,
        )
        .toList(growable: false);
    _ref.read(groupsProvider.notifier).setGroups(nextGroups);

    if (currentGroup.id != null) {
      await _ref
          .read(databaseProvider)
          .updateGroupWorkspaceId(currentGroup.id!, normalizedWorkspaceId);
    }
  }
}
