import 'package:ai_chat/main.dart' as app;
import 'package:ai_chat/models/chat_message.dart';
import 'package:ai_chat/pages/chat_page.dart';
import 'package:ai_chat/pages/settings_page.dart';
import 'package:ai_chat/providers/chat_providers.dart';
import 'package:ai_chat/providers/dsh_connection_providers.dart';
import 'package:ai_chat/widgets/interaction/ask_user_question_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const launchUrl = String.fromEnvironment('DSH_E2E_LAUNCH_URL');

  testWidgets('macOS chat through DSH Gateway', (tester) async {
    app.main();
    await _until(
        tester, () => find.byType(ChatPage).evaluate().isNotEmpty, 'chat page');
    final chat = tester.element(find.byType(ChatPage));
    final container = ProviderScope.containerOf(chat, listen: false);
    Navigator.of(chat).push<void>(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    await _until(tester, () => find.text('DSH 调试连接').evaluate().isNotEmpty,
        'DSH settings');
    final settings = find.text('DSH 调试连接');
    await tester.ensureVisible(settings);
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pumpAndSettle();
    await _until(tester, () => find.byType(TextField).evaluate().isNotEmpty,
        'launch URL field');
    await tester.enterText(find.byType(TextField).last, launchUrl);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('应用'));
    await tester.tap(find.text('应用'));
    await _until(
        tester, () => find.text('应用').evaluate().isEmpty, 'saved connection');
    await _until(tester, () => find.text('已验证').evaluate().isNotEmpty,
        'verified connection');
    final defaultRow = find.byKey(
      const ValueKey('settings-row-shell-新对话使用 DSH'),
    );
    await tester.ensureVisible(defaultRow);
    await tester.pumpAndSettle();
    await tester.tap(
        find.descendant(of: defaultRow, matching: find.byType(InkWell)).last);
    expect(container.read(dshDefaultForNewChatsProvider), isTrue);
    Navigator.of(tester.element(find.byType(SettingsPage))).pop();
    await _until(tester, () => find.byType(SettingsPage).evaluate().isEmpty,
        'chat returned');

    final created = <int>{};
    Future<void> send(String input) async {
      final field = find.byKey(const ValueKey('chat-input-field'));
      await _until(tester, () => field.evaluate().isNotEmpty, 'composer');
      await _until(
          tester,
          () => container.read(sendPhaseProvider) == ChatSendPhase.idle,
          'idle composer');
      await tester.pumpAndSettle();
      await tester.enterText(field, input);
      await tester.pump();
      expect(
          container.read(composerDocumentControllerProvider).exportPlainText(),
          input);
      await tester.tap(find.byKey(const ValueKey('chat-input-send-button')));
      await _until(tester, () {
        final group = container.read(currentGroupProvider);
        if (group?.backendId != 'dsh' || group?.id == null) return false;
        created.add(group!.id!);
        return container
            .read(messagesForGroupProvider(group.id))
            .any((message) => message.text.contains(input));
      }, 'DSH admitted $input');
    }

    Future<void> message(String marker) => _until(tester, () {
          final id = container.read(currentGroupProvider)?.id;
          return container
              .read(messagesForGroupProvider(id))
              .any((message) => message.text.contains(marker));
        }, marker);

    try {
      await tester.tap(find.byTooltip('新建对话'));
      await tester.pump();
      await send('DSH fixture text');
      await message('Fixture reply. Complete.');

      await send('DSH fixture stop');
      final stop = find.byKey(const ValueKey('chat-input-stop-icon'));
      await _until(tester, () => stop.evaluate().isNotEmpty, 'stop button');
      final groupId = container.read(currentGroupProvider)!.id;
      await _until(tester, () {
        final preview =
            container.read(runtimeStreamingPreviewForGroupProvider(groupId));
        return preview.messages.any((message) => message.blocks.isNotEmpty);
      }, 'partial streaming reply');
      await tester.tap(stop);
      await message('Stop fixture prefix.');
      expect(
        container.read(messagesForGroupProvider(groupId)).any((message) =>
            message.text == 'Stop fixture prefix.' &&
            message.status == MessageStatus.interrupted),
        isTrue,
      );

      await _until(tester, () => stop.evaluate().isEmpty, 'stopped turn');
      await send('DSH fixture question');
      final question = find.byType(AskUserQuestionCard);
      await _until(
          tester, () => question.evaluate().isNotEmpty, 'timeline question');
      await _until(tester, () => find.text('Blue').evaluate().isNotEmpty,
          'question card');
      await tester.tap(find.text('Blue').last);
      await tester.pump();
      await tester.tap(find.text('提交并继续'));
      await _until(tester, () => find.text('提交并继续').evaluate().isEmpty,
          'answered question');
      await message('Result: {"answers":[{"id":"color","selected":["Blue"]}]}');
      await _until(tester, () => stop.evaluate().isEmpty, 'answered turn done');

      await send('DSH fixture approval');
      final reject = find.text('拒绝');
      await _until(tester, () => reject.evaluate().isNotEmpty, 'approval card');
      await tester.tap(reject);
      await _until(
          tester, () => reject.evaluate().isEmpty, 'approval decision');
      await message('Result: rejected');
    } finally {
      for (final id in created) {
        await container.read(chatControllerProvider).deleteGroup(id);
      }
    }
  }, skip: launchUrl.isEmpty);
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String stage,
) async {
  final watch = Stopwatch()..start();
  while (!ready() && watch.elapsed < const Duration(seconds: 15)) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(ready(), isTrue, reason: stage);
}
