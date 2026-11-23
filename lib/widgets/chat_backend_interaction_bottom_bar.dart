import 'package:ai_chat/services/chat_backends/chat_backend_contract.dart';
import 'package:ai_chat/theme/app_radius.dart';
import 'package:ai_chat/theme/app_spacing.dart';
import 'package:ai_chat/theme/app_theme_spec.dart';
import 'package:flutter/material.dart';
import 'package:ai_chat/widgets/tool_confirmation/tool_confirmation_bottom_bar.dart';

/// Shared action surface for backend-owned interactions that do not map to a
/// local tool confirmation or AskUserQuestion card.
class ChatBackendInteractionBottomBar extends StatelessWidget {
  const ChatBackendInteractionBottomBar({
    super.key,
    required this.interaction,
    required this.onAction,
  });

  final ChatBackendPendingInteraction interaction;
  final Future<void> Function(String, Map<String, Object?>) onAction;

  Future<void> _submit(
    BuildContext context,
    String action, [
    Map<String, Object?> payload = const {},
  ]) async {
    try {
      await onAction(action, payload);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法提交远端交互')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (interaction.reference.kind == 'approval') {
      return ToolConfirmationBottomBar.backend(
        toolName: interaction.reference.payload['toolName'] as String? ?? '工具',
        summary: interaction.prompt,
        onContinue: interaction.actions.contains('allow-once')
            ? () => _submit(context, 'allow-once')
            : null,
        onCancel: interaction.actions.contains('reject')
            ? () => _submit(context, 'reject')
            : null,
      );
    }
    final colors = Theme.of(context).extension<AppThemeSpec>()!;
    final spacing = Theme.of(context).extension<AppSpacing>()!;
    final radius = Theme.of(context).extension<AppRadius>()!;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.md,
        spacing.xs,
        spacing.md,
        spacing.xs,
      ),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(spacing.md),
        decoration: BoxDecoration(
          color: colors.assistantSurface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(radius.lg + 4),
          boxShadow: [
            BoxShadow(
              color: colors.primaryText.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              interaction.title,
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.24,
              ),
            ),
            if (interaction.prompt.trim().isNotEmpty) ...[
              SizedBox(height: spacing.xs),
              Text(
                interaction.prompt,
                style: TextStyle(
                  color: colors.secondaryText,
                  fontSize: 12.5,
                  height: 1.42,
                ),
              ),
            ],
            if (interaction.actions.isNotEmpty) ...[
              SizedBox(height: spacing.sm),
              Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  for (var index = 0;
                      index < interaction.actions.length;
                      index++)
                    index == 0
                        ? FilledButton(
                            onPressed: () =>
                                _submit(context, interaction.actions[index]),
                            child:
                                Text(_actionLabel(interaction.actions[index])),
                          )
                        : OutlinedButton(
                            onPressed: () =>
                                _submit(context, interaction.actions[index]),
                            child:
                                Text(_actionLabel(interaction.actions[index])),
                          ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _actionLabel(String action) => switch (action) {
        'allow-once' => '仅本次允许',
        'reject' => '拒绝',
        'cancel' => '取消',
        _ => action,
      };
}
