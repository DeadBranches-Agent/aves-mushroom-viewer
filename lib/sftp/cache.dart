import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final SftpCache sftpCache = SftpCache._private();

enum SftpCacheVariant { thumbnail, full }

// identifies one cached object. modification time and size are part of the
// identity, so an edited remote file invalidates its stale cache entries
// (they age out by LRU).
class SftpCacheKey {
  final String hostId;
  final String remotePath;
  final int mtimeSecs;
  final int sizeBytes;
  final SftpCacheVariant variant;

  const SftpCacheKey({
    required this.hostId,
    required this.remotePath,
    required this.mtimeSecs,
    required this.sizeBytes,
    required this.variant,
  });
}

class _SftpCacheEntry {
  final String hostId;
  final SftpCacheVariant variant;
  final File file;
  final int sizeBytes;

  const _SftpCacheEntry({
    required this.hostId,
    required this.variant,
    required this.file,
    required this.sizeBytes,
  });
}

// disk LRU cache for remote file bytes, in app-internal cache storage
// (invisible to MediaStore and other apps), shared by the grid and the viewer.
//
// layout: `<internal cache dir>/sftp/<variant>/<hostId>/<sha1(remotePath|mtime|size)>`
// two independent byte budgets, each evicted LRU on insert:
// - thumbnails (embedded previews): 200 MB
// - full images (original bytes, unmodified): 1 GB
// LRU order is tracked in memory and persisted through file modification times
// (`setLastModified` on hit); `init` rebuilds the index by scanning the directories.
class SftpCache {
  static const thumbnailBudgetBytes = 200 << 20;
  static const fullBudgetBytes = 1 << 30;

  static const _tempExtension = '.tmp';

  // byte budget per variant, overridable for tests
  final Map<SftpCacheVariant, int> budgetBytes = {
    SftpCacheVariant.thumbnail: thumbnailBudgetBytes,
    SftpCacheVariant.full: fullBudgetBytes,
  };

  // key: file path, in LRU order, least recently used first
  final Map<String, _SftpCacheEntry> _entries = {};
  final Map<SftpCacheVariant, int> _variantSizes = {};
  late String _sftpDir;

  SftpCache._private();

  // `rootDir`: the app-internal cache directory (from `storageService.getInternalCacheDirectory`)
  Future<void> init(String rootDir) async {
    _sftpDir = p.join(rootDir, 'sftp');
    _entries.clear();
    _variantSizes.clear();

    final found = <({_SftpCacheEntry entry, DateTime modified})>[];
    for (final variant in SftpCacheVariant.values) {
      final variantDir = Directory(p.join(_sftpDir, variant.name));
      if (!await variantDir.exists()) continue;

      for (final hostDir in await variantDir.list().toList()) {
        if (hostDir is! Directory) continue;

        final hostId = p.basename(hostDir.path);
        for (final file in await hostDir.list().toList()) {
          if (file is! File || file.path.endsWith(_tempExtension)) continue;

          final stat = await file.stat();
          found.add((
            entry: _SftpCacheEntry(
              hostId: hostId,
              variant: variant,
              file: file,
              sizeBytes: stat.size,
            ),
            modified: stat.modified,
          ));
        }
      }
    }

    mergeSort(found, compare: (a, b) => a.modified.compareTo(b.modified));
    found.forEach((v) => _index(v.entry));
  }

  // cached file for this key, or null; touches LRU order on hit
  File? get(SftpCacheKey key) {
    final path = _pathOf(key);
    final entry = _entries.remove(path);
    if (entry == null) return null;

    _entries[path] = entry;
    entry.file.setLastModifiedSync(DateTime.now());
    return entry.file;
  }

  // writes bytes (atomically: temp file + rename), updates the index, then
  // evicts least-recently-used entries of the same variant over budget
  Future<File> put(SftpCacheKey key, Uint8List bytes) async {
    final path = _pathOf(key);
    final file = File(path);
    await file.parent.create(recursive: true);

    final tempFile = File('$path$_tempExtension');
    await tempFile.writeAsBytes(bytes, flush: true);
    await tempFile.rename(path);

    _unindex(_entries[path]);
    _index(
      _SftpCacheEntry(
        hostId: key.hostId,
        variant: key.variant,
        file: file,
        sizeBytes: bytes.length,
      ),
    );
    await _evict(key.variant, keptPath: path);

    return file;
  }

  // current on-disk bytes for this host, both variants combined
  int sizeForHost(String hostId) => _entries.values.where((v) => v.hostId == hostId).fold(0, (sum, v) => sum + v.sizeBytes);

  Future<void> clearHost(String hostId) async {
    _entries.values.where((v) => v.hostId == hostId).toList().forEach(_unindex);

    for (final variant in SftpCacheVariant.values) {
      final hostDir = Directory(p.join(_sftpDir, variant.name, hostId));
      if (await hostDir.exists()) {
        await hostDir.delete(recursive: true);
      }
    }
  }

  String _pathOf(SftpCacheKey key) {
    final digest = sha1.convert(utf8.encode('${key.remotePath}|${key.mtimeSecs}|${key.sizeBytes}'));
    return p.join(_sftpDir, key.variant.name, key.hostId, '$digest');
  }

  void _index(_SftpCacheEntry entry) {
    _entries[entry.file.path] = entry;
    _variantSizes[entry.variant] = (_variantSizes[entry.variant] ?? 0) + entry.sizeBytes;
  }

  void _unindex(_SftpCacheEntry? entry) {
    if (entry == null) return;

    _entries.remove(entry.file.path);
    _variantSizes[entry.variant] = (_variantSizes[entry.variant] ?? 0) - entry.sizeBytes;
  }

  Future<void> _evict(SftpCacheVariant variant, {required String keptPath}) async {
    final budget = budgetBytes[variant]!;
    while ((_variantSizes[variant] ?? 0) > budget) {
      final victim = _entries.values.firstWhereOrNull((v) => v.variant == variant && v.file.path != keptPath);
      if (victim == null) return;

      _unindex(victim);
      await victim.file.delete();
    }
  }
}
