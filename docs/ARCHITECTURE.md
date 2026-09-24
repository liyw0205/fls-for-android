# Architecture

## Modes

The app has two explicit panel modes:

- **Remote** stores a panel name and base URL, then loads the existing FLS web
  frontend in Android WebView. It does not proxy credentials through an FLS for
  Android server. WebView owns the panel's login and cookie session.
- **Local** downloads a prebuilt PRoot + Ubuntu/Python runtime, syncs FLS source
  at a resolved Git commit, and starts the existing Flask application in an
  Android foreground service.

The FLS project provides one runtime Release tag with `python` and `all`
profiles. Local Android installs let the user choose either profile and select
the `arm64` archive from Android's supported ABI list. A user-provided GitHub
mirror can prefix or template every GitHub API/download URL; an empty value
uses the official source. Remote WebView mode remains available on other ABIs;
local mode rejects unsupported ABIs before a download begins.

## Local files

All local instance files live under Android's private application support
directory (`<app files>/fls`):

| Path | Ownership | Update behavior |
| --- | --- | --- |
| `runtime/` | PRoot, Ubuntu rootfs, Python venv and runtime libraries | Installed once; panel updates never replace it |
| `project/` | FLS source tree | Staged and replaced by panel update |
| `data/` | FLS settings, accounts, jobs and secrets | Bound to `/opt/fls/data`; never replaced by source sync |
| `log/` | FLS panel/task logs | Bound to `/opt/fls/log`; never replaced by source sync |
| `scripts/` | User scripts | Bound to `/opt/fls/scripts`; never replaced by source sync |
| `panel-revision` | Installed FLS commit SHA | Written after a successful source replacement |

The runtime rootfs itself acts as the container image. The Android-native PRoot
and loader are packaged under `jniLibs` so Android's package manager installs
them in `nativeLibraryDir`, where executable mappings are allowed. PRoot binds `project/`
to `/opt/fls`, then overlays the three persistent directories. This allows the
container image and Python environment to remain stable while panel code moves
forward independently.

## Install and update transactions

1. Read the fixed runtime Release metadata over HTTPS and select the exact
   architecture asset.
2. Download to a temporary file while calculating SHA-256; reject missing or
   mismatched GitHub asset digests.
3. Extract into a staging directory and verify the ARM64 marker, PRoot, loader,
   shared libraries, and Python paths before activation.
4. Replace `runtime/` by directory rename, rolling back the previous directory
   if activation fails.
5. Resolve `main` to a commit SHA, download that immutable source archive, check
   for `fls-manager.py` and `fls_manager/`, then replace only `project/`.
6. Start the panel only after both runtime and source checks pass.

Local updates intentionally do not upgrade the runtime unless the selected
profile differs from the installed profile. Runtime archives can also be
imported from Android's document picker or exported through the system save
dialog. Import/export covers only the replaceable runtime; `data/`, `log/`,
`scripts/`, and the FLS source remain separate and are preserved.

## Process boundary

`LocalPanelService` owns the PRoot process and shows an ongoing Android
notification while it runs. The FLS process binds only to `127.0.0.1`; remote
devices cannot connect to the app's local instance. Flutter communicates with
the service through a narrow MethodChannel and opens the local web panel in the
same WebView used for remote panels.

## Remote security

Remote panel URLs accept HTTP and HTTPS because FLS installations may be on a
trusted LAN without TLS. Public or untrusted networks should use HTTPS. Remote
panel pages execute in WebView with JavaScript enabled, as required by the FLS
frontend. Only add panel addresses whose operators and content are trusted.
