import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

const String playmeshExternalNavigationChannel = 'PlaymeshExternalNavigation';

/// Installed only by the native Playmesh WebView host. A regular browser never
/// sees this script, so its native `window.open` behavior is left untouched.
const String playmeshExternalNavigationScript = r'''
(() => {
  const global = globalThis;
  if (global.__playmeshExternalNavigationInstalled) return;

  const flutterChannel = global.PlaymeshExternalNavigation;
  const windowsBridge = global.chrome && global.chrome.webview;
  const send = flutterChannel && typeof flutterChannel.postMessage === "function"
    ? (message) => flutterChannel.postMessage(message)
    : windowsBridge && typeof windowsBridge.postMessage === "function"
      ? (message) => windowsBridge.postMessage(message)
      : null;
  if (!send || typeof global.open !== "function") return;

  const nativeOpen = global.open.bind(global);
  Object.defineProperty(global, "__playmeshExternalNavigationInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });

  global.open = (url, target, features) => {
    let resolved;
    try {
      if (url === undefined || url === null || String(url).trim() === "") {
        return nativeOpen(url, target, features);
      }
      resolved = new URL(String(url), global.location.href);
    } catch (_) {
      return nativeOpen(url, target, features);
    }

    if (resolved.protocol !== "http:" && resolved.protocol !== "https:") {
      return nativeOpen(url, target, features);
    }
    send(JSON.stringify({
      __playmeshExternalNavigation: { href: resolved.href },
    }));
    return null;
  };
})();
''';

Uri? parsePlaymeshExternalNavigationMessage(Object? rawMessage) {
  if (rawMessage is! String) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['__playmeshExternalNavigation'] is! Map) {
    return null;
  }
  final payload = decoded['__playmeshExternalNavigation']! as Map;
  final uri = Uri.tryParse(payload['href']?.toString() ?? '');
  if (!isSafeDeveloperExternalUri(uri)) return null;
  return uri;
}

bool isSafeDeveloperExternalUri(Uri? uri) {
  if (uri == null || !uri.hasAuthority) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

bool shouldOpenDeveloperNavigationExternally({
  required Uri workspaceUri,
  required Uri requestedUri,
}) {
  if (!isSafeDeveloperExternalUri(requestedUri)) return false;
  return requestedUri.scheme != workspaceUri.scheme ||
      requestedUri.host != workspaceUri.host ||
      requestedUri.port != workspaceUri.port;
}

Future<bool> openDeveloperExternalUri(
  Uri uri, {
  Future<bool> Function(Uri uri)? launcher,
}) async {
  if (!isSafeDeveloperExternalUri(uri)) return false;
  final open =
      launcher ??
      (target) => launchUrl(target, mode: LaunchMode.externalApplication);
  try {
    return await open(uri);
  } on Object catch (error) {
    debugPrint('Unable to open developer external URL $uri: $error');
    return false;
  }
}
