# Current UI and migration direction

The reference repository is
[`tall-1997/daidai-panel-native`](https://github.com/tall-1997/daidai-panel-native).
This project borrows the product-level distinction between a managed local
instance and saved remote panels, and the idea of hosting a local process behind
a narrow Android service boundary. It does not copy the reference Flutter
screens, Kotlin implementation, API models, or assets.

## Current implementation

- Opening a remote panel now enters a native overview and task summary. The
  overview reads FLS runtime/scheduler endpoints; the task view reads
  `/api/status` and supports run/stop/enable actions. The local panel enters
  the same native views when its service is running. Task detail and other
  business domains are still being migrated.
- The existing Flask-rendered frontend remains available through an explicit
  WebView action for workflows that have not yet moved to native Flutter.
- Local panel management has native Flutter controls for the container,
  service, source updates, and persistent data. Opening the local business
  panel still uses WebView.
- Native Flutter pages already provide APP updates and online script browsing,
  installation, and update flows. These are early migrated domains, not full
  coverage of the FLS Web product.

## Target direction

The long-term direction is a complete native FLS frontend in the APP for both
remote and local panels, including the product's actual task, script, log,
configuration, backup, and maintenance workflows where supported by FLS APIs.
The APP should consume real FLS data and preserve backend authorization and
validation; it must not replace the server with local mock business state.

Migration is incremental. Until a domain's native implementation has been
validated, WebView remains its complete workflow and fallback. The per-domain
inventory, API dependencies, and acceptance gates are tracked in
[`GOAL-ROADMAP.md`](GOAL-ROADMAP.md).
