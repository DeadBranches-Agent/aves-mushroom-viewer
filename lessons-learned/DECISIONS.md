# SFTP image source — decision log

One-line summary: dated log of design decisions, their reasons, and any later reversals.

Format: `D<n> (date) — decision — why — status`.

- D1 (2026-08-16) — Build the **libre** flavor for the deliverable APK — it is the F-Droid flavor with no Crashlytics and no GMS (`aves_useCrashlytics` only turns on for "play" tasks; `apply_flavor_libre.sh` pins `aves_services_none`) — adopted.
- D2 (2026-08-16) — Keep task-management docs in `lessons-learned/` inside the aves repo and commit them on the feature branch — the container is ephemeral; only pushed state survives across sessions — adopted.
- D3 (2026-08-16) — Use the local `/home/user/dartssh2` checkout as the SSH/SFTP dependency (git dependency on the same branch, path dep during development) — task specifies dartssh2; its `SftpFile.readBytes({length, offset})` supports the ranged reads the thumbnailer needs — adopted.
