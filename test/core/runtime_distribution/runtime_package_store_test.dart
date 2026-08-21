import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_models.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_store_io.dart';

void main() {
  test(
    'fixed package paths use existence as the complete installed rule',
    () async {
      final root = await Directory.systemTemp.createTemp('runtime-store-');
      addTearDown(() => root.delete(recursive: true));
      final store = FileRuntimePackageStore(
        libraryRootResolver: () async => root,
      );

      final initial = await store.inspectAll();
      expect(initial, hasLength(3));
      expect(initial.every((status) => !status.installed), isTrue);
      expect(initial.map((status) => status.target.id), [
        'android-x86_64',
        'android-arm64',
        'windows-x64',
      ]);

      final manual = File(
        await store.installedFilePath(RuntimePackageTarget.androidArm),
      );
      await manual.writeAsBytes(const []);
      final installed = await store.inspect(RuntimePackageTarget.androidArm);

      expect(
        installed.installed,
        isTrue,
        reason: 'zero-byte manual fixtures still exist',
      );
      expect(installed.sizeBytes, 0);
      expect(
        installed.filePath,
        endsWith(
          'runtime${Platform.pathSeparator}packages${Platform.pathSeparator}playmesh-runtime-arm.apk',
        ),
      );
      expect(installed.toJson(), containsPair('installed', true));
    },
  );

  test(
    'commit replaces atomically and recovers an interrupted backup',
    () async {
      final root = await Directory.systemTemp.createTemp('runtime-commit-');
      addTearDown(() => root.delete(recursive: true));
      final store = FileRuntimePackageStore(
        libraryRootResolver: () async => root,
      );
      final destination = File(
        await store.installedFilePath(RuntimePackageTarget.windowsX64),
      );
      await destination.writeAsString('old');
      final downloadDirectory = Directory(
        await store.downloadDirectoryPath(RuntimePackageTarget.windowsX64),
      );
      final temporary = File(
        '${downloadDirectory.path}${Platform.pathSeparator}.new.download',
      );
      await temporary.writeAsString('new');

      final committed = await store.commitTemporaryFile(
        target: RuntimePackageTarget.windowsX64,
        temporaryFilePath: temporary.path,
      );

      expect(committed.installed, isTrue);
      expect(await destination.readAsString(), 'new');
      expect(await temporary.exists(), isFalse);

      final backup = File('${destination.path}.backup');
      await destination.rename(backup.path);
      final recovered = await store.inspect(RuntimePackageTarget.windowsX64);
      expect(recovered.installed, isTrue);
      expect(await destination.readAsString(), 'new');
      expect(await backup.exists(), isFalse);
    },
  );

  test('download transaction directories are isolated per target', () async {
    final root = await Directory.systemTemp.createTemp(
      'runtime-download-roots-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = FileRuntimePackageStore(
      libraryRootResolver: () async => root,
    );

    final paths = <String>{
      for (final target in RuntimePackageTarget.values)
        await store.downloadDirectoryPath(target),
    };

    expect(paths, hasLength(3));
    expect(paths.any((path) => path.endsWith('android-x86_64')), isTrue);
    expect(paths.any((path) => path.endsWith('android-arm64')), isTrue);
    expect(paths.any((path) => path.endsWith('windows-x64')), isTrue);
  });
}
