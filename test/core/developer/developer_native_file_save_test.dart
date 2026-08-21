import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_native_file_save.dart';

void main() {
  test('native save script streams a Blob body without base64', () {
    expect(playmeshNativeFileSaveScript, contains('body: blob'));
    expect(
      playmeshNativeFileSaveScript,
      contains('return Promise.resolve().then(async () =>'),
    );
    expect(
      playmeshNativeFileSaveScript,
      contains('/dev/api/gdevelop/native-file-saves'),
    );
    expect(
      playmeshNativeFileSaveScript,
      contains('credentials: "same-origin"'),
    );
    expect(playmeshNativeFileSaveScript, isNot(contains('FileReader')));
    expect(playmeshNativeFileSaveScript, isNot(contains('readAsDataURL')));
    expect(playmeshNativeFileSaveScript, isNot(contains('base64')));
    expect(
      playmeshNativeFileSaveScript,
      isNot(contains('requestId, ...payload')),
      reason: 'Gateway dev-* requestId must not replace the save-* id',
    );
    expect(
      playmeshNativeFileSaveScript,
      contains('protocolVersion: payload.protocolVersion'),
    );
  });

  test('parses a bounded authoritative ready receipt', () {
    const transferId = 'abcdefghijklmnopqrstuvwx';
    final message = DeveloperNativeFileSaveMessage.tryParse(
      jsonEncode({
        '__playmeshNativeFileSave': {
          'kind': 'ready',
          'requestId': 'save-abc-1',
          'protocolVersion': 1,
          'transferId': transferId,
          'downloadPath': '/dev/api/gdevelop/native-file-saves/$transferId',
          'filename': 'game.zip',
          'mimeType': 'application/zip',
          'size': 2048,
        },
      }),
    );

    expect(message, isNotNull);
    expect(message!.kind, DeveloperNativeFileSaveMessageKind.ready);
    expect(message.filename, 'game.zip');
    expect(message.size, 2048);
  });

  test('rejects a forged transfer path', () {
    final message = DeveloperNativeFileSaveMessage.tryParse(
      jsonEncode({
        '__playmeshNativeFileSave': {
          'kind': 'ready',
          'requestId': 'save-abc-1',
          'protocolVersion': 1,
          'transferId': 'abcdefghijklmnopqrstuvwx',
          'downloadPath': '/dev/api/projects/private',
          'filename': 'game.zip',
          'mimeType': 'application/zip',
          'size': 2048,
        },
      }),
    );

    expect(message, isNull);
  });

  test('ready receipt rejects non-string and unsafe filenames', () {
    for (final filename in <Object?>[
      42,
      '.',
      '..',
      'folder/game.zip',
      r'folder\game.zip',
      'game\u0000.zip',
      'game\u007f.zip',
    ]) {
      final message = DeveloperNativeFileSaveMessage.tryParse(
        jsonEncode({
          '__playmeshNativeFileSave': {
            'kind': 'ready',
            'requestId': 'save-abc-1',
            'protocolVersion': 1,
            'transferId': 'abcdefghijklmnopqrstuvwx',
            'downloadPath':
                '/dev/api/gdevelop/native-file-saves/'
                'abcdefghijklmnopqrstuvwx',
            'filename': filename,
            'mimeType': 'application/zip',
            'size': 2048,
          },
        }),
      );

      expect(message, isNull, reason: 'unsafe filename: $filename');
    }
  });

  test('parses bounded upload failures for visible host reporting', () {
    final message = DeveloperNativeFileSaveMessage.tryParse(
      jsonEncode({
        '__playmeshNativeFileSave': {
          'kind': 'error',
          'requestId': 'save-abc-1',
          'code': 'native_file_save_stage_failed',
          'message': 'staging failed',
        },
      }),
    );

    expect(message, isNotNull);
    expect(message!.kind, DeveloperNativeFileSaveMessageKind.error);
    expect(message.errorMessage, 'staging failed');
  });
}
