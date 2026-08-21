# App identity — installing beside upstream Aves

One-line summary: why this fork ships as `viewer.mushroom.moo` / "Mushroom Viewer", and the four traps in changing an Android app's identity.

## The problem it solves

The fork changed no identity at all: `applicationId` stayed `deckers.thibault.aves`, and the shipped `libre` flavor added upstream's `.libre` suffix, so the release APK was `deckers.thibault.aves.libre` labeled "Aves Libre" — byte-identical identity to upstream's F-Droid/GitHub `libre` build.

Android keys an installed app on **(applicationId, signing certificate)**. This fork signs with its own keystore (`AVES_KEYSTORE_BASE64`), upstream signs with deckerst's. Same ID + different certificate = `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: the fork could neither be installed beside an upstream libre build nor upgrade over it. The only resolution was uninstalling upstream, which would also have wiped it.

(Against upstream's Play/IzzyOnDroid build, `deckers.thibault.aves`, there was never a conflict — different ID.)

## Trap 1: `applicationId` and `namespace` are different things

`namespace` is the Kotlin/Java package the sources declare and the package `R`/`BuildConfig` are generated into; `applicationId` is the ID the app installs under. Only the second one was changed. Renaming `namespace` would mean rewriting the `package` line of every Kotlin file for no benefit — and `build.gradle.kts` already keeps them apart on purpose:

```kotlin
resValue("string", "screen_saver_settings_activity", "${applicationId}/${packageName}.ScreenSaverSettingsActivity")
```

`<installed ID>/<class name>` — the class name has to stay in the source package. Everything else derived from identity (`file_provider` and `search_provider` authorities) reads `applicationId` and followed the rename for free.

## Trap 2: a flavor `values/strings.xml` does not win over `values-fr/strings.xml`

`app_name` is defined in the `main` source set **56 times**: once in `values/` and once in each locale-qualified `values-*/`. A flavor override in `libre/res/values/strings.xml` replaces only the unqualified one. Resource *merging* is by exact configuration, and resource *resolution* at runtime picks the best locale match — so a device set to French still resolved `app_name` through `main`'s `values-fr` and showed "Aves". Upstream has this same quirk: its F-Droid build shows "Aves", not "Aves Libre", on any of those 56 locales.

The launcher name comes from the `<application>` label, so `android/app/src/libre/AndroidManifest.xml` pins it to a literal with `tools:replace="android:label"`, which no locale-qualified resource can override. The string resource is still overridden for the default locale; the one surface left localized is the `ScreenSaverService` label (shows "Aves" on those locales), which is not worth 56 more files.

## Trap 3: `google-services.json` validates the applicationId

`com.google.gms.google-services` fails the build when the applicationId has no matching client in `google-services.json` ("No matching client found for package name"). It is applied **only** when `aves_useCrashlytics` is true, i.e. for `play`-flavor task names, so `libre` builds — the only ones this fork produces (D1) — are unaffected. A local `play` build would now fail there; regenerating that file is meaningless for a fork that has no Firebase project, so it is left alone.

## Trap 4: changing identity resets the app

Everything the SFTP feature stores — host configs, credentials, TOFU-pinned host keys, the entry DB, the thumbnail/full caches — lives in app-private storage under the applicationId. A build with the new ID is a new app to Android: it installs beside the old one with empty state, and hosts have to be re-added and host keys re-accepted. Same for `versionCode` continuity: the new ID has no installed history, so the release workflow's `github.run_number` starting low is not a downgrade.

## Deliberate leftovers

Two upstream references to the old ID were left untouched, because the fork never runs the code paths that read them, and editing them would only widen the rebase surface:

- `.github/workflows/release.yml` publishes to Play with `packageName: deckers.thibault.aves`. That workflow needs `secrets.PLAYSTORE_ACCOUNT_KEY`, which this fork does not have. Worth knowing: it triggers on `push: tags: v*`, and `release-apk.yml` pushes exactly those tags, so the first release run will also start this one — it fails at the Play step, harmlessly, but noisily.
- `test_driver/driver_screenshots_test.dart` grants permissions to `deckers.thibault.aves.debug` / `.profile`. It is upstream's screenshot driver, run against a device, never in this fork.
