# Development and validation

## Environment

- Flutter stable and Dart from the Flutter SDK
- JDK 17 or newer
- Android SDK Platform 35 and Android build tools
- Android device or emulator for PRoot execution tests

## Local commands

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

Local mode currently requires ARM64 Android. Other ABIs can use remote panel
mode but must fail local installation before downloading a runtime.

## Required device checks

The CI build cannot prove that Termux-built PRoot works from this app's
non-root Android sandbox. Before a public local-mode release, test on at least
one ARM64 Android phone and one Android 14+ device:

1. Install with an empty app data directory; verify ABI selection, download
   progress, SHA-256 rejection, extraction and first boot.
2. Complete FLS `/setup`, create a task and script, and verify the app WebView
   reaches `127.0.0.1:5700` without exposing the service on the LAN.
3. Put the app in the background, lock the device, and verify the foreground
   service and task scheduler remain active.
4. Update FLS source while stopped and while running; verify settings, tasks,
   logs and scripts survive and failed extraction leaves the previous source
   usable.
5. Test no network, interrupted download, insufficient storage, unsupported
   ABI, process death, Android notification permission denied, and reboot.
6. Uninstall/reinstall behavior must be documented separately; app-private
   files are normally removed when the app is uninstalled. Add export/restore
   before promising data survives app removal.

Record device model, Android API, ABI, app version, exact action, result, and
relevant service log for each run. Do not mark a test as passed based only on
an APK build.

## Release boundaries

- The `python` PRoot runtime is reused from the FLS fixed `proot-runtime`
  Release; it is not rebuilt by this repository's app workflow.
- App releases package only the Android app. Runtime archive changes belong to
  the FLS runtime workflow.
- The package application ID is `top.fls.fls_for_android`.
