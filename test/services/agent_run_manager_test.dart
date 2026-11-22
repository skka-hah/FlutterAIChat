import 'dart:async';

import 'package:ai_chat/services/agent_run_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reserves synchronously and runs different groups in FIFO order',
      () async {
    final manager = AgentRunManager();
    final enteredFirst = Completer<void>();
    final enteredSecond = Completer<void>();
    final firstResult = Completer<AgentRunOutcome>();
    final secondResult = Completer<AgentRunOutcome>();
    final started = <int>[];

    final first = manager.start(
        groupId: 1,
        execute: (run) {
          run.bindTurn(10);
          started.add(run.groupId);
          enteredFirst.complete();
          return firstResult.future;
        })!;
    expect(manager.start(groupId: 1, execute: _unexpected), isNull);
    final second = manager.start(
        groupId: 2,
        execute: (run) {
          started.add(run.groupId);
          enteredSecond.complete();
          return secondResult.future;
        })!;
    final third = manager.start(
        groupId: 3,
        execute: (run) async {
          started.add(run.groupId);
          return AgentRunOutcome.completed;
        })!;
    final fourth = manager.start(
        groupId: 4,
        execute: (run) async {
          started.add(run.groupId);
          return AgentRunOutcome.completed;
        })!;
    final removed = manager.start(groupId: 5, execute: _unexpected)!;

    await Future.wait([enteredFirst.future, enteredSecond.future]);
    expect(started, [1, 2]);
    expect(first.phase, AgentRunPhase.running);
    expect(first.turnId, 10);
    expect(third.phase, AgentRunPhase.queued);
    expect(fourth.phase, AgentRunPhase.queued);
    expect(manager.cancel(removed.runId), isTrue);
    expect(await removed.done, AgentRunOutcome.cancelled);
    expect(manager.mainTurnForGroup(5), isNull);

    firstResult.complete(AgentRunOutcome.completed);
    expect(await first.done, AgentRunOutcome.completed);
    await Future.wait([third.done, fourth.done]);
    expect(started, [1, 2, 3, 4]);
    expect(second.phase, AgentRunPhase.running);
    secondResult.complete(AgentRunOutcome.completed);
    await second.done;
  });

  test('suspension releases capacity and resume gets a new run ID', () async {
    final manager = AgentRunManager(maxConcurrentRuns: 1);
    final first = manager.start(
        groupId: 1,
        execute: (run) async {
          run.bindTurn(10);
          return AgentRunOutcome.suspended;
        })!;
    final enteredSecond = Completer<void>();
    final secondResult = Completer<AgentRunOutcome>();
    final second = manager.start(
        groupId: 2,
        execute: (run) {
          enteredSecond.complete();
          return secondResult.future;
        })!;

    expect(await first.done, AgentRunOutcome.suspended);
    await enteredSecond.future;
    expect(manager.start(groupId: 1, execute: _unexpected), isNull);
    expect(
        manager.resume(groupId: 1, turnId: 11, execute: _unexpected), isNull);
    expect(manager.releaseSuspendedTurn(groupId: 1, turnId: 11), isFalse);

    final abandoned = manager.resume(
      groupId: 1,
      turnId: 10,
      execute: _unexpected,
    )!;
    expect(manager.cancel(abandoned.runId), isTrue);
    expect(await abandoned.done, AgentRunOutcome.cancelled);
    expect(manager.mainTurnForGroup(1), same(first));

    final resumed = manager.resume(
      groupId: 1,
      turnId: 10,
      execute: (run) async {
        expect(run.turnId, 10);
        expect(run.isCancellationRequested, isFalse);
        return AgentRunOutcome.completed;
      },
    )!;
    expect(resumed.runId, isNot(first.runId));
    expect(manager.cancel(first.runId), isFalse);
    expect(
        manager.resume(groupId: 1, turnId: 10, execute: _unexpected), isNull);
    expect(resumed.phase, AgentRunPhase.queued);
    secondResult.complete(AgentRunOutcome.completed);
    await second.done;
    expect(await resumed.done, AgentRunOutcome.completed);
    expect(manager.mainTurnForGroup(1), isNull);
  });

  test('cancellation waits for its own cleanup and leaves other runs active',
      () async {
    final manager = AgentRunManager();
    final firstStarted = Completer<void>();
    final firstSawCancellation = Completer<void>();
    final cleanup = Completer<void>();
    final secondResult = Completer<AgentRunOutcome>();
    final first = manager.start(
        groupId: 1,
        execute: (run) async {
          firstStarted.complete();
          await run.cancellationRequested;
          firstSawCancellation.complete();
          await cleanup.future;
          return AgentRunOutcome.completed;
        })!;
    final second = manager.start(
        groupId: 2,
        execute: (_) {
          return secondResult.future;
        })!;
    final queued = manager.start(
        groupId: 3,
        execute: (_) async {
          return AgentRunOutcome.completed;
        })!;

    await firstStarted.future;
    expect(manager.cancel(first.runId), isTrue);
    expect(manager.cancel(first.runId), isFalse);
    await firstSawCancellation.future;
    expect(first.phase, AgentRunPhase.cancelling);
    expect(queued.phase, AgentRunPhase.queued);
    expect(manager.mainTurnForGroup(1), same(first));
    expect(second.isCancellationRequested, isFalse);

    cleanup.complete();
    expect(await first.done, AgentRunOutcome.cancelled);
    expect(await queued.done, AgentRunOutcome.completed);
    expect(second.phase, AgentRunPhase.running);
    secondResult.complete(AgentRunOutcome.completed);
    await second.done;
  });

  test('an executor failure releases the reservation and scheduler capacity',
      () async {
    final manager = AgentRunManager(maxConcurrentRuns: 1);
    final failure = StateError('execution failed');
    final failed = manager.start(groupId: 1, execute: (_) => throw failure)!;
    final next = manager.start(
        groupId: 2,
        execute: (_) async {
          return AgentRunOutcome.completed;
        })!;

    await expectLater(failed.done, throwsA(same(failure)));
    expect(manager.mainTurnForGroup(1), isNull);
    expect(await next.done, AgentRunOutcome.completed);
  });

  test('releases a suspended turn only when group and turn both match',
      () async {
    final manager = AgentRunManager();
    final run = manager.start(
        groupId: 1,
        execute: (run) async {
          run.bindTurn(10);
          return AgentRunOutcome.suspended;
        })!;

    await run.done;
    expect(manager.releaseSuspendedTurn(groupId: 2, turnId: 10), isFalse);
    expect(manager.releaseSuspendedTurn(groupId: 1, turnId: 10), isTrue);
    expect(manager.releaseSuspendedTurn(groupId: 1, turnId: 10), isFalse);
    final next = manager.start(
        groupId: 1,
        execute: (_) async {
          return AgentRunOutcome.completed;
        })!;
    expect(manager.cancel(run.runId), isFalse);
    expect(await next.done, AgentRunOutcome.completed);
  });
}

Future<AgentRunOutcome> _unexpected(AgentRun run) async {
  fail('Run ${run.runId} should not execute');
}
