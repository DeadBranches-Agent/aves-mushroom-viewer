import 'dart:async';

// priority classes for remote reads, lowest index served first
enum SftpRequestPriority {
  // full-size bytes for the image currently displayed in the viewer
  viewerCurrent,
  // thumbnails for grid cells currently in the viewport
  visibleThumbnail,
  // full-size bytes for the viewer's neighbouring images (order = distance, nearest first)
  viewerNeighbor,
  // speculative thumbnails for grid cells outside the viewport; suspended while the viewer is open
  speculativeThumbnail,
}

// thrown into a task's future when it is cancelled before or during execution
class SftpRequestCancelledException implements Exception {
  final String key;

  SftpRequestCancelledException(this.key);

  @override
  String toString() => 'SftpRequestCancelledException{key=$key}';
}

// checked cooperatively by tasks between chunk reads
class SftpCancelToken {
  final String _key;
  bool _cancelled = false;

  SftpCancelToken._(this._key);

  bool get isCancelled => _cancelled;

  // throws `SftpRequestCancelledException` if cancelled
  void ensureActive() {
    if (_cancelled) throw SftpRequestCancelledException(_key);
  }
}

// handle for one submission; cancelling releases this holder's interest
class SftpTicket<T> {
  final _SftpTask _task;
  final Completer<T> _completer = Completer<T>();

  SftpTicket._(this._task) {
    // keep an error listener attached at all times, so that a cancelled ticket
    // nobody awaits does not surface as an unhandled asynchronous error
    unawaited(_completer.future.then((_) {}, onError: (_) {}));
  }

  Future<T> get future => _completer.future;

  void cancel() => _task.scheduler._cancelTicket(this);

  void _complete(Object? value) => _completer.complete(value as T);

  void _completeError(Object error, StackTrace stackTrace) => _completer.completeError(error, stackTrace);
}

class _SftpTask {
  final SftpScheduler scheduler;
  final String key;
  final int seq;
  final Future<Object?> Function(SftpCancelToken token) run;
  final Set<SftpTicket<Object?>> tickets = {};
  late final SftpCancelToken token = SftpCancelToken._(key);
  SftpRequestPriority priority;
  int order;
  bool running = false;

  _SftpTask({
    required this.scheduler,
    required this.key,
    required this.seq,
    required this.priority,
    required this.order,
    required this.run,
  });

  // most urgent first
  int compareTo(_SftpTask other) {
    final byPriority = priority.index.compareTo(other.priority.index);
    if (byPriority != 0) return byPriority;
    final byOrder = order.compareTo(other.order);
    if (byOrder != 0) return byOrder;
    return seq.compareTo(other.seq);
  }

  bool isLessUrgentThan(SftpRequestPriority otherPriority, int otherOrder) {
    final byPriority = otherPriority.index.compareTo(priority.index);
    if (byPriority != 0) return byPriority < 0;
    return otherOrder < order;
  }
}

// one scheduler per host: a priority queue of remote reads with a fixed
// number of concurrent workers (default 4).
//
// - requests are keyed. re-submitting a live key returns a ticket onto the same
//   underlying task, raising its priority/order if the new submission is more urgent.
//   the task runs once; all tickets share its result.
// - a task is cancelled when all its tickets are cancelled: pending tasks leave
//   the queue immediately; running tasks are signalled through their `SftpCancelToken`.
// - within a priority class, tasks run in ascending `order`, then submission order.
// - `viewerActive = true` suspends `speculativeThumbnail` tasks (they stay queued);
//   setting it back to false resumes them.
class SftpScheduler {
  final String hostId;
  final int concurrency;

  final Map<String, _SftpTask> _pending = {};
  final Map<String, _SftpTask> _running = {};
  int _seq = 0;
  bool _viewerActive = false;
  bool _disposed = false;

  SftpScheduler(this.hostId, {this.concurrency = 4});

  SftpTicket<T> submit<T>({
    required String key,
    required SftpRequestPriority priority,
    int order = 0,
    required Future<T> Function(SftpCancelToken token) task,
  }) {
    final live = _pending[key] ?? _running[key];
    if (live != null) {
      final ticket = SftpTicket<T>._(live);
      live.tickets.add(ticket);
      if (live.isLessUrgentThan(priority, order)) {
        live.priority = priority;
        live.order = order;
      }
      _dispatch();
      return ticket;
    }

    final newTask = _SftpTask(
      scheduler: this,
      key: key,
      seq: _seq++,
      priority: priority,
      order: order,
      run: task,
    );
    final ticket = SftpTicket<T>._(newTask);
    newTask.tickets.add(ticket);
    if (_disposed) {
      _cancelTicket(ticket);
      return ticket;
    }

    _pending[key] = newTask;
    _dispatch();
    return ticket;
  }

  // cancels all tickets of all tasks matching `test` (e.g. after a fling, for cells that went by)
  void cancelWhere(bool Function(String key, SftpRequestPriority priority) test) {
    final matches = [..._pending.values, ..._running.values].where((task) => test(task.key, task.priority)).toList();
    matches.forEach(_cancelTask);
  }

  set viewerActive(bool active) {
    if (_viewerActive == active) return;
    _viewerActive = active;
    _dispatch();
  }

  // pending + running task count, for debug overlays
  int get load => _pending.length + _running.length;

  void dispose() {
    _disposed = true;
    [..._pending.values, ..._running.values].forEach(_cancelTask);
    _pending.clear();
    _running.clear();
  }

  void _cancelTask(_SftpTask task) => task.tickets.toList().forEach(_cancelTicket);

  void _cancelTicket(SftpTicket<Object?> ticket) {
    final task = ticket._task;
    if (!task.tickets.remove(ticket)) return;

    ticket._completeError(SftpRequestCancelledException(task.key), StackTrace.current);
    if (task.tickets.isEmpty) {
      task.token._cancelled = true;
      if (!task.running) {
        _pending.remove(task.key);
      }
      _dispatch();
    }
  }

  _SftpTask? _next() {
    _SftpTask? best;
    for (final task in _pending.values) {
      if (_viewerActive && task.priority == SftpRequestPriority.speculativeThumbnail) continue;
      if (best == null || task.compareTo(best) < 0) {
        best = task;
      }
    }
    return best;
  }

  void _dispatch() {
    if (_disposed) return;
    while (_running.length < concurrency) {
      final task = _next();
      if (task == null) return;

      _pending.remove(task.key);
      _running[task.key] = task;
      task.running = true;
      Future.sync(() => task.run(task.token)).then(
        (value) => _onTaskDone(task, value: value),
        onError: (Object error, StackTrace stackTrace) => _onTaskDone(task, error: error, stackTrace: stackTrace),
      );
    }
  }

  void _onTaskDone(_SftpTask task, {Object? value, Object? error, StackTrace? stackTrace}) {
    _running.remove(task.key);
    task.running = false;
    final tickets = task.tickets.toList();
    task.tickets.clear();
    if (error != null) {
      tickets.forEach((ticket) => ticket._completeError(error, stackTrace ?? StackTrace.current));
    } else {
      tickets.forEach((ticket) => ticket._complete(value));
    }
    _dispatch();
  }
}
