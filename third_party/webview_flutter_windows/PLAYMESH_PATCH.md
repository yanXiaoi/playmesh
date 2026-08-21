# Playmesh patch

This directory vendors `webview_flutter_windows` 1.0.0 under its original
BSD 3-Clause license.

Playmesh carries a Windows-native behavior fix: WebView2 reports CSS
`cursor: none` as a null `HCURSOR`, so `GetCursorName(nullptr)` must return the
Flutter cursor name `none`. Unknown non-null handles continue to fall back to
`basic`.

The native WebView constructor also supports the opt-in compile definition
`PLAYMESH_WEBVIEW_DISABLE_DEVTOOLS`. A host that defines it must successfully
set `ICoreWebView2Settings::AreDevToolsEnabled` to `FALSE`; otherwise WebView
creation fails. The standalone Runtime enables this definition for its plugin
target, while the main App keeps the plugin's default behavior.

The dependency is intentionally a repository-relative path dependency so
debug, release, and CI builds compile the same patched native source instead
of relying on a modified global Pub cache.
