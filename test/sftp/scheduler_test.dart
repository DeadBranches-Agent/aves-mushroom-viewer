import 'dart:async';

import 'package:aves/sftp/scheduler.dart';
import 'package:test/test.dart';

// records task execution and lets tests decide when each task completes
class _Tasks {
  final List<String> started = [];
  final Map<String, Completer<String>> _completers = {};
  final Map<String, SftpCancelToken> tokens = {};
  final Map<String, int> runCounts = {};

  Future<String> Function(SftpCancelToken token) call(String name) {
    return (token) {
      started.add(name);
      tokens[name] = token;
      runCounts[name] = (runCounts[name] ?? 0) + 1;
      return _completerFor(name).future;
    };
  }

  // completes when the task body is resumed, then checks cancellation
  Future<String> Function(SftpCancelToken token) cancellable(String name) {
    return (token) async {
      started.add(name);
      tokens[name] = token;
      runCounts[name] = (runCounts[name] ?? 0) + 1;
      await _completerFor(name).future;
      token.ensureActive();
      return name;
    };
  }

  Completer<String> _completerFor(String name) => _completers.putIfAbsent(name, Completer<String>.new);

  void finish(String name) => _completerFor(name).complete(name);

  void fail(String name, Object error) => _completerFor(name).completeError(error);
}

Future<void> settle() => pumpEventQueue();

void main() {
  late _Tasks tasks;

  setUp(() {
    tasks = _Tasks();
  });

  SftpTicket<String> submit(
    SftpScheduler scheduler,
    String key,
    SftpRequestPriority priority, {
    int order = 0,
    Future<String> Function(SftpCancelToken token)? task,
  }) {
    return scheduler.submit(
      key: key,
      priority: priority,
      order: order,
      task: task ?? tasks.call(key),
    );
  }

  group('dispatch order', () {
    test('serves lower priority index first', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);
      expect(tasks.started, ['blocker']);

      submit(scheduler, 'spec', SftpRequestPriority.speculativeThumbnail);
      submit(scheduler, 'neighbor', SftpRequestPriority.viewerNeighbor);
      submit(scheduler, 'visible', SftpRequestPriority.visibleThumbnail);
      submit(scheduler, 'current', SftpRequestPriority.viewerCurrent);
      expect(tasks.started, ['blocker']);

      for (final name in ['blocker', 'current', 'visible', 'neighbor']) {
        tasks.finish(name);
        await settle();
      }
      expect(tasks.started, ['blocker', 'current', 'visible', 'neighbor', 'spec']);

      scheduler.dispose();
    });

    test('serves ascending order within a priority, then submission order', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      submit(scheduler, 'far', SftpRequestPriority.viewerNeighbor, order: 3);
      submit(scheduler, 'near', SftpRequestPriority.viewerNeighbor, order: 1);
      submit(scheduler, 'mid', SftpRequestPriority.viewerNeighbor, order: 2);
      submit(scheduler, 'nearFirst', SftpRequestPriority.viewerNeighbor, order: 1);

      for (final name in ['blocker', 'near', 'nearFirst', 'mid']) {
        tasks.finish(name);
        await settle();
      }
      expect(tasks.started, ['blocker', 'near', 'nearFirst', 'mid', 'far']);

      scheduler.dispose();
    });

    test('runs at most `concurrency` tasks at a time', () async {
      final scheduler = SftpScheduler('host', concurrency: 2);
      for (var i = 0; i < 5; i++) {
        submit(scheduler, 'task$i', SftpRequestPriority.visibleThumbnail, order: i);
      }
      expect(tasks.started, ['task0', 'task1']);
      expect(scheduler.load, 5);

      tasks.finish('task0');
      await settle();
      expect(tasks.started, ['task0', 'task1', 'task2']);
      expect(scheduler.load, 4);

      tasks.finish('task1');
      tasks.finish('task2');
      await settle();
      expect(tasks.started, ['task0', 'task1', 'task2', 'task3', 'task4']);
      expect(scheduler.load, 2);

      scheduler.dispose();
    });

    test('load counts pending and running tasks', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      expect(scheduler.load, 0);

      submit(scheduler, 'a', SftpRequestPriority.viewerCurrent);
      submit(scheduler, 'b', SftpRequestPriority.viewerCurrent);
      expect(scheduler.load, 2);

      tasks.finish('a');
      await settle();
      expect(scheduler.load, 1);

      tasks.finish('b');
      await settle();
      expect(scheduler.load, 0);

      scheduler.dispose();
    });
  });

  group('keyed dedup', () {
    test('runs the task once and shares the result', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      var secondClosureRuns = 0;
      final ticket1 = submit(scheduler, 'key', SftpRequestPriority.visibleThumbnail);
      final ticket2 = submit(
        scheduler,
        'key',
        SftpRequestPriority.visibleThumbnail,
        task: (token) {
          secondClosureRuns++;
          return Future.value('other');
        },
      );
      expect(ticket1, isNot(ticket2));
      expect(scheduler.load, 1);

      tasks.finish('key');
      expect(await ticket1.future, 'key');
      expect(await ticket2.future, 'key');
      expect(tasks.runCounts['key'], 1);
      expect(secondClosureRuns, 0);

      scheduler.dispose();
    });

    test('shares errors with all tickets', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket1 = submit(scheduler, 'key', SftpRequestPriority.visibleThumbnail);
      final ticket2 = submit(scheduler, 'key', SftpRequestPriority.visibleThumbnail);

      tasks.fail('key', 'boom');
      await expectLater(ticket1.future, throwsA('boom'));
      await expectLater(ticket2.future, throwsA('boom'));

      scheduler.dispose();
    });

    test('upgrades priority of a pending task', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      submit(scheduler, 'shared', SftpRequestPriority.speculativeThumbnail);
      submit(scheduler, 'other', SftpRequestPriority.visibleThumbnail);
      submit(scheduler, 'shared', SftpRequestPriority.viewerCurrent);

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'shared']);

      scheduler.dispose();
    });

    test('upgrades order within the same priority', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      submit(scheduler, 'shared', SftpRequestPriority.viewerNeighbor, order: 5);
      submit(scheduler, 'other', SftpRequestPriority.viewerNeighbor, order: 2);
      submit(scheduler, 'shared', SftpRequestPriority.viewerNeighbor, order: 1);

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'shared']);

      scheduler.dispose();
    });

    test('keeps the task urgency when a later submission is less urgent', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      submit(scheduler, 'shared', SftpRequestPriority.visibleThumbnail);
      submit(scheduler, 'other', SftpRequestPriority.viewerNeighbor);
      submit(scheduler, 'shared', SftpRequestPriority.speculativeThumbnail);

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'shared']);

      scheduler.dispose();
    });

    test('joins a running task', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket1 = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent);
      expect(tasks.started, ['key']);

      final ticket2 = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent);
      expect(scheduler.load, 1);

      tasks.finish('key');
      expect(await ticket1.future, 'key');
      expect(await ticket2.future, 'key');
      expect(tasks.runCounts['key'], 1);

      scheduler.dispose();
    });

    test('runs a new task for a key submitted again after completion', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket1 = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent);
      tasks.finish('key');
      expect(await ticket1.future, 'key');

      final ticket2 = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent, task: (token) async => 'again');
      expect(await ticket2.future, 'again');

      scheduler.dispose();
    });
  });

  group('cancellation', () {
    test('cancelling one ticket leaves the task alive for the others', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      final ticket1 = submit(scheduler, 'shared', SftpRequestPriority.visibleThumbnail);
      final ticket2 = submit(scheduler, 'shared', SftpRequestPriority.visibleThumbnail);

      ticket1.cancel();
      await expectLater(ticket1.future, throwsA(isA<SftpRequestCancelledException>()));
      expect(scheduler.load, 2);

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'shared']);

      tasks.finish('shared');
      expect(await ticket2.future, 'shared');

      scheduler.dispose();
    });

    test('cancelling all tickets removes a pending task from the queue', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      final ticket1 = submit(scheduler, 'doomed', SftpRequestPriority.visibleThumbnail);
      final ticket2 = submit(scheduler, 'doomed', SftpRequestPriority.visibleThumbnail);
      submit(scheduler, 'survivor', SftpRequestPriority.speculativeThumbnail);
      expect(scheduler.load, 3);

      ticket1.cancel();
      ticket2.cancel();
      expect(scheduler.load, 2);
      await expectLater(ticket1.future, throwsA(isA<SftpRequestCancelledException>()));
      await expectLater(ticket2.future, throwsA(isA<SftpRequestCancelledException>()));

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'survivor']);
      expect(tasks.runCounts.containsKey('doomed'), false);

      scheduler.dispose();
    });

    test('cancelling a running task flips its token and frees the worker', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket = submit(scheduler, 'running', SftpRequestPriority.viewerCurrent, task: tasks.cancellable('running'));
      submit(scheduler, 'next', SftpRequestPriority.viewerCurrent);
      expect(tasks.started, ['running']);
      expect(tasks.tokens['running']!.isCancelled, false);

      ticket.cancel();
      expect(tasks.tokens['running']!.isCancelled, true);
      await expectLater(ticket.future, throwsA(isA<SftpRequestCancelledException>()));
      expect(tasks.started, ['running']);

      tasks.finish('running');
      await settle();
      expect(tasks.started, ['running', 'next']);
      expect(scheduler.load, 1);

      scheduler.dispose();
    });

    test('cancelled exception carries the request key', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket = submit(scheduler, 'some key', SftpRequestPriority.viewerCurrent);
      ticket.cancel();
      await expectLater(
        ticket.future,
        throwsA(isA<SftpRequestCancelledException>().having((v) => v.key, 'key', 'some key')),
      );

      scheduler.dispose();
    });

    test('cancelling twice is a no-op', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent);
      ticket.cancel();
      ticket.cancel();
      await expectLater(ticket.future, throwsA(isA<SftpRequestCancelledException>()));

      scheduler.dispose();
    });

    test('cancelling after completion is a no-op', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final ticket = submit(scheduler, 'key', SftpRequestPriority.viewerCurrent);
      tasks.finish('key');
      expect(await ticket.future, 'key');

      ticket.cancel();
      await settle();

      scheduler.dispose();
    });

    test('cancelWhere drops the matching tasks after a fling', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'blocker', SftpRequestPriority.viewerCurrent);

      final flung = [0, 1, 2].map((i) => submit(scheduler, 'cell$i', SftpRequestPriority.visibleThumbnail, order: i)).toList();
      final extra = submit(scheduler, 'cell1', SftpRequestPriority.visibleThumbnail);
      submit(scheduler, 'kept', SftpRequestPriority.visibleThumbnail, order: 9);
      expect(scheduler.load, 5);

      scheduler.cancelWhere((key, priority) => priority == SftpRequestPriority.visibleThumbnail && key.startsWith('cell'));
      expect(scheduler.load, 2);
      for (final ticket in [...flung, extra]) {
        await expectLater(ticket.future, throwsA(isA<SftpRequestCancelledException>()));
      }

      tasks.finish('blocker');
      await settle();
      expect(tasks.started, ['blocker', 'kept']);

      scheduler.dispose();
    });

    test('cancelWhere signals running tasks', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'running', SftpRequestPriority.visibleThumbnail, task: tasks.cancellable('running'));
      expect(tasks.started, ['running']);

      scheduler.cancelWhere((key, priority) => key == 'running');
      expect(tasks.tokens['running']!.isCancelled, true);

      scheduler.dispose();
    });

    test('does not raise unhandled errors for cancelled tickets nobody awaits', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final scheduler = SftpScheduler('host', concurrency: 1);
        final pending = submit(scheduler, 'pending', SftpRequestPriority.visibleThumbnail);
        submit(scheduler, 'pending', SftpRequestPriority.visibleThumbnail).cancel();
        pending.cancel();

        final running = submit(scheduler, 'running', SftpRequestPriority.viewerCurrent, task: tasks.cancellable('running'));
        running.cancel();
        tasks.finish('running');
        await settle();

        scheduler.dispose();
        await settle();
      }, (error, stack) => errors.add(error));
      await settle();
      expect(errors, isEmpty);
    });

    test('dispose cancels everything and rejects further submissions', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      final running = submit(scheduler, 'running', SftpRequestPriority.viewerCurrent);
      final queued = submit(scheduler, 'queued', SftpRequestPriority.viewerCurrent);

      scheduler.dispose();
      expect(scheduler.load, 0);
      await expectLater(running.future, throwsA(isA<SftpRequestCancelledException>()));
      await expectLater(queued.future, throwsA(isA<SftpRequestCancelledException>()));

      final afterDispose = submit(scheduler, 'late', SftpRequestPriority.viewerCurrent);
      await expectLater(afterDispose.future, throwsA(isA<SftpRequestCancelledException>()));
      expect(tasks.runCounts.containsKey('late'), false);
      expect(tasks.runCounts.containsKey('queued'), false);
    });
  });

  group('viewer active', () {
    test('suspends speculative thumbnails while keeping them queued', () async {
      final scheduler = SftpScheduler('host', concurrency: 2);
      scheduler.viewerActive = true;

      submit(scheduler, 'spec0', SftpRequestPriority.speculativeThumbnail, order: 0);
      submit(scheduler, 'spec1', SftpRequestPriority.speculativeThumbnail, order: 1);
      expect(tasks.started, isEmpty);
      expect(scheduler.load, 2);

      submit(scheduler, 'visible', SftpRequestPriority.visibleThumbnail);
      await settle();
      expect(tasks.started, ['visible']);

      scheduler.viewerActive = false;
      expect(tasks.started, ['visible', 'spec0']);

      tasks.finish('visible');
      await settle();
      expect(tasks.started, ['visible', 'spec0', 'spec1']);

      scheduler.dispose();
    });

    test('does not stop a speculative task already running', () async {
      final scheduler = SftpScheduler('host', concurrency: 1);
      submit(scheduler, 'spec', SftpRequestPriority.speculativeThumbnail);
      expect(tasks.started, ['spec']);

      scheduler.viewerActive = true;
      expect(tasks.tokens['spec']!.isCancelled, false);

      tasks.finish('spec');
      await settle();
      expect(scheduler.load, 0);

      scheduler.dispose();
    });
  });
}
