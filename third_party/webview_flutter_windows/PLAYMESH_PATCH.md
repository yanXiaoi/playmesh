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
creation fails. The standalone Runtime enables this definition for its plugin
target, while the main App keeps the plugin's default behavior.

The dependency is intentionally a repository-relative path dependency so
debug, release, and CI builds compile the same patched native source instead
of relying on a modified global Pub cache.
