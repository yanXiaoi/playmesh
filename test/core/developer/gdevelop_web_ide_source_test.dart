import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source_io.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';

void main() {
  test(
    'source recovers and validates the fixed official root before serving',
    () async {
      final fixture = await _SourceFixture.create();
      addTearDown(fixture.close);
      final installer = _SourceInstaller(
        inspections: [fixture.readyInspection, fixture.readyInspection],
      );
      final source = FileGDevelopWebIdeSource(
        root: fixture.official,
        installer: installer,
      );

      expect(await source.isAvailable(), isTrue);
      expect(
        utf8.decode((await source.read('index.html'))!),
        '<html>ready</html>',
      );
      expect(installer.inspectedRoots, [fixture.root.path, fixture.root.path]);
    },
  );

  test(
    'index navigation rechecks identity and blocks a damaged installation',
    () async {
      final fixture = await _SourceFixture.create();
      addTearDown(fixture.close);
      final installer = _SourceInstaller(
        inspections: [
          fixture.readyInspection,
          const GDevelopWebIdeInstallationInspection(
            state: GDevelopWebIdeInstallationState.needsRepair,
            diagnostic: 'gdevelop_marker_missing',
          ),
        ],
      );
      final source = FileGDevelopWebIdeSource(
        root: fixture.official,
        installer: installer,
      );

      expect(await source.isAvailable(), isTrue);
      expect(await source.read('index.html'), isNull);
      expect(await fixture.index.exists(), isTrue, reason: '检查不得删除损坏目录');
    },
  );

  test(
    'recovery failure remains a soft dependency for Developer Gateway',
    () async {
      final fixture = await _SourceFixture.create();
      addTearDown(fixture.close);
      final installer = _SourceInstaller(error: FileSystemException('locked'));
      final source = FileGDevelopWebIdeSource(
        root: fixture.official,
        installer: installer,
      );

      expect(await source.isAvailable(), isFalse);
      expect(await source.read('index.html'), isNull);
      expect(await fixture.index.readAsString(), '<html>ready</html>');
    },
  );
}

class _SourceFixture {
  _SourceFixture({
    required this.base,
    required this.root,
    required this.official,
    required this.index,
  });

  final Directory base;
  final Directory root;
  final Directory official;
  final File index;

  GDevelopWebIdeInstallationInspection get readyInspection =>
      GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.ready,
        marker: GDevelopWebIdeInstalledMarker(
          version: '5.6.269',
          sha256: List.filled(64, 'd').join(),
          noticesSha256: List.filled(64, 'e').join(),
          aiToolsPath: 'playmesh/ai/tools.json',
          aiToolsSha256: List.filled(64, 'f').join(),
          aiToolsContractHash: List.filled(64, 'a').join(),
          size: 123,
          installedAt: DateTime.utc(2026, 8, 5),
          installationKind: GDevelopWebIdeInstallationKind.release,
        ),
      );

  static Future<_SourceFixture> create() async {
    final base = await Directory.systemTemp.createTemp('gdevelop-source-');
    final root = Directory('${base.path}${Platform.pathSeparator}GDevelop');
    final official = Directory('${root.path}${Platform.pathSeparator}official');
    await official.create(recursive: true);
    final index = File('${official.path}${Platform.pathSeparator}index.html');
    await index.writeAsString('<html>ready</html>');
    return _SourceFixture(
      base: base,
      root: root,
      official: official,
      index: index,
    );
  }

  Future<void> close() async {
    if (await base.exists()) await base.delete(recursive: true);
  }
}

class _SourceInstaller implements GDevelopWebIdeInstaller {
  _SourceInstaller({
    List<GDevelopWebIdeInstallationInspection> inspections = const [],
    this.error,
  }) : _inspections = List.of(inspections);

  final List<GDevelopWebIdeInstallationInspection> _inspections;
  final Object? error;
  final List<String> inspectedRoots = [];

  @override
  Future<GDevelopWebIdeInstallationInspection> inspect({
    required String gdevelopRootPath,
  }) async {
    inspectedRoots.add(gdevelopRootPath);
    if (error case final current?) throw current;
    return _inspections.removeAt(0);
  }

  @override
  Future<GDevelopWebIdeInstallResult> install({
    required GDevelopWebIdeInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) => throw UnimplementedError();

  @override
  Future<GDevelopWebIdeInstallResult> installLocalArchive({
    required GDevelopWebIdeLocalInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) => throw UnimplementedError();

  @override
  Future<GDevelopWebIdeInstalledAiTools> loadInstalledAiTools({
    required String gdevelopRootPath,
  }) => throw UnimplementedError();

  @override
  Future<void> recover({required String gdevelopRootPath}) async {}
}
