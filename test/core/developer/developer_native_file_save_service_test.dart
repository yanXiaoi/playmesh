import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_native_file_save.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_contract.dart';
import 'package:playmesh/core/developer/developer_native_file_save_service_io.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late List<int> archive;
  var getCount = 0;
  var deleteCount = 0;
  var authorizationHeaders = <String>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-save-service-test-');
    archive = List<int>.generate(4096, (index) => index % 251);
    getCount = 0;
    deleteCount = 0;
    authorizationHeaders = <String>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      authorizationHeaders.add(
        request.headers.value(HttpHeaders.authorizationHeader) ?? '',
      );
      if (request.method == 'GET') {
        getCount += 1;
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
        request.response.statusCode = HttpStatus.methodNotAllowed;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'desktop picker receives a streamed file and transfer is released',
    () async {
      final destination = File('${root.path}${Platform.pathSeparator}game.zip');
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (suggestedName, groups) async {
          expect(suggestedName, 'game.zip');
          expect(groups.single.extensions, ['zip']);
          return FileSaveLocation(destination.path);
        },
      );

      final result = await service.save(
        message: _readyMessage(server.port, archive.length),
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.saved);
      expect(result.path, destination.path);
      expect(await destination.readAsBytes(), archive);
      expect(getCount, 1);
      expect(deleteCount, 1);
      expect(authorizationHeaders, everyElement('Bearer test-token'));
    },
  );

  test(
    'desktop picker cancellation is silent and still releases staging',
    () async {
      final service = DeveloperNativeFileSaveServiceIo(
        saveLocationPicker: (_, _) async => null,
      );

      final result = await service.save(
        message: _readyMessage(server.port, archive.length),
        workspaceUri: _workspaceUri(server.port),
      );

      expect(result.outcome, DeveloperNativeFileSaveOutcome.cancelled);
      expect(getCount, 0);
      expect(deleteCount, 1);
    },
  );
}

Uri _workspaceUri(int port) => Uri.parse(
  'http://127.0.0.1:$port/dev/workspace/gdevelop/?token=test-token',
);

DeveloperNativeFileSaveMessage _readyMessage(int port, int size) {
  const transferId = 'abcdefghijklmnopqrstuvwx';
  final message = DeveloperNativeFileSaveMessage.tryParse(
    jsonEncode({
      '__playmeshNativeFileSave': {
        'kind': 'ready',
        'requestId': 'save-test-1',
        'protocolVersion': 1,
        'transferId': transferId,
        'downloadPath': '/dev/api/gdevelop/native-file-saves/$transferId',
        'filename': 'game.zip',
        'mimeType': 'application/zip',
        'size': size,
      },
    }),
  );
  return message!;
}
