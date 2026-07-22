import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/library/playmesh_library_root.dart';

void main() {
  test('非移动端将资源库放在可执行文件同级', () async {
    final temporary = await Directory.systemTemp.createTemp('playmesh-root-');
    addTearDown(() => temporary.delete(recursive: true));
    final executable = File(
      '${temporary.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}playmesh.exe',
    );

    final root = await PlaymeshLibraryRoot.resolve(
      mobile: false,
      executablePath: executable.path,
    );

    expect(
      root.path,
      '${executable.parent.path}${Platform.pathSeparator}playmesh-library',
    );
    expect(await root.exists(), isTrue);
  });

  test('移动端将资源库放在应用支持目录', () async {
    final support = await Directory.systemTemp.createTemp('playmesh-support-');
    addTearDown(() => support.delete(recursive: true));

    final root = await PlaymeshLibraryRoot.resolve(
      mobile: true,
      applicationSupportDirectory: support,
    );

    expect(
      root.path,
      '${support.path}${Platform.pathSeparator}playmesh-library',
    );
    expect(await root.exists(), isTrue);
  });
}
