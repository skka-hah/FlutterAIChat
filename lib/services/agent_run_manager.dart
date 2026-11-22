import 'dart:async';
import 'dart:collection';

/// In-process phase of a single execution attempt.
enum AgentRunPhase { queued, running, cancelling, suspended, finished }

/// A suspension keeps the main turn reserved while releasing its execution slot.
enum AgentRunOutcome { completed, suspended, cancelled }

/// Executes one attempt and returns after its event processing has settled.
typedef AgentRunExecutor = Future<AgentRunOutcome> Function(AgentRun run);

/// Identity and cooperative cancellation signal for one execution attempt.
class AgentRun {
  final int runId;
  final int groupId;
  AgentRunExecutor? _executor;
  AgentRun? _previousSuspension;
  final _completion = Completer<AgentRunOutcome>();
  final _cancellation = Completer<void>();
  int? _turnId;
  AgentRunPhase _phase = AgentRunPhase.queued;

  AgentRun._(this.runId, this.groupId, this._turnId, this._executor);

  /// Persisted turn identity, assigned after a fresh request creates its turn.
  int? get turnId => _turnId;
  AgentRunPhase get phase => _phase;

  /// Resolves when the execution settles, or throws if the executor fails.
  Future<AgentRunOutcome> get done => _completion.future;

  /// Completes only when this attempt receives a cancellation request.
  Future<void> get cancellationRequested => _cancellation.future;
  bool get isCancellationRequested => _cancellation.isCompleted;

  /// Binds the persisted turn created by this attempt. Cancellation can arrive
  /// while that write is in flight, so the executor can still bind it for cleanup.
  void bindTurn(int turnId) {
    if (_turnId != null ||
        (_phase != AgentRunPhase.running &&
            _phase != AgentRunPhase.cancelling)) {
      throw StateError('Cannot bind turn $turnId to run $runId in $_phase');
    }
    _turnId = turnId;
  }

  /// Moves the execution to the continuation created by context compaction.
  void bindContinuation({required int previousTurnId, required int turnId}) {
    if (_turnId != previousTurnId ||
        (_phase != AgentRunPhase.running &&
            _phase != AgentRunPhase.cancelling)) {
      throw StateError('Cannot replace turn $previousTurnId for run $runId');
    }
    _turnId = turnId;
  }
}

/// Reserves main turns by group and schedules their execution in FIFO order.
class AgentRunManager {
  AgentRunManager({this.maxConcurrentRuns = 2}) {
    if (maxConcurrentRuns < 1) {
      throw ArgumentError.value(
          maxConcurrentRuns, 'maxConcurrentRuns', 'Must be positive');
    }
  }

  final int maxConcurrentRuns;
  final _runs = <int, AgentRun>{};
  final _mainTurns = <int, AgentRun>{};
  final _ready = Queue<AgentRun>();
  int _nextRunId = 0;
  int _runningCount = 0;

  /// Includes queued, executing and suspended main turns for this group.
  AgentRun? mainTurnForGroup(int groupId) => _mainTurns[groupId];

  /// Reserves a persisted checkpoint after application startup.
  void restoreSuspendedTurn({required int groupId, required int turnId}) {
    _mainTurns.putIfAbsent(groupId, () {
      final run = AgentRun._(++_nextRunId, groupId, turnId, null);
      run._phase = AgentRunPhase.suspended;
      run._completion.complete(AgentRunOutcome.suspended);
      return run;
    });
  }

  /// Reserves the group synchronously. An occupied group returns null so the
  /// caller can dispatch the input to the existing turn's Steer/Queue flow.
  AgentRun? start({required int groupId, required AgentRunExecutor execute}) {
    if (_mainTurns.containsKey(groupId)) {
      return null;
    }
    return _enqueue(groupId, null, execute);
  }

  /// Schedules a new attempt for the matching suspended turn.
  /// The caller validates the persisted interaction before calling this method.
  AgentRun? resume({
    required int groupId,
    required int turnId,
    required AgentRunExecutor execute,
  }) {
    final previous = _mainTurns[groupId];
    if (previous != null &&
        (previous.phase != AgentRunPhase.suspended ||
            previous.turnId != turnId)) {
      return null;
    }
    return _enqueue(groupId, turnId, execute).._previousSuspension = previous;
  }

  /// Releases a suspended reservation after the caller persists a terminal turn.
  bool releaseSuspendedTurn({required int groupId, required int turnId}) {
    final run = _mainTurns[groupId];
    if (run?.phase != AgentRunPhase.suspended || run?.turnId != turnId) {
      return false;
    }
    _mainTurns.remove(groupId);
    return true;
  }

  /// Cancels by attempt ID. Running attempts keep their slot until cleanup
  /// settles. Cancelling a queued resume restores the suspended reservation.
  bool cancel(int runId) {
    final run = _runs[runId];
    if (run == null || run.isCancellationRequested) {
      return false;
    }

    run._cancellation.complete();
    if (_ready.remove(run)) {
      final previous = run._previousSuspension;
      run._previousSuspension = null;
      run._executor = null;
      _finish(run, AgentRunOutcome.cancelled);
      // A queued resume has not consumed the persisted checkpoint yet.
      if (previous != null) {
        _mainTurns[run.groupId] = previous;
      }
      run._completion.complete(AgentRunOutcome.cancelled);
    } else {
      run._phase = AgentRunPhase.cancelling;
    }
    return true;
  }

  AgentRun _enqueue(int groupId, int? turnId, AgentRunExecutor execute) {
    final run = AgentRun._(++_nextRunId, groupId, turnId, execute);
    _runs[run.runId] = run;
    _mainTurns[groupId] = run;
    _ready.addLast(run);
    scheduleMicrotask(_drain);
    return run;
  }

  void _drain() {
    while (_runningCount < maxConcurrentRuns && _ready.isNotEmpty) {
      final run = _ready.removeFirst();
      run._phase = AgentRunPhase.running;
      run._previousSuspension = null;
      final execute = run._executor!;
      run._executor = null;
      _runningCount++;
      unawaited(_execute(run, execute));
    }
  }

  Future<void> _execute(AgentRun run, AgentRunExecutor execute) async {
    try {
      final result = await execute(run);
      final outcome =
          run.isCancellationRequested ? AgentRunOutcome.cancelled : result;
      if (outcome == AgentRunOutcome.suspended && run.turnId == null) {
        throw StateError('Run ${run.runId} suspended without a persisted turn');
      }
      _finish(run, outcome);
      run._completion.complete(outcome);
    } catch (error, stackTrace) {
      _finish(run, AgentRunOutcome.completed);
      run._completion.completeError(error, stackTrace);
    } finally {
      _runningCount--;
      scheduleMicrotask(_drain);
    }
  }

  void _finish(AgentRun run, AgentRunOutcome outcome) {
    _runs.remove(run.runId);
    if (outcome == AgentRunOutcome.suspended) {
      run._phase = AgentRunPhase.suspended;
    } else {
      run._phase = AgentRunPhase.finished;
      _mainTurns.remove(run.groupId);
    }
  }
}
