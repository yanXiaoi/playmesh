import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'developer_event_hub.dart';

const String windowsWebViewConsoleCaptureScript = r'''
(() => {
  const target = globalThis.console;
  const bridge = globalThis.chrome && globalThis.chrome.webview;
  if (!target || !bridge || globalThis.__playmeshHostConsoleCaptureInstalled) return;

  Object.defineProperty(globalThis, "__playmeshHostConsoleCaptureInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });
  Object.defineProperty(target, "__playmeshForwardingInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });

  function format(value) {
    if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`;
    if (typeof value === "string") return value;
    if (typeof value === "bigint") return value.toString();
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  }

  function forward(level, args, eventType = "console") {
    try {
      bridge.postMessage(JSON.stringify({
        __playmeshHostConsole: {
          level,
          message: args.map(format).join(" "),
          href: globalThis.location ? globalThis.location.href : null,
          timestamp: Date.now(),
          eventType,
        },
      }));
    } catch (_) {
      // Console capture must never affect the page.
    }
  }

  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const nativeMethod = typeof target[level] === "function"
      ? target[level].bind(target)
      : null;
    if (!nativeMethod) continue;
    target[level] = (...args) => {
      nativeMethod(...args);
      forward(level, args);
    };
  }

  globalThis.addEventListener("error", (event) => {
    const resource = event.target && event.target !== globalThis
      ? event.target.currentSrc || event.target.src || event.target.href
      : null;
    const error = event.error instanceof Error ? event.error : null;
    forward(
      "error",
      [resource ? `Resource load failed: ${resource}` : error || event.message],
      resource ? "resource.error" : "uncaught.error",
    );
  }, true);

  globalThis.addEventListener("unhandledrejection", (event) => {
    forward("error", [event.reason], "unhandled.rejection");
  });
})();
''';

void recordLocalWebViewConsole({
  required String level,
  required String message,
  String source = 'app-webview',
  String? href,
  int? clientTimestamp,
  String eventType = 'console',
}) {
  final normalizedLevel = level == 'warning' ? 'warn' : level;
  final normalizedMessage = message.length > 8192
      ? message.substring(0, 8192)
      : message;
  debugPrint('[WebView][$normalizedLevel] $normalizedMessage');
  developerEventHub.emit({
    'type': 'runtime.log',
    'source': source,
    'scope': 'local-device',
    'level': normalizedLevel,
    'message': normalizedMessage,
    'href': href,
    'clientTimestamp': clientTimestamp,
    'eventType': eventType,
    'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
  });
}

bool handleWindowsWebViewConsoleMessage(
  Object? rawMessage, {
  String source = 'app-webview',
}) {
  if (rawMessage is! String) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(rawMessage);
  } on FormatException {
    return false;
  }
  if (decoded is! Map || decoded['__playmeshHostConsole'] is! Map) {
    return false;
  }
  final payload = Map<String, Object?>.from(
    decoded['__playmeshHostConsole']! as Map,
  );
  recordLocalWebViewConsole(
    level: payload['level']?.toString() ?? 'log',
    message: payload['message']?.toString() ?? '',
    source: source,
    href: payload['href']?.toString(),
    clientTimestamp: payload['timestamp'] is num
        ? (payload['timestamp']! as num).toInt()
        : null,
    eventType: payload['eventType']?.toString() ?? 'console',
  );
  return true;
}
