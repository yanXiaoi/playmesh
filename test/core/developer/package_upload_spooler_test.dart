import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/package_upload_spooler.dart';

void main() {
  test('上传以 chunk 流式落唯一临时文件且成功后可完整清理', () async {
    final root = await Directory.systemTemp.createTemp('package-spool-test-');
    addTearDown(() => root.delete(recursive: true));
    final chunks = List<List<int>>.generate(
      1024,
      (index) => List<int>.filled(1024, index % 251),
    );
    final upload = await PackageUploadSpooler(
      maxBytes: 2 * 1024 * 1024,
      temporaryRoot: root,
    ).spool(Stream.fromIterable(chunks), declaredLength: 1024 * 1024);

    expect(upload.length, 1024 * 1024);
    expect(await upload.file.length(), upload.length);
    expect((await root.list().toList()), hasLength(1));
    await upload.dispose();
    expect(await root.list().toList(), isEmpty);
  });

  test('声明长度和实际流超限均拒绝且不留 partial', () async {
    final root = await Directory.systemTemp.createTemp('package-limit-test-');
    addTearDown(() => root.delete(recursive: true));
    final spooler = PackageUploadSpooler(maxBytes: 4, temporaryRoot: root);

    await expectLater(
      spooler.spool(Stream.value([1]), declaredLength: 5),
      throwsA(
        isA<PackageUploadTooLarge>().having((error) => error.limit, 'limit', 4),
      ),
    );
    expect(await root.list().toList(), isEmpty);

    await expectLater(
      spooler.spool(
        Stream.fromIterable(const [
          [1, 2],
          [3, 4, 5],
        ]),
      ),
      throwsA(isA<PackageUploadTooLarge>()),
    );
    expect(await root.list().toList(), isEmpty);
  });

  test('空闲超时、上游取消错误与空包均清理临时目录', () async {
    final root = await Directory.systemTemp.createTemp('package-timeout-test-');
    addTearDown(() => root.delete(recursive: true));
    final timeoutSpooler = PackageUploadSpooler(
      maxBytes: 1024,
      inactivityTimeout: const Duration(milliseconds: 10),
      temporaryRoot: root,
    );
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    controller.add(const [1, 2, 3]);
    await expectLater(
      timeoutSpooler.spool(controller.stream),
      throwsA(isA<TimeoutException>()),
    );
    expect(await root.list().toList(), isEmpty);

    await expectLater(
      timeoutSpooler.spool(
        Stream<List<int>>.error(StateError('client disconnected')),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await root.list().toList(), isEmpty);

    await expectLater(
      timeoutSpooler.spool(const Stream<List<int>>.empty()),
      throwsA(isA<PackageUploadEmpty>()),
    );
    expect(await root.list().toList(), isEmpty);
  });
}
