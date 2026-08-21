import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const String playmeshGameExternalNavigationChannel =
    'PlaymeshGameExternalNavigation';

const MethodChannel _androidExternalNavigationChannel = MethodChannel(
  'playmesh/external_navigation',
);

const Set<String> _nonExternalSchemes = {
  'about',
  'blob',
  'content',
  'data',
  'file',
  'javascript',
  'view-source',
};

/// Installed only in native game WebViews. It converts `window.open` into a
/// host request while leaving ordinary browsers and same-window navigation
/// untouched.
const String playmeshGameWindowOpenScript = r'''
(() => {
  const global = globalThis;
  if (global.__playmeshGameWindowOpenInstalled) return;
  const channel = global.PlaymeshGameExternalNavigation;
  if (!channel || typeof channel.postMessage !== "function" ||
      typeof global.open !== "function") return;

  const nativeOpen = global.open.bind(global);
  Object.defineProperty(global, "__playmeshGameWindowOpenInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });

  global.open = (url, target, features) => {
    if (url === undefined || url === null || String(url).trim() === "") {
      return nativeOpen(url, target, features);
    }
    let resolved;
    try {
      resolved = new URL(String(url), global.location.href);
    } catch (_) {
      return nativeOpen(url, target, features);
    }
    const blocked = new Set([
      "about:", "blob:", "content:", "data:", "file:", "javascript:",
      "view-source:",
    ]);
    if (blocked.has(resolved.protocol)) {
      return nativeOpen(url, target, features);
    }
    channel.postMessage(JSON.stringify({
      __playmeshGameExternalNavigation: { href: resolved.href },
    }));
    return null;
  };
})();
''';

enum GameWebViewNavigationDisposition { navigate, openExternal, prevent }

Uri? parseGameWebViewExternalUri(String rawUrl) {
  final value = rawUrl.trim();
  if (value.isEmpty || value.length > 8192) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (_nonExternalSchemes.contains(scheme)) return null;
  if ((scheme == 'http' || scheme == 'https') &&
      (!uri.hasAuthority || uri.host.isEmpty)) {
    return null;
  }
  return uri;
}

Uri? parseGameWebViewExternalNavigationMessage(Object? rawMessage) {
  if (rawMessage is! String) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['__playmeshGameExternalNavigation'] is! Map) {
    return null;
  }
  final payload = decoded['__playmeshGameExternalNavigation']! as Map;
  return parseGameWebViewExternalUri(payload['href']?.toString() ?? '');
}

GameWebViewNavigationDisposition classifyGameWebViewNavigation(String rawUrl) {
  final value = rawUrl.trim();
  if (value.isEmpty || value.length > 8192) {
    return GameWebViewNavigationDisposition.prevent;
  }
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.isEmpty) {
    return GameWebViewNavigationDisposition.prevent;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http' ||
      scheme == 'https' ||
      _nonExternalSchemes.contains(scheme)) {
    return GameWebViewNavigationDisposition.navigate;
  }
  return parseGameWebViewExternalUri(value) == null
      ? GameWebViewNavigationDisposition.prevent
      : GameWebViewNavigationDisposition.openExternal;
}

Future<bool> openGameWebViewExternalUri(
  Uri uri, {
  TargetPlatform? platform,
  Future<bool> Function(Uri uri)? launcher,
  Future<bool> Function(String intentUri)? androidIntentLauncher,
}) async {
  final target = parseGameWebViewExternalUri(uri.toString());
  if (target == null) return false;
  final currentPlatform = platform ?? defaultTargetPlatform;
  try {
    if (target.scheme.toLowerCase() == 'intent') {
      if (currentPlatform != TargetPlatform.android) return false;
      final openIntent =
          androidIntentLauncher ??
          (value) async =>
              await _androidExternalNavigationChannel.invokeMethod<bool>(
                'openIntentUri',
                value,
              ) ??
              false;
      return await openIntent(target.toString());
    }
    final open =
        launcher ??
        (value) => launchUrl(value, mode: LaunchMode.externalApplication);
    return await open(target);
  } on Object catch (error) {
    debugPrint('打开游戏 WebView 外部链接失败: $target ($error)');
    return false;
  }
}
