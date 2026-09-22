import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh_file_system_access/playmesh_file_system_access.dart';
import 'package:playmesh_file_system_access/webview_download_overlay.dart';
import 'package:playmesh_file_system_access/webview_downloads.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const control = MethodChannel('playmesh/webview_downloads');
  const channel = MethodChannel('playmesh/webview_downloads/42');
  late PlaymeshWebViewDownloads downloads;
  late Map<String, List<int>> bytes;
  late List<String> saved;
  late List<String> aborted;
  late List<String> released;
  late Map<String, List<Object?>> replies;
  var fileNumber = 0;
  var testNumber = 0;
  Future<Object?> Function()? picker;

  setUp(() async {
    bytes = {};
    saved = [];
    aborted = [];
    released = [];
    replies = {};
    picker = null;
    fileNumber = 0;
    messenger.setMockMethodCallHandler(control, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cookies') return 'session=download';
      if (call.method == 'evaluate') {
        final script = (call.arguments as Map)['script'] as String;
        final matched = RegExp(r'settle\((.*)\);$').firstMatch(script);
        if (matched != null) {
          final values = jsonDecode('[${matched.group(1)}]') as List;
          replies[values[0] as String] = values.cast<Object?>();
        }
      }
      return null;
    });
    downloads = PlaymeshWebViewDownloads(
      gameId: 'com.playmesh.download-test-${testNumber++}',
      fileOperation: (command, payload) async {
        switch (command) {
          case 'pickSave':
            return picker == null
                ? {
                    'id': 'file-${++fileNumber}',
                    'name': payload['suggestedName'],
                  }
                : await picker!();
          case 'downloadDestination':
            return 'content://documents/${payload['id']}';
          case 'createWritable':
            final id = 'writer-${payload['id']}';
            bytes[id] = [];
            return {'writerId': id};
          case 'write':
            bytes[payload['writerId']]!.addAll(
              base64Decode(payload['data'] as String),
            );
            return null;
          case 'closeWritable':
            saved.add(payload['writerId'] as String);
            return null;
          case 'abortWritable':
            aborted.add(payload['writerId'] as String);
            return null;
          case 'release':
            released.add(payload['id'] as String);
            return null;
          default:
            throw StateError(command);
        }
      },
    );
    await downloads.attachAndroid(42);
  });

  tearDown(() async {
    await downloads.dispose();
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> send(
    String id,
    String operation, [
    Map<String, Object?> payload = const {},
  ]) => _deliver(channel.name, 'message', {
    'message': jsonEncode({'id': id, 'operation': operation, ...payload}),
  });

  test(
    'generated download streams bytes and records the chosen destination',
    () async {
      await send('1', 'open', {
        'generated': true,
        'name': 'video.mp4',
        'size': 4,
      });
      final token = (replies['1']![1] as Map)['token'];
      expect(
        downloads.queue.tasks.single.status,
        WebViewDownloadStatus.downloading,
      );
      await send('2', 'write', {
        'token': token,
        'sequence': 0,
        'data': base64Encode([0, 1, 255, 7]),
      });
      expect(downloads.queue.tasks.single.receivedBytes, 4);
      await send('3', 'close', {'token': token});
      expect(bytes.values.single, [0, 1, 255, 7]);
      expect(saved, ['writer-file-1']);
      expect(released, ['file-1']);
      expect(
        downloads.queue.tasks.single.status,
        WebViewDownloadStatus.completed,
      );
      expect(
        downloads.queue.tasks.single.destination,
        'content://documents/file-1',
      );
    },
  );

  test('cancelled picker leaves no writer and no saved file', () async {
    picker = () async => throw const PlaymeshFileSystemAccessException(
      'user_cancelled',
      'cancel',
    );
    await send('1', 'open', {'generated': true, 'name': 'cancel.txt'});
    expect(replies['1']![2], 'user_cancelled');
    expect(saved, isEmpty);
    expect(bytes, isEmpty);
    expect(
      downloads.queue.tasks.single.status,
      WebViewDownloadStatus.cancelled,
    );
  });

  test('second task queues until the first finishes', () async {
    await send('1', 'open', {'generated': true, 'name': 'first.txt'});
    final firstToken = (replies['1']![1] as Map)['token'];
    final second = send('2', 'open', {'generated': true, 'name': 'second.txt'});
    await Future<void>.delayed(Duration.zero);
    expect(downloads.queue.tasks.first.status, WebViewDownloadStatus.queued);
    expect(fileNumber, 1);
    await send('3', 'close', {'token': firstToken});
    await second;
    expect(fileNumber, 2);
    final secondToken = (replies['2']![1] as Map)['token'];
    await send('4', 'close', {'token': secondToken});
    expect(saved, hasLength(2));
  });

  test(
    'navigation cancels pending selection and releases its eventual result',
    () async {
      final selected = Completer<Object?>();
      picker = () => selected.future;
      final pending = send('1', 'open', {
        'generated': true,
        'name': 'late.txt',
      });
      await Future<void>.delayed(Duration.zero);
      await downloads.resetDocument();
      selected.complete({'id': 'late', 'name': 'late.txt'});
      await pending;
      expect(saved, isEmpty);
      expect(bytes, isEmpty);
      expect(released, ['late']);
      expect(
        replies,
        isEmpty,
        reason: 'Never deliver a previous document reply to the new page',
      );
      expect(
        downloads.queue.tasks.single.status,
        WebViewDownloadStatus.cancelled,
      );
    },
  );

  test('invalid chunk order aborts the temporary writer', () async {
    await send('1', 'open', {'generated': true, 'name': 'partial.bin'});
    final token = (replies['1']![1] as Map)['token'];
    await send('2', 'write', {
      'token': token,
      'sequence': 3,
      'data': base64Encode([1]),
    });
    expect(saved, isEmpty);
    expect(aborted, ['writer-file-1']);
    expect(downloads.queue.tasks.single.status, WebViewDownloadStatus.failed);
  });

  test('HTTP download keeps cookies and reports actual progress', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.cookieHeader),
        'session=download',
      );
      request.response.contentLength = 4;
      request.response.add([0, 1, 255, 7]);
      await request.response.close();
    });
    await _deliver(channel.name, 'download', {
      'url': 'http://127.0.0.1:${server.port}/video.mp4',
      'userAgent': 'Test WebView',
    });
    expect(bytes.values.single, [0, 1, 255, 7]);
    expect(downloads.queue.tasks.single.receivedBytes, 4);
    expect(downloads.queue.tasks.single.totalBytes, 4);
    expect(downloads.queue.tasks.single.name, 'video.mp4');
    expect(
      downloads.queue.tasks.single.status,
      WebViewDownloadStatus.completed,
    );
  });

  test('game IDs isolate memory queues and reopening reuses history', () async {
    await send('1', 'open', {'generated': true, 'name': 'save.bin'});
    final token = (replies['1']![1] as Map)['token'];
    await send('2', 'close', {'token': token});
    final sameGame = PlaymeshWebViewDownloads(
      gameId: 'com.playmesh.download-test-${testNumber - 1}',
    );
    final otherGame = PlaymeshWebViewDownloads(
      gameId: 'com.playmesh.other-download-test',
    );
    expect(identical(sameGame.queue, downloads.queue), isTrue);
    await downloads.dispose();
    expect(sameGame.queue.tasks.single.status, WebViewDownloadStatus.completed);
    expect(otherGame.queue.tasks, isEmpty);
    await sameGame.dispose();
    await otherGame.dispose();
  });

  test('closing cancels the active writer and every queued task', () async {
    await send('1', 'open', {'generated': true, 'name': 'active.bin'});
    final pending = send('2', 'open', {
      'generated': true,
      'name': 'waiting.bin',
    });
    await Future<void>.delayed(Duration.zero);
    await downloads.dispose();
    await pending;
    expect(fileNumber, 1, reason: 'Closing must not open the next save dialog');
    expect(aborted, ['writer-file-1']);
    expect(released, ['file-1']);
    expect(saved, isEmpty);
    expect(downloads.queue.tasks, hasLength(2));
    expect(
      downloads.queue.tasks.every(
        (task) => task.status == WebViewDownloadStatus.cancelled,
      ),
      isTrue,
    );
    expect(downloads.queue.activeCount, 0);
    expect(replies.keys, ['1']);
  });

  test('closing before a save dialog returns never starts writing', () async {
    final selection = Completer<Object?>();
    picker = () => selection.future;
    final pending = send('1', 'open', {'generated': true, 'name': 'late.bin'});
    await Future<void>.delayed(Duration.zero);
    await downloads.dispose();
    selection.complete({'id': 'late', 'name': 'late.bin'});
    await pending;
    expect(bytes, isEmpty);
    expect(saved, isEmpty);
    expect(released, ['late']);
    expect(replies, isEmpty);
    expect(
      downloads.queue.tasks.single.status,
      WebViewDownloadStatus.cancelled,
    );
  });

  test(
    'closing aborts an HTTP transfer while waiting for more bytes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      server.listen((request) async {
        request.response.contentLength = 1024;
        request.response.add([1, 2, 3]);
        await request.response.flush();
        started.complete();
        // Deliberately leave the response unfinished until the client cancels.
      });
      final pending = _deliver(channel.name, 'download', {
        'url': 'http://127.0.0.1:${server.port}/slow.bin',
        'name': 'slow.bin',
      });
      await started.future;
      await downloads.dispose();
      await pending.timeout(const Duration(seconds: 3));
      expect(saved, isEmpty);
      expect(aborted, ['writer-file-1']);
      expect(
        downloads.queue.tasks.single.status,
        WebViewDownloadStatus.cancelled,
      );
    },
  );

  test(
    'malformed messages do not create a download or break the adapter',
    () async {
      await _deliver(channel.name, 'message', {'message': '{broken'});
      await _deliver(channel.name, 'message', {'message': '[]'});
      await send('1', 'open', {'generated': true, 'size': -1});
      expect(downloads.queue.tasks, isEmpty);
      expect(replies['1']![2], 'download_failed');
      await send('2', 'open', {'generated': true, 'name': 'valid.bin'});
      expect(downloads.queue.activeCount, 1);
    },
  );

  test(
    'Windows task IDs distinguish repeated URLs and reopening the game',
    () async {
      final controller = _DownloadController();
      downloads.attachWindows(controller);
      void emit(
        _DownloadController target,
        String id,
        WebviewDownloadEventKind kind,
      ) {
        target.events.add(
          WebviewDownloadEvent(
            kind,
            'https://example.com/same.mp4',
            'C:/Downloads/same.mp4',
            kind == WebviewDownloadEventKind.downloadCompleted ? 100 : 20,
            100,
            id: id,
          ),
        );
      }

      emit(controller, '1', WebviewDownloadEventKind.downloadRequested);
      emit(controller, '1', WebviewDownloadEventKind.downloadCompleted);
      emit(controller, '1', WebviewDownloadEventKind.downloadProgress);
      emit(controller, '2', WebviewDownloadEventKind.downloadStarted);
      await downloads.dispose();
      expect(downloads.queue.tasks.map((task) => task.status), [
        WebViewDownloadStatus.cancelled,
        WebViewDownloadStatus.completed,
      ]);

      final reopenedController = _DownloadController();
      final reopened = PlaymeshWebViewDownloads(
        gameId: 'com.playmesh.download-test-${testNumber - 1}',
      );
      reopened.attachWindows(reopenedController);
      emit(reopenedController, '1', WebviewDownloadEventKind.downloadStarted);
      expect(downloads.queue.tasks, hasLength(3));
      expect(downloads.queue.tasks.map((task) => task.status), [
        WebViewDownloadStatus.downloading,
        WebViewDownloadStatus.cancelled,
        WebViewDownloadStatus.completed,
      ]);
      await reopened.dispose();
      await controller.events.close();
      await reopenedController.events.close();
    },
  );
}

class _DownloadController extends WebviewController {
  final events = StreamController<WebviewDownloadEvent>.broadcast(sync: true);
  @override
  Stream<WebviewDownloadEvent> get onDownloadEvent => events.stream;
}

Future<void> _deliver(
  String channel,
  String method,
  Map<String, Object?> arguments,
) async {
  final complete = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (reply) {
          try {
            const StandardMethodCodec().decodeEnvelope(reply!);
            complete.complete();
          } on Object catch (error, stack) {
            complete.completeError(error, stack);
          }
        },
      );
  await complete.future;
}
