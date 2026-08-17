# SFTP image source — milestone plan and session handoff

One-line summary: working plan, milestone status, and handoff notes for the remote SFTP image source feature, maintained across sessions.

## How to resume in a new session
1. Read this file, `DECISIONS.md`, and `aves-media-pipeline.md` (seam analysis).
2. `git log --oneline -15` on the current feature branch (session 4: `claude/sftp-delete-feature-5x31zb`) to see what landed.
3. Continue at the first unchecked milestone below. Update checkboxes and the "state" note as you go, and commit doc updates together with code.

## Build facts (verified)
- Flavor to build: **libre** (F-Droid; `aves_useCrashlytics` is only true for "play" task names, and libre pins `aves_services_none` + `aves_report_console` via `scripts/apply_flavor_libre.sh`).
- Dependency-update step before building: `scripts/apply_flavor_libre.sh` (rewrites pubspec plugin paths, runs `flutterw clean` + `pub get`).
- Build: `./flutterw build apk --debug -t lib/main_libre.dart --flavor libre`.
- Flutter is vendored as git submodule `.flutter` (beta v3.47.0-0.3.pre); `./flutterw` initializes it.
- dartssh2 is checked out at `/home/user/dartssh2` on the same branch name; add as a path/git dependency. `SftpFile.readBytes({length, offset})` gives ranged reads.

## Milestones
- [x] M0 Orientation: media-pipeline analysis written, seam chosen (`aves-media-pipeline.md`).
- [x] M1 Skeleton: sftp entry origin + URI scheme; host config model; secure credential storage; connection manager (one SSHClient per host, reconnect, close on background).
- [x] M2 Listing: SFTP directory listing → AvesEntry list appearing as an album in the collection; read-only enforcement.
- [x] M3 Scheduler + cache: single per-host priority queue (4 concurrent reads), cancellable requests; shared disk cache (thumb 200MB / full 1GB LRU, key host+path+mtime+size+variant) in app-private storage.
- [x] M4 Thumbnails: grid thumbnails through the scheduler (JPEG embedded-preview header reads, else full download reused for viewer; original-bytes previews instead of WebP re-encode, see D6/D7); viewport-priority + speculative prefetch one screen ahead.
- [x] M5 Viewer: full-size bytes through the same scheduler/cache; sliding prefetch window (3 ahead / 1 behind, direction bias after 2 same-way swipes); viewer suspends speculative thumb fetches.
- [x] M6 Setup UI: add-host screen (address/port/user/password|key, dir), host-key TOFU pinning, ACCESS_LOCAL_NETWORK runtime permission.
- [x] M7 Settings: hosts list with per-host cache size + clear; prefetch window settings (SftpPrefs).
- [x] M8 Debug APK builds (`build/app/outputs/flutter-apk/app-libre-debug.apk`); pushed; draft PRs.

## Current state
- Session 1 complete: feature implemented, 158 tests green (85 sftp-specific), `dart analyze lib test` clean, debug APK built with the feature. See DECISIONS.md D4–D12 for the shape and departures.
- Session 2 (2026-08-17, branch `claude/sftp-host-vault-access-3z78wz`, PR #3): first on-device test surfaced silent failures — fixed error feedback (D14) and restored play-flavor committed pubspec to unbreak CI analysis (D13). Repo owner enabled Dependency graph, so the dependency-review check now works.
- Session 3 (2026-08-17, discoverability branch): drawer entry + always-visible host albums (D15), from the owner's first-use walkthrough.
- Session 4 (2026-08-17, branch `claude/sftp-delete-feature-5x31zb`): remote delete via the standard delete UI, with a remote-`.trash` toggle (D16–D18). dartssh2 untouched (`remove`/`rename`/`mkdir` already existed).

## Session 4 — remote delete (branch `claude/sftp-delete-feature-5x31zb`)
Goal: deleting sftp entries through the standard Aves delete UI (viewer trash quick action; thumbnail multi-select trash) issues remote SFTP operations. A toggle in the Remote SFTP settings section chooses between permanent `remove` and `rename` into a `.trash` subdirectory of the host directory (defaults to `.trash`, D17).

- [x] S4-M1 Map the delete UI flow (visibility gating + dispatch in viewer and selection delegates, vault delete path as the model) — see D16; key fact: Kotlin provider silently no-ops on `sftp://`.
- [x] S4-M2 Remote delete op `SftpMediaService.deleteEntries`: group by host, `remove` or `mkdir('.trash')`+`rename` (timestamp-suffix retry on collision), per-entry failure tracking, entry removal from source/DB/registry.
- [x] S4-M3 Settings toggle `SettingsTileSftpDeleteToTrash` backed by `SftpPrefs.deleteToRemoteTrash`, l10n strings in app_en.arb.
- [x] S4-M4 UI seams: viewer `isVisible` `.delete` case split to allow sftp origin; both delegates' `_delete` intercept sftp entries via `SftpEntryDeleteMixin` (`lib/widgets/common/action_mixins/sftp_delete.dart`) before bin routing.
- [x] S4-M5 Tests: 160 green (`test/sftp/prefs_test.dart` added), `dart analyze lib test` clean.
- [x] S4-M6 Debug APK builds (`build/app/outputs/flutter-apk/app-libre-debug.apk`); pushed; draft PR #5; docs updated.

dartssh2: no changes expected (`remove`/`rename`/`mkdir` already exist on `SftpClient`); branch exists on origin already.

## Follow-ups worth considering (not started)
- **Tap-and-hold any left-drawer item → context menu to hide it** (owner request, 2026-08-17): general drawer ergonomics, not sftp-specific. Sits close to upstream code (drawer tiles + navigation settings), so weigh fork-maintenance cost before building.
- **Remote directory browser/picker in the host form** (owner expected to browse from `/` and refine): needs a connection from the edit form before save; medium effort.
- On-device validation against a real SFTP server (untested end to end — nothing here ran on a phone).
- Remote `.trash` management from the app (list / restore / empty): deliberately out of scope for the delete feature; trashed files are only reachable server-side.
- HEIC/AVIF embedded-preview extraction; progressive JPEG first-scan decode.
- Refresh grid cell sharpness once full bytes arrive (thumbnail key is unchanged, so a soft EXIF preview stays until cache eviction).
- Share/export actions on remote entries pass `sftp://` URIs to platform handlers and will fail; hide or materialize-then-share.
- Non-JPEG entries have 0×0 dimensions until first full download; viewer lays out with aspect 1 until then.

## Fork-maintenance stance (owner, 2026-08-17)
Keep changes strategic: prefer self-contained additions (new files under `lib/sftp/`, `lib/widgets/settings/sftp/`) over edits to upstream files, so rebasing the fork onto upstream releases stays cheap. When an upstream file must change, keep the diff to a few lines at a clear seam (as with `_loadSftpEntries` beside `_loadVaultEntries`).
