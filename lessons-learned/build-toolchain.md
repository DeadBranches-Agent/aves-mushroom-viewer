# Building Aves in a fresh cloud container

One-line summary: exact steps to reproduce the debug build environment from a clean container, with the gotchas that cost time.

1. Flutter is a git submodule: `git submodule update --init --depth 1 .flutter` works (GitHub allows fetching the pinned SHA directly); `./flutterw --version` then bootstraps the Dart SDK through the proxy without issue.
2. Android SDK is not preinstalled. Install cmdline-tools into `$HOME/android-sdk` (note: `$HOME` is `/root` here), accept licenses, then install `platform-tools`, **`platforms;android-37.0`** (the API 37 platform package is named `android-37.0`, not `android-37` — a plain `android-37` does not exist) and `build-tools;37.0.0`.
3. AGP expects `platforms/android-37`; the package installs as `android-37.0`, so symlink: `ln -s $HOME/android-sdk/platforms/android-37.0 $HOME/android-sdk/platforms/android-37`. Gradle prints a warning about the "inconsistent location" but builds fine.
4. Write `android/local.properties` with `sdk.dir` and `flutter.sdk` (absolute paths).
5. `scripts/apply_flavor_libre.sh` before building (rewrites pubspec to `aves_services_none` + `aves_report_console`, runs clean + pub get). These pubspec changes are committed on this branch deliberately.
6. Build: `ANDROID_HOME=/root/android-sdk ./flutterw build apk --debug -t lib/main_libre.dart --flavor libre` → `build/app/outputs/flutter-apk/app-libre-debug.apk` (~10 min first time; gradle downloads NDK + CMake itself).
7. `./flutterw analyze` on the whole workspace reports ~65 pre-existing errors in `plugins/aves_services_google` (Play-flavor plugin without its deps under the libre flavor). Use `.flutter/bin/dart analyze lib test` for a signal that matters.
8. The `dartssh2` dependency is a git dependency on the fork branch — it must be pushed before `pub get` can resolve it (this broke agents' pub get once).
9. Tests: `./flutterw test` — the flutter tool serializes on a lock, so tests queue behind a running gradle build.
