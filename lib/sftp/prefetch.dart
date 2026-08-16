import 'dart:async';
import 'dart:math';

import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/source/collection_lens.dart';
import 'package:aves/sftp/scheduler.dart';
import 'package:aves/sftp/sftp_media_service.dart';
import 'package:flutter/foundation.dart';

final SftpViewerPrefetcher sftpViewerPrefetcher = SftpViewerPrefetcher._private();
final SftpGridPrefetcher sftpGridPrefetcher = SftpGridPrefetcher._private();

// keeps full-size bytes resident for a sliding window around the entry shown
// in the viewer: `windowAhead` ahead and `windowBehind` behind, in swipe direction.
// the window starts symmetric and only leans into a direction after two
// consecutive swipes the same way, so the first backward swipe is not a miss.
// when the index moves, whatever entered the window is enqueued (nearest first)
// and whatever left it is cancelled.
class SftpViewerPrefetcher {
  static const windowAhead = 3;
  static const windowBehind = 1;

  List<AvesEntry> Function()? _entries;
  ValueNotifier<AvesEntry?>? _entryNotifier;
  final Map<String, SftpTicket<Object?>> _tickets = {};
  int? _lastIndex;
  int _lastDelta = 0, _consecutiveSameWay = 0;

  SftpViewerPrefetcher._private();

  void attach(List<AvesEntry> Function() entries, ValueNotifier<AvesEntry?> entryNotifier) {
    detach();
    _entries = entries;
    _entryNotifier = entryNotifier;
    entryNotifier.addListener(_onEntryChanged);
    // entering the viewer suspends speculative grid fetching entirely
    sftpMediaService.viewerActive = true;
    _onEntryChanged();
  }

  void detach() {
    _entryNotifier?.removeListener(_onEntryChanged);
    _entries = null;
    _entryNotifier = null;
    _lastIndex = null;
    _lastDelta = 0;
    _consecutiveSameWay = 0;
    _cancelAll();
    sftpMediaService.viewerActive = false;
  }

  void _onEntryChanged() {
    final entry = _entryNotifier?.value;
    final entries = _entries?.call();
    if (entry == null || entries == null) return;

    final index = entries.indexOf(entry);
    if (index < 0) return;

    final lastIndex = _lastIndex;
    if (lastIndex != null && index != lastIndex) {
      final delta = index - lastIndex;
      _consecutiveSameWay = delta.sign == _lastDelta.sign ? _consecutiveSameWay + 1 : 1;
      _lastDelta = delta;
    }
    _lastIndex = index;

    final biased = _consecutiveSameWay >= 2;
    final sign = _lastDelta.sign == 0 ? 1 : _lastDelta.sign;
    // symmetric by default; asymmetric only once a direction is established
    final ahead = biased ? windowAhead : (windowAhead + windowBehind) ~/ 2;
    final behind = biased ? windowBehind : (windowAhead + windowBehind) - (windowAhead + windowBehind) ~/ 2;

    final wanted = <String, ({AvesEntry entry, int distance})>{};
    void want(int i, int distance) {
      if (i < 0 || i >= entries.length) return;
      final candidate = entries[i];
      if (candidate.origin != EntryOrigins.sftp) return;
      wanted[candidate.uri] = (entry: candidate, distance: distance);
    }

    want(index, 0);
    for (var d = 1; d <= max(ahead, behind); d++) {
      if (d <= ahead) want(index + sign * d, d);
      if (d <= behind) want(index - sign * d, d);
    }

    // cancel whatever just left the window
    _tickets.removeWhere((uri, ticket) {
      if (wanted.containsKey(uri)) return false;
      ticket.cancel();
      return true;
    });

    // enqueue whatever just entered it, nearest first
    wanted.forEach((uri, target) {
      if (_tickets.containsKey(uri)) return;
      unawaited(
        sftpMediaService
            .ensureFullFile(
              target.entry,
              priority: target.distance == 0 ? SftpRequestPriority.viewerCurrent : SftpRequestPriority.viewerNeighbor,
              order: target.distance,
              onTicket: (ticket) => _tickets[uri] = ticket,
            )
            .then((_) {}, onError: (Object _) {})
            .whenComplete(() => _tickets.remove(uri)),
      );
    });
  }

  void _cancelAll() {
    _tickets.values.toList().forEach((ticket) => ticket.cancel());
    _tickets.clear();
  }
}

// speculative thumbnail fetching roughly one screen ahead in the direction
// the grid is being scrolled. estimates entry indices from scroll fractions,
// which is approximate under section headers — good enough for speculation.
class SftpGridPrefetcher {
  static const _throttleInterval = Duration(milliseconds: 200);

  final Map<String, SftpPrefetchHandle> _handles = {};
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastPixels = 0;

  SftpGridPrefetcher._private();

  void onScroll(CollectionLens collection, {required double pixels, required double viewportDimension, required double maxScrollExtent}) {
    final now = DateTime.now();
    if (now.difference(_lastRun) < _throttleInterval) return;
    _lastRun = now;

    final scrollingDown = pixels >= _lastPixels;
    _lastPixels = pixels;

    final entries = collection.sortedEntries;
    if (entries.isEmpty || entries.first.origin != EntryOrigins.sftp) return;

    final totalExtent = maxScrollExtent + viewportDimension;
    if (totalExtent <= 0) return;

    final count = entries.length;
    final visibleFirst = (pixels / totalExtent * count).floor();
    final visibleLast = ((pixels + viewportDimension) / totalExtent * count).ceil();
    final screenCount = max(1, visibleLast - visibleFirst);

    final int bandFirst, bandLast;
    if (scrollingDown) {
      bandFirst = visibleLast;
      bandLast = visibleLast + screenCount;
    } else {
      bandFirst = visibleFirst - screenCount;
      bandLast = visibleFirst;
    }

    final wanted = <String, ({AvesEntry entry, int order})>{};
    for (var i = max(0, bandFirst); i < min(count, bandLast); i++) {
      final entry = entries[i];
      final order = scrollingDown ? i - bandFirst : bandLast - i;
      wanted[entry.uri] = (entry: entry, order: order);
    }

    // a fling past many cells cancels the queued work for the cells that went by
    _handles.removeWhere((uri, handle) {
      if (wanted.containsKey(uri)) return false;
      handle.cancel();
      return true;
    });

    wanted.forEach((uri, target) {
      if (_handles.containsKey(uri)) return;
      final handle = sftpMediaService.prefetchThumbnail(target.entry, order: target.order);
      if (handle != null) _handles[uri] = handle;
    });
  }

  void reset() {
    _handles.values.toList().forEach((handle) => handle.cancel());
    _handles.clear();
  }
}
