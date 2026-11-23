const Object _unsetWorkspaceId = Object();

/// Stable identifier used to route a conversation to its owning execution
/// backend. Existing sessions default to the local Agent backend.
const String localAgentBackendId = 'local_agent';

class ChatGroup {
  int? id;
  String title;
  final DateTime createdAt;
  final DateTime lastMessageAt;
  final String? systemPrompt;
  final bool isSummarized;
  final String? workspaceId;
  final String backendId;
  final String? backendSessionId;

  ChatGroup({
    this.id,
    required this.title,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    this.systemPrompt,
    this.isSummarized = false,
    this.workspaceId,
    this.backendId = localAgentBackendId,
    this.backendSessionId,
  })  : createdAt = createdAt ?? DateTime.now(),
        lastMessageAt = lastMessageAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_message_at': lastMessageAt.millisecondsSinceEpoch,
      'system_prompt': systemPrompt,
      'is_summarized': isSummarized ? 1 : 0,
      'workspace_id': workspaceId,
      'backend_id': backendId,
      'backend_session_id': backendSessionId,
    };
  }

  factory ChatGroup.fromMap(Map<String, dynamic> map) {
    return ChatGroup(
      id: map['id'],
      title: map['title'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']),
      lastMessageAt:
          DateTime.fromMillisecondsSinceEpoch(map['last_message_at']),
      systemPrompt: map['system_prompt'],
      isSummarized: map['is_summarized'] == 1,
      workspaceId: map['workspace_id'] as String?,
      backendId: (map['backend_id'] as String?)?.trim().isNotEmpty == true
          ? (map['backend_id'] as String).trim()
          : localAgentBackendId,
      backendSessionId: map['backend_session_id'] as String?,
    );
  }

  ChatGroup copyWith({
    int? id,
    String? title,
    DateTime? createdAt,
    DateTime? lastMessageAt,
    String? systemPrompt,
    bool? isSummarized,
    Object? workspaceId = _unsetWorkspaceId,
    String? backendId,
    Object? backendSessionId = _unsetWorkspaceId,
  }) {
    return ChatGroup(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      isSummarized: isSummarized ?? this.isSummarized,
      workspaceId: identical(workspaceId, _unsetWorkspaceId)
          ? this.workspaceId
          : workspaceId as String?,
      backendId: backendId ?? this.backendId,
      backendSessionId: identical(backendSessionId, _unsetWorkspaceId)
          ? this.backendSessionId
          : backendSessionId as String?,
    );
  }
}
