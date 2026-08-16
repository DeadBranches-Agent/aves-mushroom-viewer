# Aves media pipeline — orientation answers and the chosen seam

One-line summary: answers to the five step-0 questions with file references, and the seam chosen for the SFTP source (vault-pattern origin + service-level scheme branch + local-cache-file substitution).

## 1. The media item type

`AvesEntry` (`lib/model/entry/entry.dart:21`), satisfying the read-only `AvesEntryBase` mixin (`plugins/aves_model/lib/src/entry/base.dart`) consumed by viewer plugins. Non-nullable constructor fields: `uri`, `sourceMimeType`, `width`, `height`, `sourceRotationDegrees`, `trashed`, `origin`. Nullable but required: `path`, `contentId`, `sizeBytes`, dates, `sourceTitle`. `id` comes from `localMediaDb.nextId`. Crucially there is an `origin` int (`lib/model/entry/origins.dart`): `mediaStoreContent=0, unknownContent=1, file=2, vault=3`, mirrored in Kotlin `SourceEntry.kt:275`. Vault entries prove a non-MediaStore entry kind already flows through the whole app. `canEdit` (`lib/model/entry/extensions/props.dart:141`) keys on MediaStore-URI or vault-path prefix, so any other origin is **read-only for free**.

## 2. Grid thumbnails

Grid tile → `ThumbnailImage` (`lib/widgets/common/thumbnail/image.dart`) drives `ImageStream`s manually with a custom `ThumbnailProvider` (`lib/image_providers/thumbnail_provider.dart`); key props `[uri, mimeType, pageId, rotationDegrees, isFlipped, dateModifiedMillis, extent]`. Bytes come from `mediaFetchService.getThumbnail` (`lib/services/media/media_fetch_service.dart:264`) over the `media_byte_stream` EventChannel, queued through `servicePolicy` (max 4 concurrent, priority queue, `lib/services/common/service_policy.dart`). Kotlin `ThumbnailFetcher.kt` answers via `ContentResolver.loadThumbnail` or Glide (sized), signature includes `dateModifiedMillis`. Scroll-aware pausing already exists (`tile.dart:121`, `thumbnail/image.dart:178`).

## 3. Viewer full image

`RasterImageView` (`lib/widgets/viewer/visual/raster.dart:57`): non-animated images use **tiled region decoding** (`RegionProvider` → `getRegion` op → Kotlin `BitmapRegionDecoder`), animated ones use `FullImage` (`lib/image_providers/full_image_provider.dart`) → `getFullImage` op → either original bytes decoded by the Flutter codec (`MimeTypes.handleEncodedBytesInFlutter`) or Kotlin Glide decode. A cached thumbnail is the placeholder underneath.

## 4. Caches

- Dart: Flutter `imageCache` (1000 entries / 100 MB, `home_page.dart:81`) keyed by provider keys; `EntryCache` (`lib/model/entry/cache.dart`) is a uri→keys registry for eviction and best-cached-thumbnail lookup. Invalidation via `dateModifiedMillis` in keys + explicit `EntryCache.evict`.
- Kotlin: Glide `InternalCacheDiskCacheFactory` (250 MB default, app-internal) for thumbnails only — full images and regions bypass Glide caches (`AvesAppGlideModule.kt:84`). 3-entry `BitmapRegionDecoder` pool in `RegionFetcher.kt`.
- **No prefetching exists anywhere** — only de-prioritization and progressive loading.

## 5. Collection/album membership

Single in-memory `Map<int, AvesEntry>` in abstract `CollectionSource` (`collection_source.dart:115`), sole implementation `MediaStoreSource`. An album is a **predicate**, not a list: `StoredAlbumFilter.test = entry.directory == album`. Vault entries load from the app SQLite DB by origin (`media_store_source.dart:434`: `_loadVaultEntries` = one `addEntries(localMediaDb.loadEntries(origin: vault))` call) — never from MediaStore. `_loadEntries` clears and reloads, so any new origin must hook there. `refreshUris` needs a dedicated scheme branch (vaults have one at `:359`).

## The seam

**Vault-pattern origin + service-level scheme branch + cache-file substitution:**

1. New `EntryOrigins.sftp = 4`. Entries built from the SFTP listing, persisted in `localMediaDb` like vault entries; loaded by a `_loadSftpEntries` one-liner beside `_loadVaultEntries`. URI: `sftp://<hostId>/<remote path>`. **Synthetic path** `<internal sftp root>/<host name>/<filename>` makes the album appear via the ordinary `StoredAlbumFilter` directory predicate — no new filter type, no grouping/chip/section registration. Read-only falls out of `canEdit`.
2. All byte traffic branches once, at the top of `PlatformMediaFetchService` (`getThumbnail` / `getFullImage` / `getRegion`) on the `sftp` URI scheme, into a Dart-side SFTP service (dartssh2 is pure Dart — no Kotlin networking).
3. Full images and regions are served by **materializing the original bytes to an app-private cache file** and, where platform decoding is needed (regions, non-Flutter-decodable formats, sized thumbnails of downloaded files), forwarding the existing platform op with the substituted `file://` URI. Kotlin already handles `file://` end-to-end (that's how vaults work), so the Kotlin layer needs almost no changes.
4. Thumbnails without a full download: Dart-side EXIF/JPEG header parsing extracts embedded previews from a ~128 KB ranged read; those preview bytes live in our own LRU cache. Full-file-derived thumbnails reuse Glide's existing disk cache via the substituted local file.

Why not alternatives: a second `CollectionSource` implementation would touch the three hardcoded `MediaStoreSource` instantiation sites and duplicate lifecycle machinery; a new filter type requires registration in ~7 places (filters, grouping URI round-trip, chip types, sectioning, summaries); a Kotlin-side fetch layer would mean porting SSH to Kotlin or bridging sockets. The vault template is the minimal proven path.
