import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_native_file_save.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_contract.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_io.dart';

void main() {
  test('源码包桥只接受当前项目包路径', () {
    expect(
      playmeshNativeFileSaveScript,
      contains('__playmeshSaveBlobDownload'),
    );
    expect(
      playmeshNativeFileSaveScript,
      contains('value: saveDownload'),
      reason: '源码包与 GDevelop Blob 兼容钩子必须复用同一底层保存函数',
    );
    expect(
      RegExp(
        'value: saveDownload',
      ).allMatches(playmeshNativeFileSaveScript).length,
      1,
    );
    expect(
      playmeshNativeFileSaveScript,
      isNot(contains('__playmeshSaveUrlDownload')),
    );
    expect(
      playmeshNativeFileSaveScript,
      isNot(contains('__playmeshSaveDownload')),
    );
    final directBranch = playmeshNativeFileSaveScript.indexOf(
      'if (!blobDownload)',
    );
    final directReturn = playmeshNativeFileSaveScript.indexOf(
      'return;',
      directBranch,
    );
    final blobFetch = playmeshNativeFileSaveScript.indexOf(
      'const blobResponse = await global.fetch(url)',
      directBranch,
    );
    expect(directBranch, isNonNegative);
    expect(directReturn, greaterThan(directBranch));
    expect(blobFetch, greaterThan(directReturn));
    expect(playmeshNativeFileSaveScript, contains('target.origin'));

    final message = _downloadMessage(
      '/dev/api/projects/com.example.party/package',
    );
    expect(message, isNotNull);
    expect(message!.kind, DeveloperNativeFileSaveMessageKind.download);
    expect(message.filename, isNull);
    expect(message.mimeType, 'application/zip');
    expect(message.size, isNull);

    expect(
      _downloadMessage('/dev/api/projects/com.example.party/package?token=x'),
      isNull,
    );
    expect(
      _downloadMessage('https://example.com/dev/api/projects/a/package'),
      isNull,
    );
    expect(
      _downloadMessage('/dev/api/projects/com.example.party%2Fevil/package'),
      isNull,
    );
  });

  group('源码包原生保存', () {
    late Directory root;
    late HttpServer server;
    late List<int> archive;
    var projectListGetCount = 0;
    var packageGetCount = 0;
    var deleteCount = 0;
    var authorizationHeaders = <String>[];

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'project-package-native-save-test-',
      );
      archive = List<int>.generate(8192, (index) => index % 251);
      projectListGetCount = 0;
      packageGetCount = 0;
      deleteCount = 0;
      authorizationHeaders = <String>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        authorizationHeaders.add(
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
        );
        if (request.method == 'GET' &&
            request.uri.path == '/dev/api/projects') {
          projectListGetCount += 1;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'projects': [
                {'id': 'com.example.party', 'name': '派对游戏', 'version': '1.2.3'},
              ],
            }),
          );
        } else if (request.method == 'GET' &&
            request.uri.path == '/dev/api/projects/com.example.party/package') {
          packageGetCount += 1;
          request.response.headers.contentType = ContentType(
            'application',
            'zip',
          );
          request.response.contentLength = archive.length;
          request.response.add(archive);
        } else if (request.method == 'DELETE') {
          deleteCount += 1;
          request.response.statusCode = HttpStatus.noContent;
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('宿主带会话令牌流式保存且不删除项目包路由', () async {
      final destination = File(
        '${root.path}${Platform.pathSeparator}project.playmesh.zip',
      );
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (suggestedName, groups) async {
          expect(suggestedName, '派对游戏-v1.2.3.zip');
          expect(groups.single.extensions, ['zip']);
          return FileSaveLocation(destination.path);
        },
      );

      final result = await service.save(
        message: _downloadMessage(
          '/dev/api/projects/com.example.party/package',
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.saved);
      expect(result.path, destination.path);
      expect(await destination.readAsBytes(), archive);
      expect(projectListGetCount, 1);
      expect(packageGetCount, 1);
      expect(deleteCount, 0);
      expect(authorizationHeaders, ['Bearer test-token', 'Bearer test-token']);
    });

    test('取消保存时不请求项目包', () async {
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (_, _) async => null,
      );

      final result = await service.save(
        message: _downloadMessage(
          '/dev/api/projects/com.example.party/package',
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.cancelled);
      expect(projectListGetCount, 1);
      expect(packageGetCount, 0);
      expect(deleteCount, 0);
      expect(authorizationHeaders, ['Bearer test-token']);
    });
  });
}

DeveloperNativeFileSaveMessage? _downloadMessage(String downloadPath) {
  return DeveloperNativeFileSaveMessage.tryParse(
    jsonEncode({
      '__playmeshNativeFileSave': {
        'kind': 'download',
        'requestId': 'save-test-1',
        'protocolVersion': 1,
        'downloadPath': downloadPath,
      },
    }),
  );
}

Uri _workspaceUri(int port) =>
    Uri.parse('http://127.0.0.1:$port/dev/workspace/source/?token=test-token');
