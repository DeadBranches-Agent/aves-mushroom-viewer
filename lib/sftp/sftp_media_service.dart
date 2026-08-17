import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aves/image_providers/thumbnail_provider.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/extensions/keys.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/metadata/catalog.dart';
import 'package:aves/model/source/collection_source.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/sftp/cache.dart';
import 'package:aves/sftp/connection.dart';
import 'package:aves/sftp/model/sftp_host.dart';
import 'package:aves/sftp/prefs.dart';
import 'package:aves/sftp/preview_extractor.dart';
import 'package:aves/sftp/scheduler.dart';
import 'package:aves/services/common/decoding.dart';
import 'package:aves/services/common/services.dart';
import 'package:aves/widgets/aves_app.dart';
import 'package:collection/collection.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

final SftpMediaService sftpMediaService = SftpMediaService._private();

// facade tying together connection pool, per-host schedulers and the shared cache.
// `PlatformMediaFetchService` delegates here for `sftp` scheme URIs, and the
// source loading/refresh logic keeps the entry registry up to date.
class SftpMediaService {
  static const _scheme = 'sftp';
  static const _schemePrefix = '$_scheme://';
  static const _headerReadLength = 128 << 10;
  // an implausibly large "preview" means a corrupt pointer, not a preview
  static const _maxPreviewLength = 8 << 20;
  static const _formatByteEncoded = 0xCA;

  // remote images are filtered to types the app is known to decode from plain files
  static const Map<String, String> _mimeByExtension = {
    '.jpg': MimeTypes.jpeg,
    '.jpeg': MimeTypes.jpeg,
    '.png': MimeTypes.png,
    '.gif': MimeTypes.gif,
    '.webp': MimeTypes.webp,
    '.bmp': MimeTypes.bmp,
    '.heic': MimeTypes.heic,
    '.heif': MimeTypes.heif,
    '.avif': MimeTypes.avif,
    '.tif': MimeTypes.tiff,
    '.tiff': MimeTypes.tiff,
  };

  final Map<String, SftpScheduler> _schedulers = {};
  final Map<String, AvesEntry> _entriesByUri = {};
  final Map<Object, _SftpThumbRequest> _thumbRequests = {};
  final Set<String> _refreshingHostIds = {};
  late final String _albumRoot;
  bool _initialized = false;

  SftpMediaService._private();

  static bool isSftpUri(String uri) => uri.startsWith(_schemePrefix);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    final vaultRoot = await storageService.getVaultRoot();
    _albumRoot = pContext.join(pContext.dirname(pContext.normalize(vaultRoot)), 'sftp');
    await sftpHosts.init();
    await sftpPrefs.init();
    sftpConnectionPool.init(AvesApp.lifecycleStateNotifier);
    await sftpCache.init(await storageService.getInternalCacheDirectory());
  }

  // entry URIs look like `sftp://<hostId>/<remote path>`
  static String uriFor(SftpHost host, String remotePath) => Uri(scheme: _scheme, host: host.id, path: remotePath).toString();

  static String? hostIdOfUri(String uri) => isSftpUri(uri) ? Uri.parse(uri).host : null;

  static String remotePathOfUri(String uri) => '/${Uri.parse(uri).pathSegments.join('/')}';

  // synthetic directory that makes entries of this host group into an album
  String albumPathFor(SftpHost host) => pContext.join(_albumRoot, host.name);

  // album paths of all configured hosts, so their albums stay visible even when
  // empty. safe to call before `init` (some source callbacks may fire early).
  Set<String> allAlbumPaths() => _initialized ? sftpHosts.all.map(albumPathFor).toSet() : const {};

  bool isSftpAlbumPath(String dirPath) => _initialized && pContext.isWithin(_albumRoot, dirPath);

  SftpHost? hostOfAlbumPath(String dirPath) => sftpHosts.all.firstWhereOrNull((host) => albumPathFor(host) == dirPath);

  // called by the source when loading or creating entries of `EntryOrigins.sftp`,
  // so that byte requests (which only carry a URI) can resolve entry attributes
  void registerEntries(Iterable<AvesEntry> entries) => entries.forEach((entry) => _entriesByUri[entry.uri] = entry);

  set viewerActive(bool active) => _schedulers.values.forEach((scheduler) => scheduler.viewerActive = active);

  SftpScheduler schedulerFor(String hostId) => _schedulers.putIfAbsent(hostId, () => SftpScheduler(hostId));

  // lists the remote directory (images only, no recursion), diffs against the
  // known entries and updates `source` + the local media DB.
  // network/auth errors propagate to the caller (surfaced by the UI).
  // returns the listed image count, so the UI can tell "empty" from "in sync",
  // or null when a refresh of this host is already running.
  Future<int?> refreshHost(SftpHost host, CollectionSource source) async {
    if (!_refreshingHostIds.add(host.id)) return null;
    try {
      final names = await _withClient(host, (client) => client.listdir(host.directory));

      final listed = <String, ({SftpName name, String mimeType})>{};
      names.where((name) => name.attr.type == SftpFileType.regularFile).forEach((name) {
        final mimeType = _mimeByExtension[pContext.extension(name.filename).toLowerCase()];
        if (mimeType != null) {
          listed[uriFor(host, '${host.directory}${host.directory.endsWith('/') ? '' : '/'}${name.filename}')] = (name: name, mimeType: mimeType);
        }
      });

      final knownByUri = {
        for (final entry in source.allEntries.where((entry) => entry.origin == EntryOrigins.sftp && hostIdOfUri(entry.uri) == host.id)) entry.uri: entry,
      };

      final albumPath = albumPathFor(host);
      final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final removedUris = knownByUri.keys.where((uri) => !listed.containsKey(uri)).toSet();
      final newEntries = <AvesEntry>{};
      listed.forEach((uri, file) {
        final attr = file.name.attr;
        final mtimeMillis = (attr.modifyTime ?? 0) * 1000;
        final sizeBytes = attr.size ?? 0;
        final known = knownByUri[uri];
        if (known != null) {
          if (known.dateModifiedMillis == mtimeMillis && known.sizeBytes == sizeBytes && known.path == pContext.join(albumPath, file.name.filename)) return;
          // remote file changed (or the host was renamed, moving its synthetic album):
          // replace the entry, so caches keyed on mtime/size refresh and the album path follows
          removedUris.add(uri);
        }

        final id = localMediaDb.nextId;
        final entry = AvesEntry(
          id: id,
          uri: uri,
          path: pContext.join(albumPath, file.name.filename),
          contentId: null,
          pageId: null,
          sourceMimeType: file.mimeType,
          width: 0,
          height: 0,
          sourceRotationDegrees: 0,
          sizeBytes: sizeBytes,
          sourceTitle: null,
          dateAddedSecs: nowSecs,
          dateModifiedMillis: mtimeMillis,
          sourceDateTakenMillis: null,
          durationMillis: null,
          trashed: false,
          origin: EntryOrigins.sftp,
        );
        // remote entries are not analyzable through the platform metadata pipeline,
        // so they are stamped as catalogued upfront, dated by remote modification time
        entry.catalogMetadata = CatalogMetadata(id: id, dateMillis: mtimeMillis);
        newEntries.add(entry);
      });

      if (removedUris.isNotEmpty) {
        removedUris.forEach(_entriesByUri.remove);
        await source.removeEntries(removedUris, includeTrash: false);
      }
      if (newEntries.isNotEmpty) {
        await localMediaDb.insertEntries(newEntries);
        await localMediaDb.saveCatalogMetadata(newEntries.map((entry) => entry.catalogMetadata!).toSet());
        registerEntries(newEntries);
        source.addEntries(newEntries);
      }
      return listed.length;
    } finally {
      _refreshingHostIds.remove(host.id);
    }
  }

  // thumbnail codec for the grid, served in order of preference from:
  // cached full file (platform-decoded), cached preview bytes, embedded EXIF
  // preview from a ranged header read (JPEG), or a lowest-priority full download.
  Future<ui.Codec> getThumbnail({
    required ThumbnailProviderKey request,
    ImageDecoderCallback? decode,
    Object? taskKey,
  }) {
    final thumbRequest = _SftpThumbRequest(this, request, decode);
    if (taskKey != null) {
      _thumbRequests[taskKey] = thumbRequest;
      thumbRequest.completer.future.whenComplete(() {
        if (identical(_thumbRequests[taskKey], thumbRequest)) {
          _thumbRequests.remove(taskKey);
        }
      }).ignore();
    }
    thumbRequest.start();
    return thumbRequest.completer.future;
  }

  // pauses the underlying remote read, keeping the request resumable.
  // mirrors `servicePolicy` pause/resume semantics for local entries.
  bool cancelThumbnail(Object taskKey) {
    final thumbRequest = _thumbRequests[taskKey];
    if (thumbRequest == null) return false;

    thumbRequest.pause();
    return true;
  }

  bool resumeLoading(Object taskKey) {
    final thumbRequest = _thumbRequests[taskKey];
    if (thumbRequest == null) return false;

    thumbRequest.resume();
    return true;
  }

  // original bytes, unmodified
  Future<Uint8List> getFullBytes(AvesEntry entry) async {
    final file = await ensureFullFile(entry, priority: SftpRequestPriority.viewerCurrent);
    return await file.readAsBytes();
  }

  // downloads (or finds cached) original bytes and returns a local `file://` URI,
  // for substitution into platform ops (viewer full image, regions)
  Future<String> localUriForRequest(String uri, {BytesReceivedCallback? onBytesReceived}) async {
    final entry = _entriesByUri[uri];
    if (entry == null) throw StateError('unknown remote entry for uri=$uri');

    final file = await ensureFullFile(entry, priority: SftpRequestPriority.viewerCurrent, onBytesReceived: onBytesReceived);
    return Uri.file(file.path).toString();
  }

  Future<File> ensureFullFile(
    AvesEntry entry, {
    required SftpRequestPriority priority,
    int order = 0,
    BytesReceivedCallback? onBytesReceived,
    void Function(SftpTicket<Object?> ticket)? onTicket,
  }) async {
    final cacheKey = _cacheKey(entry, SftpCacheVariant.full);
    final cached = sftpCache.get(cacheKey);
    if (cached != null) return cached;

    final host = _hostOfEntry(entry);
    final sizeBytes = entry.sizeBytes;
    final ticket = schedulerFor(host.id).submit<File>(
      key: 'full:${entry.uri}',
      priority: priority,
      order: order,
      task: (token) async {
        final bytes = await _readRemote(
          host,
          path: remotePathOfUri(entry.uri),
          token: token,
          onBytesReceived: onBytesReceived == null ? null : (received) => onBytesReceived(received, sizeBytes),
        );
        final file = await sftpCache.put(cacheKey, bytes);
        if (entry.width == 0) {
          unawaited(_applySizeFromFile(entry, file));
        }
        return file;
      },
    );
    onTicket?.call(ticket);
    return await ticket.future;
  }

  // deletes the given remote entries on their servers — permanently, or by
  // moving them into a `.trash` subdirectory of the host directory when
  // `sftpPrefs.deleteToRemoteTrash` is set — then removes the successfully
  // deleted entries from `source` and the local media DB.
  // per-entry failures are collected, not thrown, so one bad file does not
  // abort the rest of a selection; the first error is returned for feedback.
  Future<({Set<String> deletedUris, Object? firstError})> deleteEntries(Iterable<AvesEntry> entries, CollectionSource source) async {
    final deletedUris = <String>{};
    Object? firstError;

    final byHostId = groupBy(entries.where((entry) => entry.origin == EntryOrigins.sftp), (entry) => hostIdOfUri(entry.uri));
    for (final MapEntry(key: hostId, value: hostEntries) in byHostId.entries) {
      final host = sftpHosts.byId(hostId ?? '');
      if (host == null) {
        firstError ??= StateError('unknown remote host for id=$hostId');
        continue;
      }

      final toTrash = sftpPrefs.deleteToRemoteTrash;
      var trashDirEnsured = false;
      for (final entry in hostEntries) {
        final remotePath = remotePathOfUri(entry.uri);
        try {
          await _withClient(host, (client) async {
            if (toTrash) {
              final trashDir = '${host.directory}${host.directory.endsWith('/') ? '' : '/'}.trash';
              if (!trashDirEnsured) {
                // probe with `stat` rather than an unconditional `mkdir`, so a
                // real mkdir failure (e.g. permission denied) surfaces as its
                // own specific error instead of a puzzling rename failure
                try {
                  await client.stat(trashDir);
                } on SftpStatusError catch (e) {
                  if (e.code != SftpStatusCode.noSuchFile) rethrow;
                  await client.mkdir(trashDir);
                }
                trashDirEnsured = true;
              }
              final filename = pContext.basename(remotePath);
              try {
                await client.rename(remotePath, '$trashDir/$filename');
              } on SftpStatusError {
                // a same-named file may already sit in the trash; retry once
                // under a name made unique by the deletion time
                final extension = pContext.extension(filename);
                final stem = pContext.basenameWithoutExtension(filename);
                await client.rename(remotePath, '$trashDir/$stem.${DateTime.now().millisecondsSinceEpoch}$extension');
              }
            } else {
              await client.remove(remotePath);
            }
          });
          deletedUris.add(entry.uri);
        } catch (error) {
          firstError ??= error;
        }
      }
    }

    if (deletedUris.isNotEmpty) {
      deletedUris.forEach(_entriesByUri.remove);
      await source.removeEntries(deletedUris, includeTrash: false);
    }
    return (deletedUris: deletedUris, firstError: firstError);
  }

  // removes this host's entries from `source` and the local media DB,
  // and clears its caches. used when removing a host.
  Future<void> removeHostData(SftpHost host, CollectionSource source) async {
    _schedulers.remove(host.id)?.dispose();
    sftpConnectionPool.invalidate(host.id);

    final uris = _entriesByUri.keys.where((uri) => hostIdOfUri(uri) == host.id).toSet();
    uris.forEach(_entriesByUri.remove);
    await source.removeEntries(uris, includeTrash: false);
    await sftpCache.clearHost(host.id);
  }

  Future<ui.Codec> _loadThumbnailCodec(_SftpThumbRequest thumbRequest) async {
    final request = thumbRequest.request;
    final entry = _entriesByUri[request.uri];
    if (entry == null) throw StateError('unknown remote entry for uri=${request.uri}');

    final fullFile = sftpCache.get(_cacheKey(entry, SftpCacheVariant.full));
    if (fullFile != null) return _platformThumbnail(request, fullFile, thumbRequest.decode);

    final thumbFile = sftpCache.get(_cacheKey(entry, SftpCacheVariant.thumbnail));
    if (thumbFile != null) return _codecFromEncodedBytes(await thumbFile.readAsBytes(), thumbRequest.decode);

    if (entry.mimeType == MimeTypes.jpeg) {
      final host = _hostOfEntry(entry);
      final ticket = schedulerFor(host.id).submit<Uint8List?>(
        key: 'thumb:${entry.uri}',
        priority: SftpRequestPriority.visibleThumbnail,
        task: (token) => _fetchEmbeddedPreview(host, entry, token),
      );
      thumbRequest.ticket = ticket;
      final preview = await ticket.future;
      if (preview != null) return _codecFromEncodedBytes(preview, thumbRequest.decode);
    }

    // no shortcut: the whole file comes down, at the lowest priority in the queue,
    // and its original bytes stay cached so the viewer gets the image for free later
    final file = await ensureFullFile(
      entry,
      priority: SftpRequestPriority.speculativeThumbnail,
      onTicket: (ticket) => thumbRequest.ticket = ticket,
    );
    return _platformThumbnail(request, file, thumbRequest.decode);
  }

  // fetches thumbnail bytes without producing a codec, for speculative prefetch.
  // returns a cancellable handle, or null when the bytes are already cached.
  SftpPrefetchHandle? prefetchThumbnail(AvesEntry entry, {required int order}) {
    if (sftpCache.get(_cacheKey(entry, SftpCacheVariant.full)) != null) return null;
    if (sftpCache.get(_cacheKey(entry, SftpCacheVariant.thumbnail)) != null) return null;

    final handle = SftpPrefetchHandle();
    unawaited(_prefetchThumbnail(entry, order: order, handle: handle).then((_) {}, onError: (_) {}));
    return handle;
  }

  Future<void> _prefetchThumbnail(AvesEntry entry, {required int order, required SftpPrefetchHandle handle}) async {
    final host = _hostOfEntry(entry);
    if (entry.mimeType == MimeTypes.jpeg) {
      final ticket = schedulerFor(host.id).submit<Uint8List?>(
        key: 'thumb:${entry.uri}',
        priority: SftpRequestPriority.speculativeThumbnail,
        order: order,
        task: (token) => _fetchEmbeddedPreview(host, entry, token),
      );
      if (!handle.attach(ticket)) return;
      if (await ticket.future != null) return;
      if (handle.cancelled) return;
    }
    await ensureFullFile(
      entry,
      priority: SftpRequestPriority.speculativeThumbnail,
      order: order,
      onTicket: (ticket) => handle.attach(ticket),
    );
  }

  Future<Uint8List?> _fetchEmbeddedPreview(SftpHost host, AvesEntry entry, SftpCancelToken token) async {
    final remotePath = remotePathOfUri(entry.uri);
    final sizeBytes = entry.sizeBytes ?? 0;
    final headerLength = sizeBytes > 0 ? min(_headerReadLength, sizeBytes) : _headerReadLength;
    final header = await _readRemote(host, path: remotePath, length: headerLength, token: token);
    final inspection = JpegPreviewExtractor.inspect(header);

    final newFields = <String, Object?>{};
    if (inspection.width != null && entry.width == 0) {
      newFields[EntryFields.width] = inspection.width;
      newFields[EntryFields.height] = inspection.height;
    }
    final rotationDegrees = inspection.rotationDegrees;
    if (rotationDegrees != null && (rotationDegrees != entry.sourceRotationDegrees || inspection.isFlipped != entry.isFlipped)) {
      newFields[EntryFields.sourceRotationDegrees] = rotationDegrees;
    }
    if (newFields.isNotEmpty) {
      await entry.applyNewFields(newFields, persist: true);
      // dimension-only changes do not trigger the visual notifier by themselves
      entry.visualChangeNotifier.notify();
    }

    var preview = inspection.previewBytes;
    if (preview == null) {
      final offset = inspection.previewOffset;
      final length = inspection.previewLength;
      if (offset == null || length == null || length > _maxPreviewLength || (sizeBytes > 0 && offset + length > sizeBytes)) return null;

      token.ensureActive();
      preview = await _readRemote(host, path: remotePath, offset: offset, length: length, token: token);
      if (preview.length < length) return null;
    }

    final oriented = _withBakedOrientation(preview, rotationDegrees ?? 0, inspection.isFlipped);
    await sftpCache.put(_cacheKey(entry, SftpCacheVariant.thumbnail), oriented);
    return oriented;
  }

  // routes the request through the regular platform pipeline against the cached local file,
  // so decoding, orientation and Glide thumbnail caching behave as for local entries
  Future<ui.Codec> _platformThumbnail(ThumbnailProviderKey request, File file, ImageDecoderCallback? decode) {
    return mediaFetchService.getThumbnail(
      decoded: false,
      request: ThumbnailProviderKey(
        uri: Uri.file(file.path).toString(),
        mimeType: request.mimeType,
        pageId: request.pageId,
        rotationDegrees: request.rotationDegrees,
        isFlipped: request.isFlipped,
        dateModifiedMillis: request.dateModifiedMillis,
        extent: request.extent,
      ),
      decode: decode,
    );
  }

  Future<ui.Codec> _codecFromEncodedBytes(Uint8List bytes, ImageDecoderCallback? decode) async {
    final withTrailer = Uint8List(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = _formatByteEncoded;
    final codec = await InteropDecoding.encodedBytesToCodec(
      withTrailer,
      decode ?? (buffer, {getTargetSize}) => PaintingBinding.instance.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize),
    );
    if (codec == null) throw StateError('failed to decode remote thumbnail bytes');
    return codec;
  }

  SftpHost _hostOfEntry(AvesEntry entry) {
    final host = sftpHosts.byId(hostIdOfUri(entry.uri) ?? '');
    if (host == null) throw StateError('unknown remote host for uri=${entry.uri}');
    return host;
  }

  SftpCacheKey _cacheKey(AvesEntry entry, SftpCacheVariant variant) => SftpCacheKey(
    hostId: hostIdOfUri(entry.uri)!,
    remotePath: remotePathOfUri(entry.uri),
    mtimeSecs: (entry.dateModifiedMillis ?? 0) ~/ 1000,
    sizeBytes: entry.sizeBytes ?? 0,
    variant: variant,
  );

  Future<Uint8List> _readRemote(
    SftpHost host, {
    required String path,
    int offset = 0,
    int? length,
    required SftpCancelToken token,
    void Function(int receivedBytes)? onBytesReceived,
  }) {
    return _withClient(host, (client) async {
      final file = await client.open(path);
      try {
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in file.read(offset: offset, length: length)) {
          token.ensureActive();
          buffer.add(chunk);
          onBytesReceived?.call(buffer.length);
        }
        return buffer.takeBytes();
      } finally {
        unawaited(file.close());
      }
    });
  }

  // the network is a real boundary: on a dropped connection, reconnect and retry once
  Future<T> _withClient<T>(SftpHost host, Future<T> Function(SftpClient client) body) async {
    final client = await sftpConnectionPool.clientFor(host);
    try {
      return await body(client);
    } catch (error) {
      sftpConnectionPool.invalidate(host.id);
      if (error is SocketException || error is TimeoutException || error is SftpAbortError) {
        final freshClient = await sftpConnectionPool.clientFor(host);
        return await body(freshClient);
      }
      rethrow;
    }
  }

  Future<void> _applySizeFromFile(AvesEntry entry, File file) async {
    final probed = await mediaFetchService.getEntry(Uri.file(file.path).toString(), entry.mimeType);
    if (probed == null || probed.width == 0) return;

    await entry.applyNewFields({
      EntryFields.width: probed.width,
      EntryFields.height: probed.height,
      EntryFields.sourceRotationDegrees: probed.sourceRotationDegrees,
    }, persist: true);
    entry.visualChangeNotifier.notify();
  }

  // EXIF IFD1 previews carry no orientation of their own; injecting a minimal
  // EXIF APP1 with the main image's orientation makes decoders show them upright
  static Uint8List _withBakedOrientation(Uint8List jpegBytes, int rotationDegrees, bool isFlipped) {
    final code = _orientationCode(rotationDegrees, isFlipped);
    if (code == 1) return jpegBytes;
    if (jpegBytes.length < 2 || jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8) return jpegBytes;

    // APP1 payload: `Exif\0\0` + TIFF header (big endian) + IFD0 with a single orientation entry
    final payload = ByteData(6 + 8 + 2 + 12 + 4);
    payload.setUint32(0, 0x45786966); // Exif
    payload.setUint16(4, 0);
    payload.setUint16(6, 0x4D4D); // big endian
    payload.setUint16(8, 42);
    payload.setUint32(10, 8); // IFD0 offset
    payload.setUint16(14, 1); // entry count
    payload.setUint16(16, 0x0112); // orientation tag
    payload.setUint16(18, 3); // SHORT
    payload.setUint32(20, 1); // value count
    payload.setUint16(24, code);
    payload.setUint32(26, 0); // next IFD

    final payloadBytes = payload.buffer.asUint8List();
    final segmentLength = payloadBytes.length + 2;
    final result = BytesBuilder(copy: false)
      ..add(const [0xFF, 0xD8, 0xFF, 0xE1])
      ..addByte(segmentLength >> 8)
      ..addByte(segmentLength & 0xFF)
      ..add(payloadBytes)
      ..add(Uint8List.sublistView(jpegBytes, 2));
    return result.takeBytes();
  }

  static int _orientationCode(int rotationDegrees, bool isFlipped) {
    return switch ((rotationDegrees, isFlipped)) {
      (90, false) => 6,
      (180, false) => 3,
      (270, false) => 8,
      (0, true) => 2,
      (90, true) => 7,
      (180, true) => 4,
      (270, true) => 5,
      _ => 1,
    };
  }
}

// mirrors `servicePolicy` pause/resume semantics: pausing cancels the underlying
// remote read but keeps the completer pending, so the image stream can resume it
class _SftpThumbRequest {
  final SftpMediaService _service;
  final ThumbnailProviderKey request;
  final ImageDecoderCallback? decode;
  final Completer<ui.Codec> completer = Completer<ui.Codec>();
  SftpTicket<Object?>? ticket;
  bool _paused = false;

  _SftpThumbRequest(this._service, this.request, this.decode);

  void start() {
    _paused = false;
    _run();
  }

  void pause() {
    _paused = true;
    ticket?.cancel();
    ticket = null;
  }

  void resume() {
    if (_paused && !completer.isCompleted) start();
  }

  Future<void> _run() async {
    try {
      final codec = await _service._loadThumbnailCodec(this);
      if (!completer.isCompleted) completer.complete(codec);
    } on SftpRequestCancelledException catch (error, stack) {
      // when paused, leave the completer pending for a later resume
      if (!_paused && !completer.isCompleted) completer.completeError(error, stack);
    } catch (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
    }
  }
}

// cancellable handle over the (possibly chained) remote reads behind one prefetch
class SftpPrefetchHandle {
  SftpTicket<Object?>? _ticket;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  // returns false when the handle was cancelled before the ticket attached
  bool attach(SftpTicket<Object?> ticket) {
    if (_cancelled) {
      ticket.cancel();
      return false;
    }
    _ticket = ticket;
    return true;
  }

  void cancel() {
    _cancelled = true;
    _ticket?.cancel();
    _ticket = null;
  }
}
