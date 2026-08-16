# SFTP image source — decision log

One-line summary: dated log of design decisions, their reasons, and any later reversals.

Format: `D<n> (date) — decision — why — status`.

- D1 (2026-08-16) — Build the **libre** flavor for the deliverable APK — it is the F-Droid flavor with no Crashlytics and no GMS (`aves_useCrashlytics` only turns on for "play" tasks; `apply_flavor_libre.sh` pins `aves_services_none`) — adopted.
- D2 (2026-08-16) — Keep task-management docs in `lessons-learned/` inside the aves repo and commit them on the feature branch — the container is ephemeral; only pushed state survives across sessions — adopted.
- D3 (2026-08-16) — Use the fork `DeadBranches-Agent/dartssh2` as a git dependency on branch `claude/aves-sftp-image-source-4px7wz` (pushed unmodified) — task specifies dartssh2; its ranged reads and awaitable host-key callback cover all needs; no fork changes were required — adopted.
- D4 (2026-08-16) — Seam: new `EntryOrigins.sftp` + entries persisted in the local media DB under a **synthetic album path** (`<filesDir>/sftp/<host name>/…`), loaded by a `_loadSftpEntries` one-liner mirroring vaults — reuses `StoredAlbumFilter` grouping, read-only `canEdit`, and the whole collection layer without a new filter type (which needs ~7 registration sites) or a second `CollectionSource` — adopted.
- D5 (2026-08-16) — Serve full images, regions and sized thumbnails by **materializing original bytes to a cache file and re-issuing the platform op with the local `file://` URI** — Kotlin already handles files end-to-end (vault path); zero Kotlin decoding changes — adopted.
- D6 (2026-08-16) — **No WebP re-encode of thumbnails** (spec departure): embedded EXIF previews are cached as their original JPEG bytes (with an injected orientation APP1); thumbnails of fully-downloaded files come from the existing Glide pipeline and its disk cache — dart:ui cannot encode WebP, a Kotlin encode channel would duplicate Glide, and preview JPEGs are already thumbnail-sized — adopted.
- D7 (2026-08-16) — Embedded-preview shortcut is **JPEG-only in v1**; HEIC/AVIF/RAW and progressive/interlaced first-pass decoding are skipped, falling back to lowest-priority full download (which doubles as viewer warm-up) — JPEG is the dominant camera format; the other paths need per-container parsers/custom decoders with poor effort/benefit — adopted.
- D8 (2026-08-16) — Cache keys include host, remote path, mtime and size (per spec); byte requests that only carry a URI resolve the rest through an in-memory entry registry (`_entriesByUri`) fed by the DB loader and refresh — adopted.
- D9 (2026-08-16) — Commit the libre-flavor pubspec selection (`aves_services_none`, `aves_report_console`) on this branch — the branch targets a libre build and reproducibility across sessions matters more than keeping the repo's play-flavor default — adopted.
- D10 (2026-08-16) — A remote file with changed mtime/size is handled as **remove + recreate** of its entry, so every mtime-keyed cache invalidates by construction — adopted.
- D11 (2026-08-16) — Entering the viewer suspends speculative grid prefetch on all hosts' schedulers (spec-faithful, simplest) — adopted.
- D12 (2026-08-16) — Phase-2 prefetch-window settings live in a self-contained `SftpPrefs` (shared preferences) with custom tiles, not in the app's `Settings` mixin machinery — avoids touching aves_model SettingKeys/defaults/store for two module-local ints — adopted.
