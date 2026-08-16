import 'dart:io';
import 'dart:typed_data';

import 'package:aves/sftp/cache.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory rootDir;

  SftpCacheKey keyOf(
    String remotePath, {
    String hostId = 'host1',
    int mtimeSecs = 1000,
    int sizeBytes = 42,
    SftpCacheVariant variant = SftpCacheVariant.thumbnail,
  }) {
    return SftpCacheKey(
      hostId: hostId,
      remotePath: remotePath,
      mtimeSecs: mtimeSecs,
      sizeBytes: sizeBytes,
      variant: variant,
    );
  }

  Uint8List bytesOf(int length, [int fill = 7]) => Uint8List.fromList(List.filled(length, fill));

  setUp(() async {
    rootDir = await Directory.systemTemp.createTemp('aves_sftp_cache_test');
    await sftpCache.init(rootDir.path);
    sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = SftpCache.thumbnailBudgetBytes;
    sftpCache.budgetBytes[SftpCacheVariant.full] = SftpCache.fullBudgetBytes;
  });

  tearDown(() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  });

  group('get/put', () {
    test('misses on an empty cache', () {
      expect(sftpCache.get(keyOf('/remote/a.jpg')), null);
    });

    test('hits after put and returns the stored bytes', () async {
      final key = keyOf('/remote/a.jpg');
      final bytes = bytesOf(64, 3);
      final put = await sftpCache.put(key, bytes);
      expect(await put.exists(), true);

      final hit = sftpCache.get(key);
      expect(hit, isNotNull);
      expect(hit!.path, put.path);
      expect(await hit.readAsBytes(), bytes);
    });

    test('lays out files by variant and host', () async {
      final file = await sftpCache.put(keyOf('/remote/a.jpg', hostId: 'someHost', variant: SftpCacheVariant.full), bytesOf(8));
      expect(p.basename(file.parent.path), 'someHost');
      expect(p.basename(file.parent.parent.path), 'full');
      expect(p.basename(file.parent.parent.parent.path), 'sftp');
      expect(file.parent.parent.parent.parent.path, rootDir.path);
      // sha1 hex digest
      expect(p.basename(file.path), matches(RegExp(r'^[0-9a-f]{40}$')));
    });

    test('leaves no temporary file behind', () async {
      await sftpCache.put(keyOf('/remote/a.jpg'), bytesOf(8));
      final files = Directory(p.join(rootDir.path, 'sftp', 'thumbnail', 'host1')).listSync();
      expect(files.length, 1);
      expect(p.basename(files.first.path).endsWith('.tmp'), false);
    });

    test('replacing bytes for the same key does not double count', () async {
      final key = keyOf('/remote/a.jpg');
      await sftpCache.put(key, bytesOf(100));
      expect(sftpCache.sizeForHost('host1'), 100);

      await sftpCache.put(key, bytesOf(30));
      expect(sftpCache.sizeForHost('host1'), 30);
      expect(await sftpCache.get(key)!.readAsBytes(), bytesOf(30));
    });
  });

  group('key identity', () {
    test('a different modification time misses', () async {
      await sftpCache.put(keyOf('/remote/a.jpg', mtimeSecs: 1000), bytesOf(8));
      expect(sftpCache.get(keyOf('/remote/a.jpg', mtimeSecs: 1000)), isNotNull);
      expect(sftpCache.get(keyOf('/remote/a.jpg', mtimeSecs: 1001)), null);
    });

    test('a different size misses', () async {
      await sftpCache.put(keyOf('/remote/a.jpg', sizeBytes: 42), bytesOf(8));
      expect(sftpCache.get(keyOf('/remote/a.jpg', sizeBytes: 43)), null);
    });

    test('a different remote path misses', () async {
      await sftpCache.put(keyOf('/remote/a.jpg'), bytesOf(8));
      expect(sftpCache.get(keyOf('/remote/b.jpg')), null);
    });

    test('variants and hosts are stored separately', () async {
      final thumbnailKey = keyOf('/remote/a.jpg');
      final fullKey = keyOf('/remote/a.jpg', variant: SftpCacheVariant.full);
      final otherHostKey = keyOf('/remote/a.jpg', hostId: 'host2');
      await sftpCache.put(thumbnailKey, bytesOf(8, 1));
      expect(sftpCache.get(fullKey), null);
      expect(sftpCache.get(otherHostKey), null);

      await sftpCache.put(fullKey, bytesOf(16, 2));
      await sftpCache.put(otherHostKey, bytesOf(32, 3));
      expect(await sftpCache.get(thumbnailKey)!.readAsBytes(), bytesOf(8, 1));
      expect(await sftpCache.get(fullKey)!.readAsBytes(), bytesOf(16, 2));
      expect(await sftpCache.get(otherHostKey)!.readAsBytes(), bytesOf(32, 3));
    });
  });

  group('eviction', () {
    test('evicts the least recently used entry of the variant', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 300;
      final keys = [0, 1, 2, 3].map((i) => keyOf('/remote/$i.jpg')).toList();
      for (final key in keys.take(3)) {
        await sftpCache.put(key, bytesOf(100));
      }
      expect(sftpCache.sizeForHost('host1'), 300);

      await sftpCache.put(keys[3], bytesOf(100));
      expect(sftpCache.sizeForHost('host1'), 300);
      expect(sftpCache.get(keys[0]), null);
      expect(sftpCache.get(keys[1]), isNotNull);
      expect(sftpCache.get(keys[2]), isNotNull);
      expect(sftpCache.get(keys[3]), isNotNull);

      final files = Directory(p.join(rootDir.path, 'sftp', 'thumbnail', 'host1')).listSync();
      expect(files.length, 3);
    });

    test('a hit protects an entry from eviction', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 300;
      final keys = [0, 1, 2, 3].map((i) => keyOf('/remote/$i.jpg')).toList();
      for (final key in keys.take(3)) {
        await sftpCache.put(key, bytesOf(100));
      }
      expect(sftpCache.get(keys[0]), isNotNull);

      await sftpCache.put(keys[3], bytesOf(100));
      expect(sftpCache.get(keys[0]), isNotNull);
      expect(sftpCache.get(keys[1]), null);
    });

    test('evicts several entries at once when needed', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 300;
      final keys = [0, 1, 2, 3].map((i) => keyOf('/remote/$i.jpg')).toList();
      for (final key in keys.take(3)) {
        await sftpCache.put(key, bytesOf(100));
      }

      await sftpCache.put(keys[3], bytesOf(150));
      expect(sftpCache.sizeForHost('host1'), 150 + 100);
      expect(sftpCache.get(keys[0]), null);
      expect(sftpCache.get(keys[1]), null);
      expect(sftpCache.get(keys[2]), isNotNull);
      expect(sftpCache.get(keys[3]), isNotNull);
    });

    test('keeps an oversized fresh entry rather than evicting itself', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 300;
      final small = keyOf('/remote/small.jpg');
      final huge = keyOf('/remote/huge.jpg');
      await sftpCache.put(small, bytesOf(100));

      await sftpCache.put(huge, bytesOf(500));
      expect(sftpCache.get(small), null);
      expect(sftpCache.get(huge), isNotNull);
    });

    test('budgets are independent per variant', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 200;
      sftpCache.budgetBytes[SftpCacheVariant.full] = 1000;

      final fullKeys = [0, 1].map((i) => keyOf('/remote/full$i.jpg', variant: SftpCacheVariant.full)).toList();
      for (final key in fullKeys) {
        await sftpCache.put(key, bytesOf(400));
      }

      final thumbnailKeys = [0, 1, 2].map((i) => keyOf('/remote/thumb$i.jpg')).toList();
      for (final key in thumbnailKeys) {
        await sftpCache.put(key, bytesOf(100));
      }

      expect(sftpCache.get(thumbnailKeys[0]), null);
      expect(sftpCache.get(thumbnailKeys[1]), isNotNull);
      expect(sftpCache.get(thumbnailKeys[2]), isNotNull);
      expect(fullKeys.every((key) => sftpCache.get(key) != null), true);
    });

    test('the variant budget spans all hosts', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 200;
      final key1 = keyOf('/remote/a.jpg', hostId: 'host1');
      final key2 = keyOf('/remote/b.jpg', hostId: 'host2');
      final key3 = keyOf('/remote/c.jpg', hostId: 'host3');
      await sftpCache.put(key1, bytesOf(100));
      await sftpCache.put(key2, bytesOf(100));
      await sftpCache.put(key3, bytesOf(100));

      expect(sftpCache.get(key1), null);
      expect(sftpCache.sizeForHost('host1'), 0);
      expect(sftpCache.sizeForHost('host2'), 100);
      expect(sftpCache.sizeForHost('host3'), 100);
    });
  });

  group('sizeForHost', () {
    test('sums both variants for that host only', () async {
      await sftpCache.put(keyOf('/remote/a.jpg', hostId: 'host1'), bytesOf(10));
      await sftpCache.put(keyOf('/remote/b.jpg', hostId: 'host1', variant: SftpCacheVariant.full), bytesOf(20));
      await sftpCache.put(keyOf('/remote/c.jpg', hostId: 'host2'), bytesOf(40));

      expect(sftpCache.sizeForHost('host1'), 30);
      expect(sftpCache.sizeForHost('host2'), 40);
      expect(sftpCache.sizeForHost('unknown'), 0);
    });
  });

  group('clearHost', () {
    test('removes files and index entries of that host only', () async {
      final gone = keyOf('/remote/a.jpg', hostId: 'host1');
      final goneFull = keyOf('/remote/b.jpg', hostId: 'host1', variant: SftpCacheVariant.full);
      final kept = keyOf('/remote/c.jpg', hostId: 'host2');
      await sftpCache.put(gone, bytesOf(10));
      await sftpCache.put(goneFull, bytesOf(20));
      await sftpCache.put(kept, bytesOf(40));

      await sftpCache.clearHost('host1');
      expect(sftpCache.get(gone), null);
      expect(sftpCache.get(goneFull), null);
      expect(sftpCache.get(kept), isNotNull);
      expect(sftpCache.sizeForHost('host1'), 0);
      expect(sftpCache.sizeForHost('host2'), 40);
      expect(Directory(p.join(rootDir.path, 'sftp', 'thumbnail', 'host1')).existsSync(), false);
      expect(Directory(p.join(rootDir.path, 'sftp', 'full', 'host1')).existsSync(), false);
      expect(Directory(p.join(rootDir.path, 'sftp', 'thumbnail', 'host2')).existsSync(), true);
    });

    test('clearing frees room in the budget', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 200;
      final key1 = keyOf('/remote/a.jpg', hostId: 'host1');
      final key2 = keyOf('/remote/b.jpg', hostId: 'host2');
      await sftpCache.put(key1, bytesOf(100));
      await sftpCache.clearHost('host1');
      await sftpCache.put(key2, bytesOf(200));

      expect(sftpCache.get(key2), isNotNull);
      expect(sftpCache.sizeForHost('host2'), 200);
    });

    test('clearing an unknown host is harmless', () async {
      await sftpCache.put(keyOf('/remote/a.jpg'), bytesOf(10));
      await sftpCache.clearHost('unknown');
      expect(sftpCache.sizeForHost('host1'), 10);
    });
  });

  group('init', () {
    test('rebuilds the index from disk', () async {
      final keys = [
        keyOf('/remote/a.jpg'),
        keyOf('/remote/b.jpg', variant: SftpCacheVariant.full),
        keyOf('/remote/c.jpg', hostId: 'host2'),
      ];
      await sftpCache.put(keys[0], bytesOf(10));
      await sftpCache.put(keys[1], bytesOf(20));
      await sftpCache.put(keys[2], bytesOf(40));

      await sftpCache.init(rootDir.path);
      expect(sftpCache.get(keys[0]), isNotNull);
      expect(sftpCache.get(keys[1]), isNotNull);
      expect(sftpCache.get(keys[2]), isNotNull);
      expect(sftpCache.sizeForHost('host1'), 30);
      expect(sftpCache.sizeForHost('host2'), 40);
    });

    test('starts empty on a fresh root', () async {
      final otherRoot = await Directory.systemTemp.createTemp('aves_sftp_cache_test_other');
      await sftpCache.put(keyOf('/remote/a.jpg'), bytesOf(10));

      await sftpCache.init(otherRoot.path);
      expect(sftpCache.get(keyOf('/remote/a.jpg')), null);
      expect(sftpCache.sizeForHost('host1'), 0);

      await otherRoot.delete(recursive: true);
    });

    test('restores LRU order from file modification times', () async {
      sftpCache.budgetBytes[SftpCacheVariant.thumbnail] = 300;
      final keys = [0, 1, 2, 3].map((i) => keyOf('/remote/$i.jpg')).toList();
      final files = <File>[];
      for (final key in keys.take(3)) {
        files.add(await sftpCache.put(key, bytesOf(100)));
      }

      // 0 used more recently than 2, itself more recent than 1
      final now = DateTime.now();
      files[1].setLastModifiedSync(now.subtract(const Duration(minutes: 30)));
      files[2].setLastModifiedSync(now.subtract(const Duration(minutes: 20)));
      files[0].setLastModifiedSync(now.subtract(const Duration(minutes: 10)));

      await sftpCache.init(rootDir.path);
      await sftpCache.put(keys[3], bytesOf(100));
      expect(sftpCache.get(keys[1]), null);
      expect(sftpCache.get(keys[0]), isNotNull);
      expect(sftpCache.get(keys[2]), isNotNull);
    });

    test('ignores leftover temporary files', () async {
      final key = keyOf('/remote/a.jpg');
      final file = await sftpCache.put(key, bytesOf(10));
      File('${file.path}.tmp').writeAsBytesSync(bytesOf(999));

      await sftpCache.init(rootDir.path);
      expect(sftpCache.sizeForHost('host1'), 10);
      expect(sftpCache.get(key), isNotNull);
    });
  });
}
