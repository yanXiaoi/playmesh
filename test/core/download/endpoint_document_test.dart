import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/endpoint_document_contract.dart';
import 'package:playmesh/core/download/endpoint_document_io.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';

void main() {
  test('production GET accepts HTTP and follows redirects', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.uri.path == '/source') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '/update.json',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ready":true}');
      }
      await request.response.close();
    });
    final client = IoEndpointDocumentHttpClient();
    addTearDown(client.close);

    final source = await client.get(
      url: Uri.parse('http://127.0.0.1:${server.port}/source'),
      maxBytes: 1024,
      timeout: const Duration(seconds: 2),
    );

    expect(jsonDecode(source), {'ready': true});
    expect(paths, ['/source', '/update.json']);
  });

  test('Content-Length and streamed bytes are bounded independently', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/declared') {
        request.response.contentLength = 2048;
        request.response.add(List<int>.filled(2048, 0x20));
      } else {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add(List<int>.filled(1025, 0x20));
      }
      try {
        await request.response.close();
      } on HttpException {
        // 有界客户端会刻意取消超出限制的响应体。
      }
    });
    final client = IoEndpointDocumentHttpClient.allowHttpForTesting();
    addTearDown(client.close);

    for (final path in const ['/declared', '/streamed']) {
      await expectLater(
        client.get(
          url: Uri.parse('http://127.0.0.1:${server.port}$path'),
          maxBytes: 1024,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(
          isA<EndpointDocumentLoadException>().having(
            (error) => error.kind,
            'kind',
            EndpointDocumentFailureKind.tooLarge,
          ),
        ),
        reason: path,
      );
    }
  });

  test('HTTP, timeout and malformed UTF-8 remain distinguishable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      switch (request.uri.path) {
        case '/http':
          request.response.statusCode = HttpStatus.badGateway;
          await request.response.close();
          break;
        case '/utf8':
          request.response.add(const [0xff, 0xfe]);
          await request.response.close();
          break;
        case '/timeout':
          await Future<void>.delayed(const Duration(seconds: 2));
          await request.response.close();
          break;
      }
    });
    final client = IoEndpointDocumentHttpClient.allowHttpForTesting();
    addTearDown(client.close);
    final expected = {
      '/http': EndpointDocumentFailureKind.http,
      '/utf8': EndpointDocumentFailureKind.invalidUtf8,
      '/timeout': EndpointDocumentFailureKind.timeout,
    };

    for (final entry in expected.entries) {
      await expectLater(
        client.get(
          url: Uri.parse('http://127.0.0.1:${server.port}${entry.key}'),
          maxBytes: 1024,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<EndpointDocumentLoadException>().having(
            (error) => error.kind,
            'kind',
            entry.value,
          ),
        ),
      );
    }
  });

  test(
    'generic loader wraps strict parser errors without trying another source',
    () async {
      final client = _RecordingDocumentClient('not-json');
      final loader = EndpointDocumentLoader(httpClient: client, maxBytes: 32);
      final selected = NamedDownloadEndpoint(
        name: 'Selected only',
        url: Uri.parse('https://example.com/update.json'),
      );

      await expectLater(
        loader.load<Object?>(endpoint: selected, parse: jsonDecode),
        throwsA(
          isA<EndpointDocumentLoadException>().having(
            (error) => error.kind,
            'kind',
            EndpointDocumentFailureKind.invalidDocument,
          ),
        ),
      );
      expect(client.urls, [selected.url]);
    },
  );
}

class _RecordingDocumentClient implements EndpointDocumentHttpClient {
  _RecordingDocumentClient(this.source);

  final String source;
  final List<Uri> urls = [];

  @override
  Future<String> get({
    required Uri url,
    required int maxBytes,
    required Duration timeout,
  }) async {
    urls.add(url);
    return source;
  }

  @override
  void close() {}
}
