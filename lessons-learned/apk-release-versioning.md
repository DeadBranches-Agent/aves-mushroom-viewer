# Release APK versioning — tag-derived versions in a Flutter/Gradle build

One-line summary: how `.github/workflows/release-apk.yml` derives the app version from git tags, and the three traps that make a version silently wrong instead of loudly broken.

## The mechanism
- **Version state lives in the latest `vMAJOR.MINOR` git tag.** No version file to drift, no commit-back to the branch; the tag *is* the release record.
- `workflow_dispatch` input `bump` (`minor` | `major`) picks the increment; a major bump resets the minor to 0.
- `versionName` = `MAJOR.MINOR`. `versionCode` = `github.run_number`, deliberately **unrelated** to `versionName` — it only has to increase, which sidesteps the whole "what does versionCode do when 1.47 becomes 2.0" problem.
- The tag is pushed **after** a successful build and artifact upload, so a failed run never consumes a version number.

## Trap 1: `flutter build` does not forward `-P` to Gradle
The obvious `./flutterw build apk -PverName=… -PverCode=…` does not work — the Flutter tool passes its own fixed set of `-P` flags to Gradle and has no passthrough for extra ones. Deliver them as **environment variables instead**: Gradle reads `ORG_GRADLE_PROJECT_verName` / `ORG_GRADLE_PROJECT_verCode` as the project properties `verName` / `verCode`, so `findProperty("verName")` picks them up unchanged. Same property, different delivery.

## Trap 2: an assignment in `defaultConfig` beats `-P` silently
`android/app/build.gradle.kts` previously read:

```kotlin
versionCode = flutter.versionCode
versionName = flutter.versionName
```

Those are not string literals, but they have the same effect as one: they win over any property, the build succeeds, and the APK just carries the pubspec version. Nothing fails. The lines must be *replaced* by the property path, not supplemented:

```kotlin
versionCode = (findProperty("verCode") as String?)?.toInt() ?: flutter.versionCode
versionName = (findProperty("verName") as String?) ?: flutter.versionName
```

The fallback is `flutter.*` (the pubspec version) rather than the spec's generic `"0.0-dev"` / `1`, so local builds, `debug-build.yml`, `release.yml` and the CodeQL profile build behave exactly as they did before.

Verify the property path with the built APK's own metadata, never by reading the workflow:
`grep -o '"version[NC][^,]*' build/app/outputs/apk/libre/release/output-metadata.json`

## Trap 3: `--sort=-v:refname` is load-bearing
`git tag --list 'v[0-9]*' --sort=-v:refname` is git's *version* sort. A lexical sort (`sort -r`) ranks `v1.9` above `v1.10`, so the next version computes as `1.10` — one already taken — and the counter walks backwards. Verified locally: with throwaway tags `v1.9` + `v1.10` present, the bump logic yields `1.11`; `sort -r` on the same tags puts `v1.9` first.

Related: `actions/checkout` must set `fetch-depth: 0`. Tags are not fetched on a shallow clone, and without them every run reads "no tags" and produces `0.1` forever.

## Verified end to end (2026-08-21)
A full signed `libre` release build with `ORG_GRADLE_PROJECT_verName=9.9` / `ORG_GRADLE_PROJECT_verCode=999` and a throwaway keystore produced:

- `output-metadata.json`: `"versionCode": 999`, `"versionName": "9.9"` — the properties win, not the pubspec's 173 / 1.14.9.
- `aapt2 dump badging`: `package: name='deckers.thibault.aves.libre' versionCode='999' versionName='9.9'`.
- `apksigner verify`: `Verifies`, v2 scheme, 1 signer, DN matching the throwaway key. Output is `app-libre-release.apk`, not `-unsigned.apk`.

Two things that look like faults and are not: **v1 (JAR) signing is off** — AGP omits it when `minSdkVersion >= 24` (it is 24 here) because v2 covers those devices; and the universal APK is **~152 MiB** because it carries `armeabi-v7a` + `arm64-v8a` + `x86_64`. Upstream's `release.yml` uses `--split-per-abi` for libre to get ~50 MiB per ABI.

## State at introduction (2026-08-21)
The repo has **zero git tags**, so the first run produces `v0.1` (or `v1.0` for a major bump) unless a seed tag is created first.
