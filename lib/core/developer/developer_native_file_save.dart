import 'dart:convert';

import '../../models/game_id.dart';

const String playmeshNativeFileSaveChannel = 'PlaymeshNativeFileSave';

/// 仅由 Playmesh 原生 WebView 宿主注入。普通浏览器不会安装这些钩子，
/// 因此会继续使用网页自身的 `<a download>` 下载路径。
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
  const saveDownload = ({ url, filename } = {}) => {
    const requestId = nextRequestId();
    const blobDownload = typeof url === "string" && url.startsWith("blob:");
    return Promise.resolve().then(async () => {
      if (!blobDownload) {
        const target = new URL(url, global.location.href);
        if (
          target.origin !== global.location.origin ||
          target.search ||
          target.hash ||
          !/^\/dev\/api\/projects\/[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/package$/.test(target.pathname)
        ) {
          throw new Error("Project package URL is not allowed");
        }
        report({
          kind: "download",
          requestId,
          protocolVersion: 1,
          downloadPath: target.pathname,
        });
        return;
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
        // 非 JSON 响应只记录有界的 HTTP 状态，不把潜在的大响应体写入日志。
      }
      if (!stageResponse.ok || !payload) {
        const detail = payload && payload.error && payload.error.message;
        throw new Error(detail || `Unable to stage download (${stageResponse.status})`);
      }
      // Gateway 有自己的 dev-* requestId。客户端 save-* 仍是本协议的权威
      // 关联 ID，并只转发 Dart 解析器允许的回执字段。
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
        eventType: blobDownload
          ? "native.file_save.stage_error"
          : "native.file_save.request_error",
        requestId,
        message,
      }));
      report({
        kind: "error",
        requestId,
        code: blobDownload
          ? "native_file_save_stage_failed"
          : "native_file_save_request_failed",
        message,
      });
    });
  };
  // 保留 GDevelop 已发布的兼容名称；同一底层函数同时接受 Blob 和经过
  // 白名单校验的当前项目包 URL，不建立第二套原生保存桥。
  Object.defineProperty(global, "__playmeshSaveBlobDownload", {
    configurable: false,
    enumerable: false,
    value: saveDownload,
  });
})();
''';

enum DeveloperNativeFileSaveMessageKind { ready, download, error }

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
      case 'download':
        if (payload['protocolVersion'] != 1) return null;
        final downloadPath = payload['downloadPath']?.toString() ?? '';
        final packageUri = parseDeveloperProjectPackageDownloadPath(
          downloadPath,
        );
        if (packageUri == null) return null;
        return DeveloperNativeFileSaveMessage._(
          kind: DeveloperNativeFileSaveMessageKind.download,
          requestId: requestId,
          downloadPath: downloadPath,
          mimeType: 'application/zip',
        );
      default:
        return null;
    }
  }
}

Uri? parseDeveloperProjectPackageDownloadPath(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 5 ||
      uri.pathSegments[0] != 'dev' ||
      uri.pathSegments[1] != 'api' ||
      uri.pathSegments[2] != 'projects' ||
      !isValidPlaymeshGameId(uri.pathSegments[3]) ||
      uri.pathSegments[4] != 'package') {
    return null;
  }
  return uri;
}

String _boundedField(Object? value, {required String fallback}) {
  final text = value?.toString() ?? '';
  return RegExp(r'^[a-z0-9_.-]{1,80}$').hasMatch(text) ? text : fallback;
}
