import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../webview_download_overlay.dart';
import 'playmesh_file_system_access_io.dart';
import 'webview_download_script.dart';

typedef DownloadFileOperation =
    Future<Object?> Function(String command, Map<String, Object?> payload);

/// Tracks downloads for one WebView. Android selection/writes reuse the native
/// File System Access backend; no paths or cookies enter JavaScript.
class PlaymeshWebViewDownloads {
  PlaymeshWebViewDownloads({
    required String? gameId,
    DownloadFileOperation? fileOperation,
  }) : queue = gameId == null
           ? WebViewDownloadQueue()
           : WebViewDownloadQueue.forGame(gameId),
       _fileOperation = fileOperation ?? PlaymeshFileSystemAccessHost().execute;

  static const _control = MethodChannel('playmesh/webview_downloads');
  final DownloadFileOperation _fileOperation;
  final WebViewDownloadQueue queue;
  final String _hostId = _downloadToken();
  StreamSubscription<WebviewDownloadEvent>? _windowsEvents;
  final List<_Download> _waiting = [];
  final Set<String> _ownedTasks = {};
  MethodChannel? _channel;
  int? _identifier;
  int _generation = 0;
  bool _disposed = false;
  _Download? _active;

  void attachWindows(WebviewController controller) {
    if (_disposed) return;
    _windowsEvents = controller.onDownloadEvent.listen((event) {
      if (_disposed) return;
      final id = '$_hostId:${event.id}';
      var task = queue[id];
      if (task != null && !task.isActive) return;
      if (task == null) {
        task = WebViewDownloadTask(
          id: id,
          name: safeDownloadFilename(event.resultFilePath),
          source: event.url,
        );
        _ownedTasks.add(id);
        queue.add(task);
      }
      task.receivedBytes = event.bytesReceived;
      task.totalBytes = event.totalBytesToReceive > 0
          ? event.totalBytesToReceive
          : null;
      task.status = switch (event.kind) {
        WebviewDownloadEventKind.downloadRequested =>
          WebViewDownloadStatus.choosing,
        WebviewDownloadEventKind.downloadStarted ||
        WebviewDownloadEventKind.downloadProgress =>
          WebViewDownloadStatus.downloading,
        WebviewDownloadEventKind.downloadCompleted =>
          WebViewDownloadStatus.completed,
        WebviewDownloadEventKind.downloadCancelled =>
          WebViewDownloadStatus.cancelled,
        WebviewDownloadEventKind.downloadFailed => WebViewDownloadStatus.failed,
      };
      if (event.kind != WebviewDownloadEventKind.downloadRequested) {
        task.destination = event.resultFilePath;
        task.name = safeDownloadFilename(event.resultFilePath);
      }
      if (event.error?.isNotEmpty == true) task.error = event.error;
      if (!task.isActive) task.finishedAt = DateTime.now();
      if (task.status == WebViewDownloadStatus.completed) {
        task.totalBytes ??= task.receivedBytes;
      }
      queue.changed();
    });
  }

  Future<void> attachAndroid(int identifier) async {
    if (_disposed) return;
    _identifier = identifier;
    final channel = MethodChannel('playmesh/webview_downloads/$identifier');
    _channel = channel;
    channel.setMethodCallHandler(_onMethodCall);
    await _control.invokeMethod<void>('attach', {
      'identifier': identifier,
      'script': playmeshWebViewDownloadScript,
    });
  }

  Future<void> installScript() async {
    if (!_disposed) await _channel?.invokeMethod<void>('installScript');
  }

  Future<Object?> _onMethodCall(MethodCall call) async {
    if (_disposed) return null;
    if (call.arguments is! Map) return null;
    final args = Map<String, Object?>.from(call.arguments as Map);
    if (call.method == 'download') {
      final url = args['url'];
      if (url is! String) return null;
      if (url.startsWith('blob:') || url.startsWith('data:')) {
        await installScript();
        await _evaluate(
          'globalThis.__playmeshDownloadRuntime?.download('
          '${jsonEncode(url)},${jsonEncode(args['name'])});',
        );
      } else {
        try {
          await _saveHttp(
            url,
            args['name'] as String?,
            args['userAgent'] as String?,
          );
        } on Object catch (error) {
          await _report(error);
        }
      }
    } else if (call.method == 'message') {
      final raw = args['message'];
      if (raw is! String || raw.length > 400 * 1024) return null;
      final generation = _generation;
      Map<String, Object?> message;
      try {
        message = Map<String, Object?>.from(jsonDecode(raw) as Map);
      } on Object {
        return null;
      }
      final id = message['id'];
      if (id is! String || id.length > 32) return null;
      Object? result;
      String? failure;
      try {
        result = await _handleMessage(message);
      } on Object catch (error) {
        failure = _errorCode(error);
        final download = _active;
        if (download != null && download.token == message['token']) {
          await _abort(download, error: error);
        }
        await _report(error);
      }
      if (!_disposed && generation == _generation) {
        await _evaluate(
          'globalThis.__playmeshDownloadRuntime?.settle('
          '${jsonEncode(id)},${jsonEncode(result)},${jsonEncode(failure)});',
        );
      }
    }
    return null;
  }

  Future<Object?> _handleMessage(Map<String, Object?> message) async {
    if (message['operation'] == 'open') {
      if (message['generated'] != true) {
        await _saveHttp(
          message['url']! as String,
          message['name'] as String?,
          null,
        );
        return null;
      }
      final size = message['size'];
      if (size != null && (size is! int || size < 0)) {
        throw const FormatException('下载大小无效');
      }
      final download = await _open(
        message['name'] as String?,
        total: size as int?,
      );
      return {'token': download.token};
    }
    final download = _active;
    if (download == null || download.token != message['token']) {
      throw const FormatException('下载已结束');
    }
    _checkActive(download);
    switch (message['operation']) {
      case 'write':
        if (message['sequence'] != download.sequence++) {
          throw const FormatException('下载分块顺序无效');
        }
        final data = message['data'] as String;
        if (data.length > 350 * 1024) {
          throw const FormatException('下载分块过大');
        }
        final length = base64Decode(data).length;
        if (length > 256 * 1024) {
          throw const FormatException('下载分块过大');
        }
        await _fileOperation('write', {
          'writerId': download.writerId,
          'data': data,
        });
        _checkActive(download);
        download.task.receivedBytes += length;
        queue.changed();
        return null;
      case 'close':
        await _finish(download);
        return null;
      case 'abort':
        await _abort(download);
        return null;
      default:
        throw const FormatException('未知下载操作');
    }
  }

  Future<_Download> _open(String? name, {String? source, int? total}) async {
    if (_disposed) {
      throw const PlaymeshFileSystemAccessException('user_cancelled', '下载已关闭');
    }
    final task = WebViewDownloadTask(
      id: '$_hostId:${_downloadToken()}',
      name: safeDownloadFilename(name),
      source: source,
      totalBytes: total,
    );
    final download = _Download(_generation, task);
    _ownedTasks.add(task.id);
    queue.add(task);
    if (_active == null) {
      _active = download;
      download.ready.complete();
    } else {
      _waiting.add(download);
    }
    try {
      await download.ready.future;
      _checkActive(download);
      task.status = WebViewDownloadStatus.choosing;
      queue.changed();
      final selected =
          await _fileOperation('pickSave', {
                'suggestedName': safeDownloadFilename(name),
              })
              as Map;
      download.entryId = selected['id'] as String;
      _checkActive(download);
      task.name = selected['name'] as String? ?? task.name;
      task.destination =
          await _fileOperation('downloadDestination', {'id': download.entryId})
              as String?;
      _checkActive(download);
      final writer =
          await _fileOperation('createWritable', {
                'id': download.entryId,
                'keepExistingData': false,
              })
              as Map;
      download.writerId = writer['writerId'] as String;
      _checkActive(download);
      task.status = WebViewDownloadStatus.downloading;
      queue.changed();
      return download;
    } on Object catch (error) {
      await _abort(download, error: error);
      rethrow;
    }
  }

  Future<void> _saveHttp(String url, String? name, String? userAgent) async {
    var uri = Uri.parse(url);
    _validateHttpUri(uri);
    final download = await _open(
      name == null || name.isEmpty ? uri.pathSegments.lastOrNull : name,
      source: url,
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    download.client = client;
    try {
      for (var redirects = 0; redirects <= 10; redirects++) {
        _checkActive(download);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        if (userAgent != null && userAgent.isNotEmpty) {
          request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        }
        // Retrieve cookies for each destination instead of forwarding the
        // previous host's credentials through redirects.
        final cookie = await _channel?.invokeMethod<String>('cookies', {
          'url': uri.toString(),
        });
        _checkActive(download);
        if (cookie != null && cookie.isNotEmpty) {
          request.headers.set(HttpHeaders.cookieHeader, cookie);
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null) throw const HttpException('下载重定向缺少地址');
          uri = uri.resolve(location);
          _validateHttpUri(uri);
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('下载失败（HTTP ${response.statusCode}）');
        }
        download.task.totalBytes =
            response.contentLength >= 0 &&
                response.compressionState !=
                    HttpClientResponseCompressionState.decompressed
            ? response.contentLength
            : null;
        queue.changed();
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          _checkActive(download);
          for (var offset = 0; offset < chunk.length; offset += 256 * 1024) {
            _checkActive(download);
            await _fileOperation('write', {
              'writerId': download.writerId,
              'data': base64Encode(
                chunk.sublist(offset, min(offset + 256 * 1024, chunk.length)),
              ),
            });
          }
          download.task.receivedBytes += chunk.length;
          queue.changed();
        }
        _checkActive(download);
        await _finish(download);
        return;
      }
      throw const HttpException('下载重定向次数过多');
    } on Object catch (error) {
      await _abort(download, error: error);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _finish(_Download download) async {
    _checkActive(download);
    await _fileOperation('closeWritable', {'writerId': download.writerId});
    download.writerId = null;
    _checkActive(download);
    download.task.status = WebViewDownloadStatus.completed;
    download.task.totalBytes ??= download.task.receivedBytes;
    download.task.finishedAt = DateTime.now();
    queue.changed();
    await _release(download);
  }

  Future<void> _abort(_Download download, {Object? error}) async {
    if (download.task.isActive) {
      download.task.status =
          error == null ||
              _errorCode(error) == 'user_cancelled' ||
              download.generation != _generation
          ? WebViewDownloadStatus.cancelled
          : WebViewDownloadStatus.failed;
      if (download.task.status == WebViewDownloadStatus.failed) {
        download.task.error = error.toString();
      }
      download.task.finishedAt = DateTime.now();
      queue.changed();
    }
    download.client?.close(force: true);
    final writer = download.writerId;
    download.writerId = null;
    if (writer != null) {
      try {
        await _fileOperation('abortWritable', {'writerId': writer});
      } on Object {
        /* Already reset by the document owner. */
      }
    }
    await _release(download);
  }

  Future<void> _release(_Download download) async {
    final id = download.entryId;
    download.entryId = null;
    if (id != null) {
      try {
        await _fileOperation('release', {'id': id});
      } on Object {
        /* Document may already be closed. */
      }
    }
    if (identical(_active, download)) {
      _active = null;
      if (_waiting.isNotEmpty && !_disposed) {
        final next = _waiting.removeAt(0);
        _active = next;
        next.ready.complete();
      }
    }
  }

  void _checkActive(_Download download) {
    if (_disposed ||
        download.generation != _generation ||
        !identical(_active, download)) {
      throw const PlaymeshFileSystemAccessException('user_cancelled', '下载已取消');
    }
  }

  Future<void> resetDocument() async {
    _generation++;
    final waiting = _waiting.toList();
    _waiting.clear();
    for (final download in waiting) {
      download.ready.completeError(
        const PlaymeshFileSystemAccessException('user_cancelled', '页面已关闭'),
      );
    }
    final download = _active;
    if (download != null) await _abort(download);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await resetDocument();
    await _windowsEvents?.cancel();
    for (final id in _ownedTasks) {
      final task = queue[id];
      if (task != null && task.isActive) {
        task.status = WebViewDownloadStatus.cancelled;
        task.finishedAt = DateTime.now();
      }
    }
    queue.changed();
    _channel?.setMethodCallHandler(null);
    final identifier = _identifier;
    if (identifier != null) {
      await _control.invokeMethod<void>('detach', {'identifier': identifier});
    }
    _channel = null;
  }

  Future<void> _evaluate(String script) async =>
      _channel?.invokeMethod<void>('evaluate', {'script': script});
  Future<void> _report(Object error) async {
    if (_errorCode(error) != 'user_cancelled' && !_disposed) {
      await _channel?.invokeMethod<void>('error', {'message': '文件下载失败，请重试'});
    }
  }

  static String _errorCode(Object error) =>
      error is PlaymeshFileSystemAccessException
      ? error.code
      : 'download_failed';
  static void _validateHttpUri(Uri uri) {
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('不支持的下载地址');
    }
  }
}

String safeDownloadFilename(String? value) {
  var name = (value ?? '').replaceAll('\\', '/').split('/').last;
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_').trim();
  if (name.isEmpty || name == '.' || name == '..') return 'download';
  return name.length > 180 ? name.substring(name.length - 180) : name;
}

class _Download {
  _Download(this.generation, this.task);
  final int generation;
  final WebViewDownloadTask task;
  final Completer<void> ready = Completer<void>();
  final String token = _downloadToken();
  String? entryId;
  String? writerId;
  HttpClient? client;
  int sequence = 0;
}

String _downloadToken() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
}
