# Playmesh patch

This directory vendors `webview_flutter_windows` 1.0.0 under its original
BSD 3-Clause license.

Playmesh carries a Windows-native behavior fix: WebView2 reports CSS
`cursor: none` as a null `HCURSOR`, so `GetCursorName(nullptr)` must return the
Flutter cursor name `none`. Unknown non-null handles continue to fall back to
`basic`.

The composition host also forwards both sides of the mouse boundary. Entering
the Flutter texture sends a fresh WebView2 mouse move for the current position,
and leaving it sends `COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE`. Cursor state remains
owned by the current document; it is not cached across documents or WebView
instances.

Each navigation broadcasts Flutter's basic cursor before the new document's
live `CursorChanged` events are applied. This prevents a reload from retaining
the previous document's hidden cursor while preserving CSS as the sole source
of the active document's cursor choice.

The native WebView constructor also supports the opt-in compile definition
`PLAYMESH_WEBVIEW_DISABLE_DEVTOOLS`. A host that defines it must successfully
set `ICoreWebView2Settings::AreDevToolsEnabled` to `FALSE`; otherwise WebView
creation fails. Both the main App and standalone Runtime enable this definition
for their plugin targets in all configurations except Debug. Debug builds allow
F12/DevTools during local development; Profile and Release builds disable them.
This policy depends on the build configuration, not which IDE launches the app.
When enabled, it also blocks the plugin's `openDevTools` API, so native calls
cannot reopen the DevTools window.
Internal DevTools protocol calls used for security updates and cache management
remain available.

Downloads use WebView2's original transfer with a deferred native save dialog,
scheduled outside the DownloadStarting callback to avoid modal reentrancy.
The selected path is required before a transfer proceeds. Events include unique
task IDs, progress, completion, cancellation and failure; repeated URLs remain
independent tasks. Disposing a WebView cancels its active downloads, closes its
save dialog, completes queued deferrals and invalidates late callbacks. Flutter
hosts provide the memory-only, per-game download history above the WebView.
The plugin links `runtimeobject` for UI-thread DispatcherQueue scheduling.

The dependency is intentionally a repository-relative path dependency so
debug, release, and CI builds compile the same patched native source instead
of relying on a modified global Pub cache.
