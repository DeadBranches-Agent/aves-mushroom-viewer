# SFTP image source — milestone plan and session handoff

One-line summary: working plan, milestone status, and handoff notes for the remote SFTP image source feature, maintained across sessions.

## How to resume in a new session
1. Read this file, `DECISIONS.md`, and `aves-media-pipeline.md` (seam analysis).
2. `git log --oneline -15` on branch `claude/aves-sftp-image-source-4px7wz` to see what landed.
3. Continue at the first unchecked milestone below. Update checkboxes and the "state" note as you go, and commit doc updates together with code.

## Build facts (verified)
- Flavor to build: **libre** (F-Droid; `aves_useCrashlytics` is only true for "play" task names, and libre pins `aves_services_none` + `aves_report_console` via `scripts/apply_flavor_libre.sh`).
- Dependency-update step before building: `scripts/apply_flavor_libre.sh` (rewrites pubspec plugin paths, runs `flutterw clean` + `pub get`).
- Build: `./flutterw build apk --debug -t lib/main_libre.dart --flavor libre`.
- Flutter is vendored as git submodule `.flutter` (beta v3.47.0-0.3.pre); `./flutterw` initializes it.
- dartssh2 is checked out at `/home/user/dartssh2` on the same branch name; add as a path/git dependency. `SftpFile.readBytes({length, offset})` gives ranged reads.

## Milestones
- [ ] M0 Orientation: media-pipeline analysis written, seam chosen (`aves-media-pipeline.md`).
- [ ] M1 Skeleton: sftp entry origin + URI scheme; host config model; secure credential storage; connection manager (one SSHClient per host, reconnect, close on background).
- [ ] M2 Listing: SFTP directory listing → AvesEntry list appearing as an album in the collection; read-only enforcement.
- [ ] M3 Scheduler + cache: single per-host priority queue (4 concurrent reads), cancellable requests; shared disk cache (thumb 200MB / full 1GB LRU, key host+path+mtime+size+variant) in app-private storage.
- [ ] M4 Thumbnails: grid thumbnails through the scheduler (embedded-preview header reads where cheap, else full download reused for viewer), WebP q73 at Aves thumbnail size; viewport-priority + modest speculative prefetch.
- [ ] M5 Viewer: full-size bytes through the same scheduler/cache; sliding prefetch window (3 ahead / 1 behind, direction bias after 2 same-way swipes); viewer suspends speculative thumb fetches.
- [ ] M6 Setup UI: add-host screen (address/port/user/password|key, dir), host-key TOFU pinning, ACCESS_LOCAL_NETWORK runtime permission.
- [ ] M7 Settings: hosts list with per-host cache size + clear; prefetch window setting.
- [ ] M8 Debug APK builds; final report; push + draft PRs.

## Current state
- Session 1 in progress: exploration agents running; Flutter submodule downloading.

## Known risks / open items
- Flutter artifact download (storage.googleapis.com) must pass the network proxy — unverified.
- Android 17 / API 37 `ACCESS_LOCAL_NETWORK` permission name must be checked against the SDK in this checkout.
