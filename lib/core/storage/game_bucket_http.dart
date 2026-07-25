import 'dart:convert';
import 'dart:io';

import 'game_storage_service.dart';

const _uploadTokenHeader = 'x-playmesh-share-token';

/// 处理同源 `/bucket` 文件上传与读取。返回 false 表示请求不属于该路由。
Future<bool> handleGameBucketRequest(
  HttpRequest request, {
  required GameStorageService storage,
  String? uploadToken,
}) async {
  final segments = request.uri.pathSegments;
  if (segments.isEmpty || segments.first != 'bucket') return false;

  if (request.method == 'POST' && segments.length == 2) {
    if (uploadToken != null &&
        request.headers.value(_uploadTokenHeader) != uploadToken) {
      await _json(request.response, HttpStatus.forbidden, {'error': '分享令牌无效'});
      return true;
    }
    final originalName = request.uri.queryParameters['name'];
    if (originalName == null || originalName.isEmpty) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': '缺少上传文件名',
      });
      return true;
    }
    try {
      final url = await storage.upload(
        bucket: segments[1],
        originalName: originalName,
        data: request,
        contentLength: request.contentLength,
      );
      await _json(request.response, HttpStatus.created, {'url': url});
    } on FormatException catch (error) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    }
    return true;
  }

  if (request.method == 'GET' && segments.length == 3) {
    try {
      final file = storage.dataFile(segments[1], segments[2]);
      if (!await file.exists()) {
        await _text(request.response, HttpStatus.notFound, '文件不存在');
        return true;
      }
      request.response.headers
        ..contentType = bucketContentType(file.path)
        ..set(
          HttpHeaders.cacheControlHeader,
          'public, max-age=31536000, immutable',
        )
        ..set('x-content-type-options', 'nosniff')
        ..contentLength = await file.length();
      await file.openRead().pipe(request.response);
    } on FormatException {
      await _text(request.response, HttpStatus.notFound, '文件不存在');
    }
    return true;
  }

  if (request.method != 'GET' && request.method != 'POST') {
    await _text(request.response, HttpStatus.methodNotAllowed, '不支持的请求');
  } else {
    // 不提供 Bucket 目录枚举，也不暴露 data/json。
    await _text(request.response, HttpStatus.notFound, '文件不存在');
  }
  return true;
}

ContentType bucketContentType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return ContentType('image', 'png');
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return ContentType('image', 'jpeg');
  }
  if (lower.endsWith('.gif')) return ContentType('image', 'gif');
  if (lower.endsWith('.webp')) return ContentType('image', 'webp');
  if (lower.endsWith('.svg')) {
    return ContentType('image', 'svg+xml', charset: 'utf-8');
  }
  if (lower.endsWith('.json')) return ContentType.json;
  if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
  if (lower.endsWith('.ogg')) return ContentType('audio', 'ogg');
  if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
  if (lower.endsWith('.mp4')) return ContentType('video', 'mp4');
  if (lower.endsWith('.webm')) return ContentType('video', 'webm');
  if (lower.endsWith('.wasm')) return ContentType('application', 'wasm');
  return ContentType.binary;
}

Future<void> _text(HttpResponse response, int status, String body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.text;
  response.write(body);
  await response.close();
}

Future<void> _json(
  HttpResponse response,
  int status,
  Map<String, Object?> body,
) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}
