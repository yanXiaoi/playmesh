import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';
import 'package:playmesh/core/download/verified_resumable_download_io.dart';

void main() {
  test('fresh redirect download requires exact bytes and SHA-256', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    final bytes = utf8.encode('0123456789');
    final sha256 = await _sha256(bytes);
    var requests = 0;
    fixture.server.listen((request) async {
      requests += 1;
      if (request.uri.path == '/start') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/file.zip');
      } else {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    final progress = <int>[];

    final result = await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: fixture.spec('/start', bytes.length, sha256),
      onProgress: (value) => progress.add(value.receivedBytes),
    );

    expect(await File(result.filePath).readAsBytes(), bytes);
    expect(result.bytes, bytes.length);
    expect(result.sha256, sha256);
    expect(result.resumed, isFalse);
    expect(progress.last, bytes.length);
    expect(await fixture.metadata(sha256).exists(), isFalse);

    await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: fixture.spec('/start', bytes.length, sha256),
    );
    expect(requests, 2, reason: '普通重试可复用同一事务的已验证 ZIP');

    await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: fixture.spec('/start', bytes.length, sha256),
      reuseCompleted: false,
    );
    expect(requests, 4, reason: 'repair 策略可强制重新下载');
  });

  test('valid partial resumes with Range and If-Range', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    final bytes = utf8.encode('0123456789');
    final sha256 = await _sha256(bytes);
    final spec = fixture.spec('/file.zip', bytes.length, sha256);
    await fixture.seedPartial(spec, bytes.sublist(0, 4), etag: '"v1"');
    fixture.server.listen((request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
      expect(request.headers.value(HttpHeaders.ifRangeHeader), '"v1"');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 4-9/10',
      );
      request.response.contentLength = 6;
      request.response.add(bytes.sublist(4));
      await request.response.close();
    });

    final result = await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: spec,
    );

    expect(result.resumed, isTrue);
    expect(await File(result.filePath).readAsBytes(), bytes);
  });

  test(
    'a 200 response that ignores Range safely restarts from byte zero',
    () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.close);
      final bytes = utf8.encode('abcdefghij');
      final sha256 = await _sha256(bytes);
      final spec = fixture.spec('/file.zip', bytes.length, sha256);
      await fixture.seedPartial(spec, utf8.encode('abcd'));
      fixture.server.listen((request) async {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });

      final result = await fixture.downloader.download(
        downloadRootPath: fixture.downloads.path,
        spec: spec,
      );

      expect(result.resumed, isFalse);
      expect(await File(result.filePath).readAsBytes(), bytes);
    },
  );

  test('416 retries once without Range', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    final bytes = utf8.encode('abcdefghij');
    final sha256 = await _sha256(bytes);
    final spec = fixture.spec('/file.zip', bytes.length, sha256);
    await fixture.seedPartial(spec, utf8.encode('abcd'));
    var calls = 0;
    fixture.server.listen((request) async {
      calls += 1;
      if (calls == 1) {
        expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=4-');
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      } else {
        expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });

    final result = await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: spec,
    );

    expect(calls, 2);
    expect(result.resumed, isFalse);
    expect(await File(result.filePath).readAsBytes(), bytes);
  });

  test('cancellation keeps a SHA-isolated partial that can resume', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    final bytes = utf8.encode('0123456789');
    final sha256 = await _sha256(bytes);
    final spec = fixture.spec('/file.zip', bytes.length, sha256);
    fixture.server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final start = range == null
          ? 0
          : int.parse(
              RegExp(r'^bytes=([0-9]+)-$').firstMatch(range)!.group(1)!,
            );
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      request.response.headers.set(HttpHeaders.etagHeader, '"v1"');
      request.response.contentLength = bytes.length - start;
      try {
        for (var index = start; index < bytes.length; index += 2) {
          request.response.add(
            bytes.sublist(index, (index + 2).clamp(0, bytes.length).toInt()),
          );
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        await request.response.close();
      } on Object {
        // 首次请求会在收到有效分块后被刻意取消。
      }
    });
    final cancellation = DownloadCancellationToken();

    await expectLater(
      fixture.downloader.download(
        downloadRootPath: fixture.downloads.path,
        spec: spec,
        cancellationToken: cancellation,
        onProgress: (progress) {
          if (progress.receivedBytes >= 2) cancellation.cancel();
        },
      ),
      throwsA(
        isA<VerifiedDownloadException>().having(
          (error) => error.kind,
          'kind',
          VerifiedDownloadFailureKind.cancelled,
        ),
      ),
    );
    expect(await fixture.partial(sha256).exists(), isTrue);
    expect(await fixture.metadata(sha256).exists(), isTrue);

    final result = await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: spec,
    );
    expect(result.resumed, isTrue);
    expect(await File(result.filePath).readAsBytes(), bytes);
  });

  test('new manifest SHA discards old partial artifacts', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    const oldSha =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await fixture.partial(oldSha).writeAsString('old');
    await fixture.metadata(oldSha).writeAsString('{}');
    await File(
      '${fixture.downloads.path}${Platform.pathSeparator}$oldSha.zip',
    ).writeAsString('old');
    final bytes = utf8.encode('new release');
    final newSha = await _sha256(bytes);
    fixture.server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });

    await fixture.downloader.download(
      downloadRootPath: fixture.downloads.path,
      spec: fixture.spec('/file.zip', bytes.length, newSha),
    );

    expect(await fixture.partial(oldSha).exists(), isFalse);
    expect(await fixture.metadata(oldSha).exists(), isFalse);
    expect(
      await File(
        '${fixture.downloads.path}${Platform.pathSeparator}$oldSha.zip',
      ).exists(),
      isFalse,
    );
  });

  test(
    'size/header mismatch and SHA mismatch cannot become completed ZIPs',
    () async {
      for (final mismatch in const ['size', 'sha']) {
        final fixture = await _DownloadFixture.create();
        addTearDown(fixture.close);
        final bytes = utf8.encode('0123456789');
        final actualSha = await _sha256(bytes);
        const wrongSha =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        fixture.server.listen((request) async {
          final body = mismatch == 'size' ? bytes.sublist(0, 9) : bytes;
          request.response.contentLength = body.length;
          request.response.add(body);
          await request.response.close();
        });
        final spec = fixture.spec(
          '/file.zip',
          bytes.length,
          mismatch == 'sha' ? wrongSha : actualSha,
        );

        await expectLater(
          fixture.downloader.download(
            downloadRootPath: fixture.downloads.path,
            spec: spec,
          ),
          throwsA(
            isA<VerifiedDownloadException>().having(
              (error) => error.kind,
              'kind',
              mismatch == 'size'
                  ? VerifiedDownloadFailureKind.invalidResponse
                  : VerifiedDownloadFailureKind.sha256Mismatch,
            ),
          ),
        );
        expect(
          await File(
            '${fixture.downloads.path}${Platform.pathSeparator}${spec.sha256}.zip',
          ).exists(),
          isFalse,
        );
        expect(await fixture.partial(spec.sha256).exists(), isFalse);
      }
    },
  );

  test('quota fails before opening a network request', () async {
    final root = await Directory.systemTemp.createTemp('verified-quota-');
    addTearDown(() => root.delete(recursive: true));
    final downloader = IoVerifiedResumableDownloader(
      reserveBytes: 0,
      availableBytes: (_) async => 9,
    );
    addTearDown(downloader.close);
    final endpoint = NamedDownloadEndpoint(
      name: 'Local',
      url: Uri.parse('http://127.0.0.1:1/file.zip'),
    );

    await expectLater(
      downloader.download(
        downloadRootPath: root.path,
        spec: VerifiedDownloadSpec(
          endpoint: endpoint,
          size: 10,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
      ),
      throwsA(
        isA<VerifiedDownloadException>().having(
          (error) => error.kind,
          'kind',
          VerifiedDownloadFailureKind.quota,
        ),
      ),
    );
  });
}

class _DownloadFixture {
  _DownloadFixture({
    required this.root,
    required this.downloads,
    required this.server,
    required this.downloader,
  });

  final Directory root;
  final Directory downloads;
  final HttpServer server;
  final IoVerifiedResumableDownloader downloader;

  static Future<_DownloadFixture> create() async {
    final root = await Directory.systemTemp.createTemp('verified-download-');
    final downloads = Directory(
      '${root.path}${Platform.pathSeparator}downloads',
    );
    await downloads.create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _DownloadFixture(
      root: root,
      downloads: downloads,
      server: server,
      downloader: IoVerifiedResumableDownloader(reserveBytes: 0),
    );
  }

  VerifiedDownloadSpec spec(String path, int size, String sha256) =>
      VerifiedDownloadSpec(
        endpoint: NamedDownloadEndpoint(
          name: 'Local',
          url: Uri.parse('http://127.0.0.1:${server.port}$path'),
        ),
        size: size,
        sha256: sha256,
      );

  File partial(String sha256) =>
      File('${downloads.path}${Platform.pathSeparator}$sha256.partial');

  File metadata(String sha256) =>
      File('${downloads.path}${Platform.pathSeparator}$sha256.json');

  Future<void> seedPartial(
    VerifiedDownloadSpec spec,
    List<int> bytes, {
    String? etag,
  }) async {
    await partial(spec.sha256).writeAsBytes(bytes);
    await metadata(spec.sha256).writeAsString(
      jsonEncode({
        'sha256': spec.sha256,
        'url': spec.endpoint.url.toString(),
        'size': spec.size,
        'etag': etag,
        'lastModified': null,
      }),
    );
  }

  Future<void> close() async {
    downloader.close();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<String> _sha256(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
