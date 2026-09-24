# FLS for Android

FLS for Android is a Flutter client for remote FLS panels and a private local
FLS instance. The Android interface is being built independently; the existing
FLS panel remains the source of truth for its web UI and backend behavior.

## Current scope

- Save multiple remote panel addresses and open the existing panel in Android
  WebView. Login and session cookies stay in the WebView data store.
- Install either the ARM64 Python or Full PRoot runtime from the fixed
  [`proot-runtime` release](https://github.com/liyw0205/fls/releases/tag/proot-runtime),
  with optional GitHub mirror support.
- Import and export runtime containers through the Android document picker;
  panel data, logs, and scripts stay outside the replaceable runtime.
- Verify the runtime asset against the SHA-256 digest published by GitHub,
  sync FLS source by commit, and run the local service on `127.0.0.1:5700`.
- Keep task data, logs, and user scripts outside the replaceable panel source.

Local PRoot execution has not yet been validated on a physical Android device.
See [development notes](docs/DEVELOPMENT.md) before relying on local mode.

## Build

Requirements: Flutter stable, Android SDK, Java 17+, and Android SDK Platform 35.

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

## Project notes

- [Architecture and local storage](docs/ARCHITECTURE.md)
- [Development and device validation](docs/DEVELOPMENT.md)
- [Reference UI and behavior](docs/REFERENCE.md)

## License

MIT. See [LICENSE](LICENSE).
