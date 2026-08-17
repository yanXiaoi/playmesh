import 'dart:convert';

const String playmeshDeveloperFullscreenChannel = 'PlaymeshDeveloperFullscreen';

/// Installed only by the native Playmesh WebView host. It exposes a narrow
/// toggle intent to the WebIDE; the actual platform fullscreen behavior remains
/// owned by AppDeviceService, just like the game WebView.
const String playmeshDeveloperFullscreenScript = r'''
(() => {
  const global = globalThis;
  if (global.__playmeshDeveloperFullscreenInstalled) return;

  const flutterChannel = global.PlaymeshDeveloperFullscreen;
  const windowsBridge = global.chrome && global.chrome.webview;
  const send = flutterChannel && typeof flutterChannel.postMessage === "function"
    ? (message) => flutterChannel.postMessage(message)
    : windowsBridge && typeof windowsBridge.postMessage === "function"
      ? (message) => windowsBridge.postMessage(message)
      : null;
  if (!send) return;

  const applyState = active => {
    if (typeof active !== "boolean") return;
    global.__playmeshDeveloperFullscreenActive = active;
    global.dispatchEvent(new CustomEvent(
      "playmeshdeveloperfullscreenchange",
      { detail: { active } }
    ));
  };

  Object.defineProperty(global, "__playmeshDeveloperFullscreenInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });
  Object.defineProperty(global, "__playmeshDeveloperFullscreen", {
    configurable: false,
    enumerable: false,
    value: Object.freeze({
      toggle: () => send(JSON.stringify({
        __playmeshDeveloperFullscreen: { action: "toggle" },
      })),
    }),
  });
  Object.defineProperty(global, "__playmeshApplyDeveloperFullscreenState", {
    configurable: false,
    enumerable: false,
    value: applyState,
  });
  applyState(false);
})();
''';

bool isPlaymeshDeveloperFullscreenToggleMessage(Object? rawMessage) {
  if (rawMessage is! String || rawMessage.length > 256) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException {
    return false;
  }
  if (decoded is! Map || decoded.length != 1) return false;
  final payload = decoded['__playmeshDeveloperFullscreen'];
  if (payload is! Map || payload.length != 1) return false;
  return payload['action'] == 'toggle';
}

String playmeshDeveloperFullscreenStateScript(bool active) =>
    'globalThis.__playmeshApplyDeveloperFullscreenState?.('
    '${jsonEncode(active)});';
