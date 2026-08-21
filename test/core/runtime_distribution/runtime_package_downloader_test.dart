import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_downloader_contract.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_downloader_io.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_models.dart';

void main() {
  test('production default enforces a one-GiB streaming ceiling', () {
    final downloader = IoRuntimePackageDownloader();
    addTearDown(downloader.close);
    expect(downloader.maxBytes, 1024 * 1024 * 1024);
  });

  test(
    'redirect download streams, hashes and leaves one commit file',
    () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.close);
      final bytes = utf8.encode('runtime-package');
      final sha256 = await _sha256(bytes);
      fixture.server.listen((request) async {
        if (request.uri.path == '/start') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/file.apk');
        } else {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final progress = <RuntimePackageDownloadProgress>[];

      final result = await fixture.downloader.download(
        endpoint: fixture.endpoint('/start', sha256),
        downloadDirectoryPath: fixture.downloads.path,
        onProgress: progress.add,
      );

      expect(await File(result.temporaryFilePath).readAsBytes(), bytes);
      expect(result.bytes, bytes.length);
      expect(result.sha256, sha256);
      expect(progress.first.receivedBytes, 0);
      expect(progress.last.receivedBytes, bytes.length);
    },
  );

  test('empty configuration cannot start a network download', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);

    await expectLater(
      fixture.downloader.download(
        endpoint: const RuntimePackageDownloadEndpoint(
          name: 'Placeholder',
          urlValue: '',
          sha256: '',
        ),
        downloadDirectoryPath: fixture.downloads.path,
      ),
      throwsA(
        isA<RuntimePackageDownloadException>().having(
          (error) => error.kind,
          'kind',
          RuntimePackageDownloadFailureKind.unavailable,
        ),
      ),
    );
  });

  test(
    'hash mismatch and stream limit remove the private temporary file',
    () async {
      for (final mode in const ['hash', 'limit']) {
        final fixture = await _DownloadFixture.create(
          maxBytes: mode == 'limit' ? 4 : 1024,
        );
        addTearDown(fixture.close);
        final bytes = utf8.encode('runtime-package');
        final actualSha256 = await _sha256(bytes);
        fixture.server.listen((request) async {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        });

        await expectLater(
          fixture.downloader.download(
            endpoint: fixture.endpoint(
              '/file.apk',
              mode == 'hash' ? List.filled(64, 'a').join() : actualSha256,
            ),
            downloadDirectoryPath: fixture.downloads.path,
          ),
          throwsA(
            isA<RuntimePackageDownloadException>().having(
              (error) => error.kind,
              'kind',
              mode == 'hash'
                  ? RuntimePackageDownloadFailureKind.sha256Mismatch
                  : RuntimePackageDownloadFailureKind.tooLarge,
            ),
          ),
        );
        expect(await fixture.downloads.list().toList(), isEmpty);
      }
    },
  );

  test('cancellation aborts transfer and removes the temporary file', () async {
    final fixture = await _DownloadFixture.create();
    addTearDown(fixture.close);
    final bytes = List<int>.filled(64 * 1024, 7);
    final sha256 = await _sha256(bytes);
    fixture.server.listen((request) async {
      request.response.contentLength = bytes.length;
      try {
        for (var offset = 0; offset < bytes.length; offset += 1024) {
          request.response.add(bytes.sublist(offset, offset + 1024));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await request.response.close();
      } on Object {
        // The client intentionally aborts this test response.
      }
    });
    final cancellation = RuntimePackageDownloadCancellationToken();

    await expectLater(
      fixture.downloader.download(
        endpoint: fixture.endpoint('/slow.apk', sha256),
        downloadDirectoryPath: fixture.downloads.path,
        cancellationToken: cancellation,
        onProgress: (progress) {
          if (progress.receivedBytes >= 1024) cancellation.cancel();
        },
      ),
      throwsA(
        isA<RuntimePackageDownloadException>().having(
          (error) => error.kind,
          'kind',
          RuntimePackageDownloadFailureKind.cancelled,
        ),
      ),
    );
    expect(await fixture.downloads.list().toList(), isEmpty);
  });
}

final class _DownloadFixture {
  _DownloadFixture({
    required this.root,
    required this.downloads,
    required this.server,
    required this.downloader,
  });

  final Directory root;
  final Directory downloads;
  final HttpServer server;
  final IoRuntimePackageDownloader downloader;

  static Future<_DownloadFixture> create({int maxBytes = 1024 * 1024}) async {
    final root = await Directory.systemTemp.createTemp('runtime-downloader-');
    final downloads = Directory(
      '${root.path}${Platform.pathSeparator}downloads',
    );
    await downloads.create();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _DownloadFixture(
      root: root,
      downloads: downloads,
      server: server,
      downloader: IoRuntimePackageDownloader(maxBytes: maxBytes),
    );
  }

  RuntimePackageDownloadEndpoint endpoint(String path, String sha256) =>
      RuntimePackageDownloadEndpoint(
        name: 'Local',
        urlValue: 'http://127.0.0.1:${server.port}$path',
        sha256: sha256,
      );

  Future<void> close() async {
    downloader.close();
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<String> _sha256(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
