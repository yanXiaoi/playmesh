import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/developer_native_file_save_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-save-store-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('spools bytes to disk and releases the transfer', () async {
    final store = DeveloperNativeFileSaveStore(
      maxBytes: 64,
      temporaryRoot: root,
      random: Random(4),
    );
    final transfer = await store.create(
      input: Stream.value([1, 2, 3, 4]),
      declaredLength: 4,
      requestedFilename: '../unsafe\\game.zip',
      mimeType: 'application/zip; charset=binary',
    );

    expect(transfer.filename, 'game.zip');
    expect(transfer.mimeType, 'application/zip');
    expect(await transfer.file.readAsBytes(), [1, 2, 3, 4]);
    expect(store.activeTransferCount, 1);

    expect(await store.remove(transfer.id), isTrue);
    expect(store.activeTransferCount, 0);
    expect(await transfer.file.exists(), isFalse);
    await store.dispose();
  });

  test('expiry removes abandoned staged bytes', () async {
    final store = DeveloperNativeFileSaveStore(
      maxBytes: 64,
      retention: const Duration(milliseconds: 20),
      temporaryRoot: root,
      random: Random(5),
    );
    final transfer = await store.create(
      input: Stream.value([1]),
      requestedFilename: 'game.zip',
      mimeType: 'application/zip',
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(store.find(transfer.id), isNull);
    expect(await transfer.file.exists(), isFalse);
    await store.dispose();
  });
}
