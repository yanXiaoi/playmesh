import 'dart:convert';

const String playmeshNativeFileSaveChannel = 'PlaymeshNativeFileSave';

/// Installed only by the native Playmesh WebView host. The official GDevelop
/// Blob downloader detects this hook; normal browsers keep their `<a download>`
/// path because this script is never injected there.
const String playmeshNativeFileSaveScript = r'''
(() => {
  const global = globalThis;
  if (global.__playmeshNativeFileSaveInstalled) return;

  const flutterChannel = global.PlaymeshNativeFileSave;
  const windowsBridge = global.chrome && global.chrome.webview;
  const send = flutterChannel && typeof flutterChannel.postMessage === "function"
    ? (message) => flutterChannel.postMessage(message)
    : windowsBridge && typeof windowsBridge.postMessage === "function"
      ? (message) => windowsBridge.postMessage(message)
      : null;
  if (!send || typeof global.fetch !== "function") return;

  let sequence = 0;
  const nextRequestId = () => {
    sequence += 1;
    return `save-${Date.now().toString(36)}-${sequence.toString(36)}`;
  };
  const report = payload => send(JSON.stringify({
    __playmeshNativeFileSave: payload,
  }));
  const boundedMessage = error => {
    const value = error && error.message ? error.message : String(error);
    return value.slice(0, 512);
  };

  Object.defineProperty(global, "__playmeshNativeFileSaveInstalled", {
    value: true,
    configurable: false,
    enumerable: false,
  });
  Object.defineProperty(global, "__playmeshSaveBlobDownload", {
    configurable: false,
    enumerable: false,
    value: ({ url, filename }) => {
      const requestId = nextRequestId();
      return Promise.resolve().then(async () => {
        if (typeof url !== "string" || !url.startsWith("blob:")) {
          throw new Error("GDevelop download URL is not a Blob URL");
        }
        const safeFilename = typeof filename === "string" && filename.trim()
          ? filename.trim()
          : "download.bin";
        const blobResponse = await global.fetch(url);
        if (!blobResponse.ok) {
          throw new Error(`Unable to read generated Blob (${blobResponse.status})`);
        }
        const blob = await blobResponse.blob();
        const stageResponse = await global.fetch(
          new URL("/dev/api/gdevelop/native-file-saves", global.location.href),
          {
            method: "POST",
            credentials: "same-origin",
            headers: {
              "Content-Type": blob.type || "application/octet-stream",
              "X-Playmesh-Filename": encodeURIComponent(safeFilename),
            },
            body: blob,
          }
        );
        let payload = null;
        try {
          payload = await stageResponse.json();
        } catch (_) {
          // The bounded HTTP status below is sufficient when the response was
          // not JSON. Do not leak a potentially large response body to logs.
        }
        if (!stageResponse.ok || !payload) {
          const detail = payload && payload.error && payload.error.message;
          throw new Error(detail || `Unable to stage download (${stageResponse.status})`);
        }
        // The Gateway response has its own HTTP requestId (`dev-*`). Keep the
        // client correlation id (`save-*`) authoritative and whitelist the
        // receipt fields so the Dart parser receives exactly its protocol.
        report({
          kind: "ready",
          requestId,
          protocolVersion: payload.protocolVersion,
          transferId: payload.transferId,
          downloadPath: payload.downloadPath,
          filename: payload.filename,
          mimeType: payload.mimeType,
          size: payload.size,
        });
      }).catch(error => {
        const message = boundedMessage(error);
        console.error("[PlaymeshNativeFileSave]", JSON.stringify({
          eventType: "native.file_save.stage_error",
          requestId,
          message,
        }));
        report({
          kind: "error",
          requestId,
          code: "native_file_save_stage_failed",
          message,
        });
      });
    },
  });
})();
''';

enum DeveloperNativeFileSaveMessageKind { ready, error }

final class DeveloperNativeFileSaveMessage {
  const DeveloperNativeFileSaveMessage._({
    required this.kind,
    required this.requestId,
    this.transferId,
    this.downloadPath,
    this.filename,
    this.mimeType,
    this.size,
    this.errorCode,
    this.errorMessage,
  });

  final DeveloperNativeFileSaveMessageKind kind;
  final String requestId;
  final String? transferId;
  final String? downloadPath;
  final String? filename;
  final String? mimeType;
  final int? size;
  final String? errorCode;
  final String? errorMessage;

  static DeveloperNativeFileSaveMessage? tryParse(Object? rawMessage) {
    if (rawMessage is! String || rawMessage.length > 4096) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(rawMessage);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['__playmeshNativeFileSave'] is! Map) {
      return null;
    }
    final payload = decoded['__playmeshNativeFileSave']! as Map;
    final requestId = payload['requestId']?.toString() ?? '';
    if (!RegExp(r'^save-[a-z0-9-]{3,80}$').hasMatch(requestId)) return null;
    switch (payload['kind']) {
      case 'error':
        final message = payload['message']?.toString().trim() ?? '';
        if (message.isEmpty) return null;
        return DeveloperNativeFileSaveMessage._(
          kind: DeveloperNativeFileSaveMessageKind.error,
          requestId: requestId,
          errorCode: _boundedField(payload['code'], fallback: 'unknown_error'),
          errorMessage: message.length > 512
              ? message.substring(0, 512)
              : message,
        );
      case 'ready':
        if (payload['protocolVersion'] != 1) return null;
        final transferId = payload['transferId']?.toString() ?? '';
        final downloadPath = payload['downloadPath']?.toString() ?? '';
        final filename = payload['filename']?.toString().trim() ?? '';
        final mimeType = payload['mimeType']?.toString().trim() ?? '';
        final sizeValue = payload['size'];
        final size = sizeValue is int ? sizeValue : null;
        if (!RegExp(r'^[A-Za-z0-9_-]{20,64}$').hasMatch(transferId) ||
            downloadPath != '/dev/api/gdevelop/native-file-saves/$transferId' ||
            filename.isEmpty ||
            filename.length > 512 ||
            mimeType.isEmpty ||
            mimeType.length > 128 ||
            size == null ||
            size <= 0) {
          return null;
        }
        return DeveloperNativeFileSaveMessage._(
          kind: DeveloperNativeFileSaveMessageKind.ready,
          requestId: requestId,
          transferId: transferId,
          downloadPath: downloadPath,
          filename: filename,
          mimeType: mimeType,
          size: size,
        );
      default:
        return null;
    }
  }
}

String _boundedField(Object? value, {required String fallback}) {
  final text = value?.toString() ?? '';
  return RegExp(r'^[a-z0-9_.-]{1,80}$').hasMatch(text) ? text : fallback;
}
