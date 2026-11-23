import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../models/tool/tool_invocation.dart';
import '../../theme/app_theme_spec.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../tools/core/tool_display_names.dart';

/// Shared bottom bar for tool confirmations. It keeps authorization controls
/// out of the tool-specific timeline cards.
class ToolConfirmationBottomBar extends StatelessWidget {
  const ToolConfirmationBottomBar({
    super.key,
    required ChatMessage message,
    required ToolInvocation invocation,
    this.onContinue,
    this.onCancel,
    this.onContinueAndTrust,
  })  : _message = message,
        _invocation = invocation,
        _toolName = null,
        _summary = null,
        _continueLabel = '继续',
        _cancelLabel = '取消';

  /// Uses backend-provided context and only offers decisions the backend supports.
  const ToolConfirmationBottomBar.backend({
    super.key,
    required String toolName,
    required String summary,
    required this.onContinue,
    required this.onCancel,
  })  : _message = null,
        _invocation = null,
        _toolName = toolName,
        _summary = summary,
        _continueLabel = '仅本次允许',
        _cancelLabel = '拒绝',
        onContinueAndTrust = null;

  final ChatMessage? _message;
  final ToolInvocation? _invocation;
  final String? _toolName;
  final String? _summary;
  final String _continueLabel;
  final String _cancelLabel;
  final VoidCallback? onContinue;
  final VoidCallback? onCancel;
  final VoidCallback? onContinueAndTrust;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppThemeSpec>()!;
    final spacing = Theme.of(context).extension<AppSpacing>()!;
    final radius = Theme.of(context).extension<AppRadius>()!;
    final title = resolveToolDisplayName(_toolName ?? _invocation!.toolName);
    final invocationSummary = _invocation?.summary.trim();
    final summary = _summary ??
        ((invocationSummary ?? '').isEmpty
            ? _message!.text.trim()
            : invocationSummary!);

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
              '待确认操作',
              style: TextStyle(
                color: colors.secondaryText,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(height: spacing.xs),
            Text(
              title,
              style: TextStyle(
                color: colors.primaryText,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.24,
              ),
            ),
            if (summary.isNotEmpty) ...[
              SizedBox(height: spacing.xs),
              Text(
                summary,
                style: TextStyle(
                  color: colors.secondaryText,
                  fontSize: 12.5,
                  height: 1.42,
                ),
              ),
            ],
            SizedBox(height: spacing.sm),
            Wrap(
              spacing: spacing.xs,
              runSpacing: spacing.xs,
              children: [
                FilledButton(
                  onPressed: onContinue,
                  child: Text(_continueLabel),
                ),
                OutlinedButton(
                  onPressed: onCancel,
                  child: Text(_cancelLabel),
                ),
                if (_invocation != null)
                  OutlinedButton(
                    onPressed: onContinueAndTrust,
                    child: const Text('继续，以后不再确认'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
