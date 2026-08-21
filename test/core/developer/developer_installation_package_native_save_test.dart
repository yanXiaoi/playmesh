import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_native_file_save.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_contract.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_io.dart';

void main() {
  const apkMimeType = 'application/vnd.android.package-archive';
  const zipMimeType = 'application/zip';
  const exportId = 'abcdefghijklmnopqrstuvwx';
  const downloadPath =
      '/dev/api/projects/com.example.party/package-exports/$exportId';

  group('安装包原生保存消息', () {
    test('接受带完整元数据的 APK 和 Windows ZIP', () {
      final apk = _downloadMessage(
        downloadPath: downloadPath,
        filename: 'party-v1.2.3.apk',
        mimeType: apkMimeType,
        size: 8192,
      );
      final zip = _downloadMessage(
        downloadPath: downloadPath,
        filename: 'party-v1.2.3.zip',
        mimeType: zipMimeType,
        size: 16384,
      );

      expect(apk, isNotNull);
      expect(apk!.kind, DeveloperNativeFileSaveMessageKind.download);
      expect(apk.downloadPath, downloadPath);
      expect(apk.filename, 'party-v1.2.3.apk');
      expect(apk.mimeType, apkMimeType);
      expect(apk.size, 8192);
      expect(zip, isNotNull);
      expect(zip!.filename, 'party-v1.2.3.zip');
      expect(zip.mimeType, zipMimeType);
      expect(zip.size, 16384);
    });

    test('APK 和 ZIP 都必须提供 filename、mimeType 与正整数 size', () {
      for (final fixture in const [
        ('game.apk', apkMimeType),
        ('game.zip', zipMimeType),
      ]) {
        final complete = <String, Object?>{
          'filename': fixture.$1,
          'mimeType': fixture.$2,
          'size': 1024,
        };
        for (final missing in complete.keys) {
          final metadata = Map<String, Object?>.from(complete)..remove(missing);
          expect(
            _rawDownloadMessage(downloadPath, metadata),
            isNull,
            reason: '${fixture.$1} 缺少 $missing 时不得进入原生保存',
          );
        }
        expect(
          _rawDownloadMessage(downloadPath, {...complete, 'size': 0}),
          isNull,
        );
        expect(
          _rawDownloadMessage(downloadPath, {
            ...complete,
            'size': developerNativeFileSaveMaxSafeSize + 1,
          }),
          isNull,
        );
      }
      expect(
        _downloadMessage(
          downloadPath: downloadPath,
          filename: 'game.apk',
          mimeType: 'application/octet-stream',
          size: 1024,
        ),
        isNull,
      );
    });

    test('filename 必须是安全的原生字符串', () {
      for (final filename in <Object?>[
        42,
        '',
        '.',
        '..',
        'a' * 513,
        'folder/game.apk',
        r'folder\game.apk',
        'game\u0000.apk',
        'game\u001f.apk',
        'game\u007f.apk',
      ]) {
        expect(
          _rawDownloadMessage(downloadPath, {
            'filename': filename,
            'mimeType': apkMimeType,
            'size': 1024,
          }),
          isNull,
          reason: 'unsafe filename: $filename',
        );
      }
    });

    test('拒绝跨源、查询参数和不合法 exportId 路径', () {
      for (final path in [
        '/dev/api/projects/com.example.party/package-exports/short',
        '/dev/api/projects/com.example.party/package-exports/${'a' * 19}',
        '/dev/api/projects/com.example.party/package-exports/${'a' * 65}',
        '/dev/api/projects/com.example.party/package-exports/abc%2Fdefghijklmnopqrst',
        '/dev/api/projects/com.example.party/package-exports/$exportId?x=1',
        '/dev/api/projects/com.example.party/package-exports/$exportId#x',
        '/dev/api/projects/com.example.party/package/$exportId',
        'https://example.com/dev/api/projects/com.example.party/package-exports/$exportId',
      ]) {
        expect(
          _downloadMessage(
            downloadPath: path,
            filename: 'game.apk',
            mimeType: apkMimeType,
            size: 1024,
          ),
          isNull,
          reason: path,
        );
      }
    });

    test('拒绝错误协议版本和非整数 size', () {
      for (final size in <Object?>['1024', 1024.0, -1]) {
        expect(
          _rawDownloadMessage(downloadPath, {
            'filename': 'game.apk',
            'mimeType': apkMimeType,
            'size': size,
          }),
          isNull,
        );
      }
      expect(
        DeveloperNativeFileSaveMessage.tryParse(
          jsonEncode({
            '__playmeshNativeFileSave': {
              'kind': 'download',
              'requestId': 'save-installation-1',
              'protocolVersion': 2,
              'downloadPath': downloadPath,
              'filename': 'game.apk',
              'mimeType': apkMimeType,
              'size': 1024,
            },
          }),
        ),
        isNull,
      );
    });
  });

  group('安装包原生保存服务', () {
    late Directory root;
    late HttpServer server;
    late List<int> packageBytes;
    late List<(String, String, String)> requests;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'installation-package-native-save-',
      );
      packageBytes = List<int>.generate(8192, (index) => index % 251);
      requests = <(String, String, String)>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add((
          request.method,
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
        ));
        if (request.method == 'GET' && request.uri.path == downloadPath) {
          request.response.contentLength = packageBytes.length;
          request.response.add(packageBytes);
        } else if (request.method == 'DELETE' &&
            request.uri.path == downloadPath) {
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

    test('流式保存 APK 后 DELETE 同一安装包路由', () async {
      final destination = File(
        '${root.path}${Platform.pathSeparator}party.apk',
      );
      await destination.writeAsBytes(const [9, 8, 7], flush: true);
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (suggestedName, groups) async {
          expect(suggestedName, 'party-v1.2.3.apk');
          expect(groups.single.extensions, ['apk']);
          return FileSaveLocation(destination.path);
        },
      );

      final result = await service.save(
        message: _downloadMessage(
          downloadPath: downloadPath,
          filename: 'party-v1.2.3.apk',
          mimeType: apkMimeType,
          size: packageBytes.length,
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.saved);
      expect(result.path, destination.path);
      expect(await destination.readAsBytes(), packageBytes);
      expect(
        root.listSync().whereType<File>().map((file) => file.path),
        [destination.path],
        reason: '成功覆盖后不得遗留 partial 或 backup 文件',
      );
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });

    test('Windows 提交新文件后备份清理瞬时失败仍返回成功且重试清理', () async {
      final destination = File(
        '${root.path}${Platform.pathSeparator}retry-backup.apk',
      );
      await destination.writeAsBytes(const [9, 8, 7], flush: true);
      var backupDeleteAttempts = 0;
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (_, _) async => FileSaveLocation(destination.path),
        backupFileDelete: (file) async {
          backupDeleteAttempts += 1;
          if (backupDeleteAttempts == 1) {
            throw FileSystemException('模拟备份文件被短暂占用', file.path);
          }
          await file.delete();
        },
      );

      final result = await service.save(
        message: _downloadMessage(
          downloadPath: downloadPath,
          filename: 'party-v1.2.3.apk',
          mimeType: apkMimeType,
          size: packageBytes.length,
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.saved);
      expect(await destination.readAsBytes(), packageBytes);
      expect(backupDeleteAttempts, 2);
      expect(
        root.listSync().whereType<File>().map((file) => file.path),
        [destination.path],
        reason: '事务提交后的瞬时清理失败不得误报失败或遗留可重试垃圾',
      );
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });

    test('取消 Windows ZIP 保存也 DELETE 同一安装包路由', () async {
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (suggestedName, groups) async {
          expect(suggestedName, 'party-v1.2.3.zip');
          expect(groups.single.extensions, ['zip']);
          return null;
        },
      );

      final result = await service.save(
        message: _downloadMessage(
          downloadPath: downloadPath,
          filename: 'party-v1.2.3.zip',
          mimeType: zipMimeType,
          size: packageBytes.length,
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.cancelled);
      expect(requests, [('DELETE', downloadPath, 'Bearer test-token')]);
    });

    test('Content-Length 与消息 size 不一致时拒绝文件且仍释放路由', () async {
      final destination = File(
        '${root.path}${Platform.pathSeparator}invalid.apk',
      );
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (_, _) async => FileSaveLocation(destination.path),
      );

      await expectLater(
        service.save(
          message: _downloadMessage(
            downloadPath: downloadPath,
            filename: 'party-v1.2.3.apk',
            mimeType: apkMimeType,
            size: packageBytes.length + 1,
          )!,
          workspaceUri: _workspaceUri(server.port),
        ),
        throwsA(isA<FormatException>()),
      );

      expect(await destination.exists(), isFalse);
      expect(
        root.listSync().whereType<File>(),
        isEmpty,
        reason: '长度校验失败不得遗留 partial 文件',
      );
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });

    test('覆盖中断时保留旧目标并清理 partial', () async {
      final destination = File(
        '${root.path}${Platform.pathSeparator}existing.apk',
      );
      const oldBytes = [6, 5, 4, 3];
      await destination.writeAsBytes(oldBytes, flush: true);
      final blockedBackup = Directory(
        '${destination.path}.playmesh-backup-save-installation-1',
      );
      await blockedBackup.create();
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (_, _) async => FileSaveLocation(destination.path),
      );

      await expectLater(
        service.save(
          message: _downloadMessage(
            downloadPath: downloadPath,
            filename: 'party-v1.2.3.apk',
            mimeType: apkMimeType,
            size: packageBytes.length,
          )!,
          workspaceUri: _workspaceUri(server.port),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await destination.readAsBytes(), oldBytes);
      expect(
        await File(
          '${destination.path}.playmesh-part-save-installation-1',
        ).exists(),
        isFalse,
      );
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });

    test('移动端长展示文件名只通过分享参数传递', () async {
      final longFilename = '${List.filled(80, '游').join()}-v1.2.3.apk';
      File? sharedFile;
      String? sharedFilename;
      final service = DeveloperNativeFileSaveServiceIo(
        shareOnMobile: true,
        temporaryDirectory: () async => root,
        shareFile: (file, filename, mimeType, sharePositionOrigin) async {
          sharedFile = file;
          sharedFilename = filename;
          expect(mimeType, apkMimeType);
          expect(await file.readAsBytes(), packageBytes);
          return DeveloperNativeShareDisposition.accepted;
        },
      );

      final result = await service.save(
        message: _downloadMessage(
          downloadPath: downloadPath,
          filename: longFilename,
          mimeType: apkMimeType,
          size: packageBytes.length,
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.shared);
      expect(sharedFilename, longFilename);
      expect(sharedFile, isNotNull);
      expect(
        sharedFile!.path.split(Platform.pathSeparator).last,
        'payload.apk',
      );
      expect(sharedFile!.path, isNot(contains(longFilename)));
      expect(
        sharedFile!.parent.path.split(Platform.pathSeparator).last.codeUnits,
        everyElement(lessThan(128)),
        reason: '移动端内部临时路径必须只使用短 ASCII 名称',
      );
      expect(result.path, sharedFile!.path);
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });

    test('移动端取消分享时移除独立临时目录并释放产物', () async {
      final service = DeveloperNativeFileSaveServiceIo(
        shareOnMobile: true,
        temporaryDirectory: () async => root,
        shareFile: (_, _, _, _) async =>
            DeveloperNativeShareDisposition.cancelled,
      );

      final result = await service.save(
        message: _downloadMessage(
          downloadPath: downloadPath,
          filename: 'party-v1.2.3.apk',
          mimeType: apkMimeType,
          size: packageBytes.length,
        )!,
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.cancelled);
      final shareRoot = Directory(
        '${root.path}${Platform.pathSeparator}playmesh-native-file-saves',
      );
      expect(shareRoot.listSync(), isEmpty);
      expect(requests, [
        ('GET', downloadPath, 'Bearer test-token'),
        ('DELETE', downloadPath, 'Bearer test-token'),
      ]);
    });
  });
}

DeveloperNativeFileSaveMessage? _downloadMessage({
  required String downloadPath,
  required String filename,
  required String mimeType,
  required int size,
}) => _rawDownloadMessage(downloadPath, {
  'filename': filename,
  'mimeType': mimeType,
  'size': size,
});

DeveloperNativeFileSaveMessage? _rawDownloadMessage(
  String downloadPath,
  Map<String, Object?> metadata,
) => DeveloperNativeFileSaveMessage.tryParse(
  jsonEncode({
    '__playmeshNativeFileSave': {
      'kind': 'download',
      'requestId': 'save-installation-1',
      'protocolVersion': 1,
      'downloadPath': downloadPath,
      ...metadata,
    },
  }),
);

Uri _workspaceUri(int port) =>
    Uri.parse('http://127.0.0.1:$port/dev/workspace/?token=test-token');
