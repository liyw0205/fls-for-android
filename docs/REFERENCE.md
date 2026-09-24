# UI reference

The reference repository is
[`tall-1997/daidai-panel-native`](https://github.com/tall-1997/daidai-panel-native).
This project borrows the product-level distinction between a managed local
instance and saved remote panels, and the idea of hosting a local process behind
a narrow Android service boundary. It does not copy the reference Flutter
screens, Kotlin implementation, API models, or assets.

The FLS Android UI is built around the actual FLS product surface:

- The remote view opens FLS's existing Flask-rendered pages rather than
  duplicating its task, script, log, configuration, and backup interfaces in
  native Flutter screens.
- The local view shows the container, panel source, and persistent data as
  separate install/update concerns.
- The local panel shares the same WebView path as a remote panel, so the FLS
  frontend remains authoritative in both modes.

This keeps one panel UI implementation while leaving room for future native
Android controls for installation status, service state, and storage health.
