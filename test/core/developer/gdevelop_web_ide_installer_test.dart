import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_project_context.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_io.dart';
import 'package:playmesh/core/download/safe_zip_extractor_contract.dart';
import 'package:playmesh/core/download/safe_zip_extractor_io.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

void main() {
  test(
    'fixed official install writes marker and removes transaction artifacts',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final release = await fixture.release('5.6.269', '<html>ready</html>');

      final result = await fixture.installer.install(spec: release.spec);
      final inspection = await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      );

      expect(result.marker.version, '5.6.269');
      expect(inspection.state, GDevelopWebIdeInstallationState.ready);
      expect(inspection.marker?.sha256, release.spec.sha256);
      expect(await release.archive.exists(), isFalse);
      expect(
        await fixture.officialFile('index.html').readAsString(),
        contains('ready'),
      );
      expect(await fixture.backup.exists(), isFalse);
      expect(await fixture.journal.exists(), isFalse);
      expect(
        await fixture.root
            .list()
            .where((entity) => entity.path.contains('.official-staging-'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test('same-version install still replaces official for repair', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final release = await fixture.release('5.6.269', '<html>clean</html>');
    await fixture.installer.install(spec: release.spec);
    final protected = await fixture.writeProtectedSentinels();
    await fixture.officialFile('tampered.txt').writeAsString('tampered');
    await release.restoreArchive();

    await fixture.installer.install(spec: release.spec);

    expect(await fixture.officialFile('tampered.txt').exists(), isFalse);
    expect(
      await fixture.officialFile('index.html').readAsString(),
      contains('clean'),
    );
    await _expectProtectedSentinels(protected);
  });

  test(
    'concurrent on-demand contract loads share the installed root lock',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final release = await fixture.release('5.6.269', '<html>ready</html>');
      await fixture.installer.install(spec: release.spec);

      final snapshots = await Future.wait([
        for (var index = 0; index < 8; index += 1)
          fixture.installer.loadInstalledAiTools(
            gdevelopRootPath: fixture.root.path,
          ),
      ]);

      expect(
        snapshots.map((snapshot) => snapshot.registry.contractHash).toSet(),
        hasLength(1),
      );
      expect(
        await File(
          '${fixture.root.path}${Platform.pathSeparator}.official-install.lock',
        ).exists(),
        isTrue,
      );
    },
  );

  test('schema 3 rejects invalid or unapproved libGD provenance', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final release = await fixture.release('5.6.269', '<html>ready</html>');
    final mutations = <void Function(Map)>[
      (provenance) => provenance.remove('userDecision'),
      (provenance) => provenance['kind'] = 'legacy-auto-fallback',
      (provenance) => provenance['userDecision'] = 'A',
      (provenance) =>
          ((provenance['files'] as Map)['libGD.js'] as Map)['sha256'] = 'wrong',
      (provenance) =>
          ((provenance['files'] as Map)['libGD.wasm'] as Map)['size'] = 0,
      (provenance) => provenance['unexpected'] = true,
    ];

    for (final mutate in mutations) {
      await release.restoreArchive();
      await fixture.installer.install(spec: release.spec);
      final integration = fixture.officialFile('playmesh-integration.json');
      final decoded = jsonDecode(await integration.readAsString()) as Map;
      mutate(decoded['libGdProvenance']! as Map);
      await integration.writeAsString(jsonEncode(decoded));
      expect(
        (await fixture.installer.inspect(
          gdevelopRootPath: fixture.root.path,
        )).state,
        GDevelopWebIdeInstallationState.needsRepair,
      );
    }
  });

  test('schema 3 accepts exact official commit libGD provenance', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final legacy = await fixture._libGdProvenance('5.6.276');
    final release = await fixture.release(
      '5.6.276',
      '<html>official commit</html>',
      libGdProvenance: {
        ...legacy,
        'kind': 'official-exact-commit-artifact',
        'source':
            'https://s3.amazonaws.com/gdevelop-gdevelop.js/master/commit/'
            '${List.filled(40, 'a').join()}',
        'userDecision': 'not-required',
      },
    );

    await fixture.installer.install(spec: release.spec);

    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.ready,
    );
  });

  test(
    'local archive reads version from schema3 and accepts one root folder',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final release = await fixture.release(
        '5.6.269',
        '<html>local package</html>',
      );
      final localSpec = await _wrapLocalArchive(release);

      final result = await fixture.installer.installLocalArchive(
        spec: localSpec,
      );

      expect(result.marker.version, '5.6.269');
      expect(
        await fixture.officialFile('index.html').readAsString(),
        contains('local package'),
      );
      expect(
        await fixture.officialFile('GDevelop/index.html').exists(),
        isFalse,
      );
    },
  );

  test('user-provided archive does not require release provenance', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final tools = await File(gdevelopAiToolContractTestPath).readAsBytes();
    final index = utf8.encode('<html>custom webide</html>');
    final archive = Archive()
      ..addFile(ArchiveFile('index.html', index.length, index))
      ..addFile(
        ArchiveFile(
          'THIRD_PARTY_NOTICES.md',
          _InstallerFixture._notices.length,
          _InstallerFixture._notices,
        ),
      )
      ..addFile(
        ArchiveFile(
          FileGDevelopWebIdeInstaller.aiToolsPath,
          tools.length,
          tools,
        ),
      );
    final spec = await _writeLocalSpec(
      fixture.root.path,
      ZipEncoder().encode(archive)!,
    );

    final installed = await fixture.installer.installLocalArchive(spec: spec);

    expect(
      installed.marker.installationKind,
      GDevelopWebIdeInstallationKind.userProvided,
    );
    expect(installed.marker.version, isNotEmpty);
    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.ready,
    );
  });

  test(
    'user-provided archive rejects an unsupported host execution kind',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final contract = loadGDevelopAiToolContractForTest();
      ((contract['tools'] as List).first as Map)['executionKind'] =
          'future_host_transport';
      final tools = utf8.encode(jsonEncode(contract));
      final index = utf8.encode('<html>custom webide</html>');
      final archive = Archive()
        ..addFile(ArchiveFile('index.html', index.length, index))
        ..addFile(
          ArchiveFile(
            'THIRD_PARTY_NOTICES.md',
            _InstallerFixture._notices.length,
            _InstallerFixture._notices,
          ),
        )
        ..addFile(
          ArchiveFile(
            FileGDevelopWebIdeInstaller.aiToolsPath,
            tools.length,
            tools,
          ),
        );
      final spec = await _writeLocalSpec(
        fixture.root.path,
        ZipEncoder().encode(archive)!,
      );

      await expectLater(
        fixture.installer.installLocalArchive(spec: spec),
        throwsA(
          isA<GDevelopWebIdeInstallException>().having(
            (error) => error.diagnostic,
            'diagnostic',
            'incompatible_ai_tools',
          ),
        ),
      );
    },
  );

  test(
    'bad local archive preserves the previous official installation',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final oldRelease = await fixture.release(
        '5.6.269',
        '<html>old remains</html>',
      );
      await fixture.installer.install(spec: oldRelease.spec);
      final protected = await fixture.writeProtectedSentinels();
      final invalidHtml = utf8.encode('<html>invalid</html>');
      final invalidBytes = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('index.html', invalidHtml.length, invalidHtml)),
      )!;
      final invalidSpec = await _writeLocalSpec(
        oldRelease.spec.gdevelopRootPath,
        invalidBytes,
      );

      await expectLater(
        fixture.installer.installLocalArchive(spec: invalidSpec),
        throwsA(
          isA<GDevelopWebIdeInstallException>().having(
            (error) => error.diagnostic,
            'diagnostic',
            'gdevelop_distribution_notices_missing',
          ),
        ),
      );

      expect(
        await fixture.officialFile('index.html').readAsString(),
        contains('old remains'),
      );
      await _expectProtectedSentinels(protected);
    },
  );

  test('missing marker or damaged identity reports needsRepair', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final release = await fixture.release('5.6.269', '<html>ready</html>');
    await fixture.installer.install(spec: release.spec);
    await fixture
        .officialFile(FileGDevelopWebIdeInstaller.installedMarkerName)
        .delete();

    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.needsRepair,
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    final integration = fixture.officialFile('playmesh-integration.json');
    final decoded = jsonDecode(await integration.readAsString()) as Map;
    decoded['upstreamTag'] = 'v0.0.0';
    await integration.writeAsString(jsonEncode(decoded));
    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.needsRepair,
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    await fixture.officialFile('playmesh-build-provenance.json').delete();
    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.needsRepair,
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    await fixture
        .officialFile('THIRD_PARTY_NOTICES.md')
        .writeAsString('tampered notices');
    final tamperedNotices = await fixture.installer.inspect(
      gdevelopRootPath: fixture.root.path,
    );
    expect(tamperedNotices.state, GDevelopWebIdeInstallationState.needsRepair);
    expect(
      tamperedNotices.diagnostic,
      'gdevelop_distribution_notices_identity_mismatch',
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    final oldMarker = fixture.officialFile(
      FileGDevelopWebIdeInstaller.installedMarkerName,
    );
    final oldMarkerJson = jsonDecode(await oldMarker.readAsString()) as Map;
    oldMarkerJson['schemaVersion'] = 2;
    oldMarkerJson
      ..remove('aiToolsPath')
      ..remove('aiToolsSha256')
      ..remove('aiToolsContractHash')
      ..remove('installationKind');
    await oldMarker.writeAsString(jsonEncode(oldMarkerJson));
    final oldMarkerInspection = await fixture.installer.inspect(
      gdevelopRootPath: fixture.root.path,
    );
    expect(
      oldMarkerInspection.state,
      GDevelopWebIdeInstallationState.needsRepair,
    );
    expect(oldMarkerInspection.diagnostic, 'gdevelop_marker_invalid');

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    final toolsFile = fixture.officialFile(
      FileGDevelopWebIdeInstaller.aiToolsPath.replaceAll(
        '/',
        Platform.pathSeparator,
      ),
    );
    await toolsFile.writeAsString(
      '${await toolsFile.readAsString()}\n',
      flush: true,
    );
    final tamperedTools = await fixture.installer.inspect(
      gdevelopRootPath: fixture.root.path,
    );
    expect(tamperedTools.state, GDevelopWebIdeInstallationState.needsRepair);
    expect(tamperedTools.diagnostic, 'gdevelop_ai_tools_identity_mismatch');
    await expectLater(
      fixture.installer.loadInstalledAiTools(
        gdevelopRootPath: fixture.root.path,
      ),
      throwsA(
        isA<GDevelopWebIdeInstallException>().having(
          (error) => error.diagnostic,
          'diagnostic',
          'gdevelop_ai_tools_identity_mismatch',
        ),
      ),
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    final legacyIntegration = fixture.officialFile('playmesh-integration.json');
    final legacyDecoded =
        jsonDecode(await legacyIntegration.readAsString()) as Map;
    legacyDecoded['schemaVersion'] = 2;
    await legacyIntegration.writeAsString(jsonEncode(legacyDecoded));
    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.needsRepair,
    );

    await release.restoreArchive();
    await fixture.installer.install(spec: release.spec);
    final mismatchedBuild = fixture.officialFile(
      'playmesh-build-provenance.json',
    );
    final mismatchedBuildDecoded =
        jsonDecode(await mismatchedBuild.readAsString()) as Map;
    mismatchedBuildDecoded['buildTreeSha256'] = List.filled(64, '3').join();
    await mismatchedBuild.writeAsString(jsonEncode(mismatchedBuildDecoded));
    expect(
      (await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      )).state,
      GDevelopWebIdeInstallationState.needsRepair,
    );
  });

  test(
    'cancel before staging preserves old official and verified archive',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final oldRelease = await fixture.release('5.6.269', '<html>old</html>');
      await fixture.installer.install(spec: oldRelease.spec);
      final protected = await fixture.writeProtectedSentinels();
      final next = await fixture.release('5.6.270', '<html>new</html>');
      final cancellation = DownloadCancellationToken()..cancel();

      await expectLater(
        fixture.installer.install(
          spec: next.spec,
          cancellationToken: cancellation,
        ),
        throwsA(
          isA<VerifiedDownloadException>().having(
            (error) => error.kind,
            'kind',
            VerifiedDownloadFailureKind.cancelled,
          ),
        ),
      );

      expect(
        await fixture.officialFile('index.html').readAsString(),
        contains('old'),
      );
      expect(await next.archive.exists(), isTrue);
      expect(await fixture.sourceSentinel.readAsString(), 'source workspace');
      await _expectProtectedSentinels(protected);
    },
  );

  test(
    'atomic rename failure rolls back and keeps old official usable',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final oldRelease = await fixture.release('5.6.269', '<html>old</html>');
      await fixture.installer.install(spec: oldRelease.spec);
      final protected = await fixture.writeProtectedSentinels();
      final next = await fixture.release('5.6.270', '<html>new</html>');
      var failed = false;
      final failingInstaller = FileGDevelopWebIdeInstaller(
        clock: fixture.clock,
        renameDirectory: (source, destination) async {
          final name = source.path.split(Platform.pathSeparator).last;
          if (!failed &&
              name.startsWith('.official-staging-') &&
              destination.endsWith('${Platform.pathSeparator}official')) {
            failed = true;
            throw FileSystemException('injected staging rename failure');
          }
          return source.rename(destination);
        },
      );

      await expectLater(
        failingInstaller.install(spec: next.spec),
        throwsA(isA<FileSystemException>()),
      );

      final inspection = await fixture.installer.inspect(
        gdevelopRootPath: fixture.root.path,
      );
      expect(inspection.state, GDevelopWebIdeInstallationState.ready);
      expect(inspection.marker?.version, '5.6.269');
      expect(
        await fixture.officialFile('index.html').readAsString(),
        contains('old'),
      );
      expect(await next.archive.exists(), isTrue);
      expect(await fixture.backup.exists(), isFalse);
      expect(await fixture.journal.exists(), isFalse);
      await _expectProtectedSentinels(protected);
    },
  );

  test(
    'same-root concurrent install is rejected instead of duplicated',
    () async {
      final fixture = await _InstallerFixture.create();
      addTearDown(fixture.close);
      final release = await fixture.release('5.6.269', '<html>ready</html>');
      final blocker = _BlockingZipExtractor();
      final installer = FileGDevelopWebIdeInstaller(
        zipExtractor: blocker,
        clock: fixture.clock,
      );

      final first = installer.install(spec: release.spec);
      await blocker.entered.future;
      await expectLater(
        installer.install(spec: release.spec),
        throwsA(isA<GDevelopWebIdeInstallBusyException>()),
      );
      blocker.release.complete();
      await first;
    },
  );

  test(
    'crash recovery promotes prepared new official only after backupMoved',
    () async {
      for (final phase in const ['prepared', 'backupMoved']) {
        final fixture = await _InstallerFixture.create();
        addTearDown(fixture.close);
        final oldRelease = await fixture.release('5.6.269', '<html>old</html>');
        await fixture.installer.install(spec: oldRelease.spec);
        final next = await fixture.release('5.6.270', '<html>new</html>');
        const stagingName = '.official-staging-crash';
        final staging = Directory(
          '${fixture.root.path}${Platform.pathSeparator}$stagingName',
        );
        await fixture.writeInstalledDirectory(
          staging,
          version: next.spec.version,
          sha256: next.spec.sha256,
          size: next.spec.size,
          index: '<html>new</html>',
        );
        await fixture.official.rename(fixture.backup.path);
        await fixture.journal.writeAsString(
          jsonEncode({
            'schemaVersion': 1,
            'phase': phase,
            'stagingName': stagingName,
            'version': next.spec.version,
            'sha256': next.spec.sha256,
            'size': next.spec.size,
          }),
        );

        await fixture.installer.recover(gdevelopRootPath: fixture.root.path);

        final inspection = await fixture.installer.inspect(
          gdevelopRootPath: fixture.root.path,
        );
        expect(inspection.state, GDevelopWebIdeInstallationState.ready);
        expect(
          inspection.marker?.version,
          phase == 'backupMoved' ? '5.6.270' : '5.6.269',
        );
        expect(await fixture.backup.exists(), isFalse);
        expect(await staging.exists(), isFalse);
        expect(await fixture.journal.exists(), isFalse);
      }
    },
  );

  test('archive identity mismatch cannot overwrite official', () async {
    final fixture = await _InstallerFixture.create();
    addTearDown(fixture.close);
    final oldRelease = await fixture.release('5.6.269', '<html>old</html>');
    await fixture.installer.install(spec: oldRelease.spec);
    final next = await fixture.release('5.6.270', '<html>new</html>');
    final bytes = await next.archive.readAsBytes();
    bytes[0] ^= 0xff;
    await next.archive.writeAsBytes(bytes);

    await expectLater(
      fixture.installer.install(spec: next.spec),
      throwsA(
        isA<GDevelopWebIdeInstallException>().having(
          (error) => error.diagnostic,
          'diagnostic',
          'gdevelop_archive_identity_mismatch',
        ),
      ),
    );
    expect(
      await fixture.officialFile('index.html').readAsString(),
      contains('old'),
    );
  });
}

class _InstallerFixture {
  _InstallerFixture({
    required this.base,
    required this.root,
    required this.sourceSentinel,
    required this.installer,
  });

  final Directory base;
  final Directory root;
  final File sourceSentinel;
  final FileGDevelopWebIdeInstaller installer;

  DateTime clock() => DateTime.utc(2026, 8, 5, 1, 2, 3);

  Directory get official =>
      Directory('${root.path}${Platform.pathSeparator}official');
  Directory get backup =>
      Directory('${root.path}${Platform.pathSeparator}.official-backup');
  File get journal =>
      File('${root.path}${Platform.pathSeparator}official-install.json');

  static Future<_InstallerFixture> create() async {
    final base = await Directory.systemTemp.createTemp('gdevelop-installer-');
    final root = Directory('${base.path}${Platform.pathSeparator}GDevelop');
    await Directory(
      '${root.path}${Platform.pathSeparator}downloads',
    ).create(recursive: true);
    final source = Directory(
      '${base.path}${Platform.pathSeparator}source-workspace',
    );
    await source.create();
    final sentinel = File('${source.path}${Platform.pathSeparator}keep.txt');
    await sentinel.writeAsString('source workspace');
    return _InstallerFixture(
      base: base,
      root: root,
      sourceSentinel: sentinel,
      installer: FileGDevelopWebIdeInstaller(
        clock: () => DateTime.utc(2026, 8, 5, 1, 2, 3),
      ),
    );
  }

  Future<_ReleaseFixture> release(
    String version,
    String index, {
    Map<String, Object>? libGdProvenance,
  }) async {
    final resolvedLibGdProvenance =
        libGdProvenance ?? await _libGdProvenance(version);
    final integration = _integration(version, resolvedLibGdProvenance);
    final buildProvenance = _buildProvenance(version, resolvedLibGdProvenance);
    final aiTools = await File(gdevelopAiToolContractTestPath).readAsBytes();
    final archiveValue = Archive()
      ..addFile(ArchiveFile('index.html', index.length, utf8.encode(index)))
      ..addFile(
        ArchiveFile(
          'playmesh-build-provenance.json',
          utf8.encode(buildProvenance).length,
          utf8.encode(buildProvenance),
        ),
      )
      ..addFile(
        ArchiveFile(
          'playmesh-integration.json',
          utf8.encode(integration).length,
          utf8.encode(integration),
        ),
      )
      ..addFile(
        ArchiveFile('THIRD_PARTY_NOTICES.md', _notices.length, _notices),
      )
      ..addFile(
        ArchiveFile('libGD.js', _libGdJavascript.length, _libGdJavascript),
      )
      ..addFile(ArchiveFile('libGD.wasm', _libGdWasm.length, _libGdWasm))
      ..addFile(ArchiveFile('assets/app.js', 3, const [1, 2, 3]));
    archiveValue.addFile(
      ArchiveFile(
        FileGDevelopWebIdeInstaller.aiToolsPath,
        aiTools.length,
        aiTools,
      ),
    );
    final bytes = ZipEncoder().encode(archiveValue)!;
    final sha256 = await _sha256(bytes);
    final archive = File(
      '${root.path}${Platform.pathSeparator}downloads'
      '${Platform.pathSeparator}$sha256.zip',
    );
    await archive.writeAsBytes(bytes);
    return _ReleaseFixture(
      archive: archive,
      bytes: bytes,
      spec: GDevelopWebIdeInstallSpec(
        gdevelopRootPath: root.path,
        archivePath: archive.path,
        version: version,
        sha256: sha256,
        size: bytes.length,
      ),
    );
  }

  Future<void> writeInstalledDirectory(
    Directory target, {
    required String version,
    required String sha256,
    required int size,
    required String index,
  }) async {
    final libGdProvenance = await _libGdProvenance(version);
    await target.create(recursive: true);
    await File(
      '${target.path}${Platform.pathSeparator}index.html',
    ).writeAsString(index);
    await File(
      '${target.path}${Platform.pathSeparator}playmesh-build-provenance.json',
    ).writeAsString(_buildProvenance(version, libGdProvenance));
    await File(
      '${target.path}${Platform.pathSeparator}playmesh-integration.json',
    ).writeAsString(_integration(version, libGdProvenance));
    await File(
      '${target.path}${Platform.pathSeparator}libGD.js',
    ).writeAsBytes(_libGdJavascript);
    await File(
      '${target.path}${Platform.pathSeparator}libGD.wasm',
    ).writeAsBytes(_libGdWasm);
    await File(
      '${target.path}${Platform.pathSeparator}THIRD_PARTY_NOTICES.md',
    ).writeAsBytes(_notices);
    final aiTools = await File(gdevelopAiToolContractTestPath).readAsBytes();
    final aiToolsFile = File(
      '${target.path}${Platform.pathSeparator}'
      '${FileGDevelopWebIdeInstaller.aiToolsPath.replaceAll('/', Platform.pathSeparator)}',
    );
    await aiToolsFile.parent.create(recursive: true);
    await aiToolsFile.writeAsBytes(aiTools);
    final aiToolsContract = loadGDevelopAiToolContractForTest();
    final aiToolsCapabilities =
        await GDevelopAiProjectContext.capabilitiesReference(aiToolsContract);
    await File(
      '${target.path}${Platform.pathSeparator}'
      '${FileGDevelopWebIdeInstaller.installedMarkerName}',
    ).writeAsString(
      jsonEncode({
        'schemaVersion': 3,
        'version': version,
        'sha256': sha256,
        'noticesSha256': await _sha256(_notices),
        'aiToolsPath': FileGDevelopWebIdeInstaller.aiToolsPath,
        'aiToolsSha256': await _sha256(aiTools),
        'aiToolsContractHash': aiToolsCapabilities['contractHash'],
        'size': size,
        'installedAt': '2026-08-05T01:02:03.000Z',
        'installationKind': 'release',
      }),
    );
  }

  File officialFile(String relativePath) =>
      File('${official.path}${Platform.pathSeparator}$relativePath');

  Map<String, Object> _provenanceBase(String version) => {
    'policyRevision': 17,
    'upstreamTag': 'v$version',
    'upstreamCommit': List.filled(40, 'a').join(),
    'upstreamSourceArchiveSha256': List.filled(64, 'a').join(),
    'sourcePolicyManifestSha256': List.filled(64, 'b').join(),
    'sourcePolicyOverlayTreeSha256': List.filled(64, 'c').join(),
    'sourcePolicyGeneratedFilesSha256': List.filled(64, 'd').join(),
    'sourcePolicyPatchedOfficialFilesSha256': List.filled(64, 'e').join(),
    'patchedSourceSha256': List.filled(64, 'f').join(),
  };

  static const _libGdJavascript = <int>[1, 2, 3, 4];
  static const _libGdWasm = <int>[0, 97, 115, 109, 1, 0, 0, 0];
  static final _notices = utf8.encode('fixture third-party notices');

  Future<Map<String, Object>> _libGdProvenance(String version) async => {
    'kind': 'approved-legacy-prepared-exception',
    'source': Platform.isWindows
        ? r'F:\Project\flutter\playmesh\work\gdevelop-webide-prepared-5.6.269'
        : '/tmp/playmesh/gdevelop-webide-prepared-5.6.269',
    'upstreamVersion': version,
    'files': <String, Object>{
      'libGD.js': <String, Object>{
        'sha256': await _sha256(_libGdJavascript),
        'size': _libGdJavascript.length,
      },
      'libGD.wasm': <String, Object>{
        'sha256': await _sha256(_libGdWasm),
        'size': _libGdWasm.length,
      },
    },
    'userDecision': 'B',
  };

  String _buildProvenance(
    String version,
    Map<String, Object> libGdProvenance,
  ) => jsonEncode({
    'schemaVersion': 1,
    'artifactKind': 'playmesh-gdevelop-webide-build',
    ..._provenanceBase(version),
    'buildTreeSha256': List.filled(64, '1').join(),
    'libGdProvenance': libGdProvenance,
    'sourcePolicyScript': 'playmesh/scripts/apply-source-policy.mjs',
    'buildAuditScript': 'playmesh/tests/test-production-build-audit.mjs',
  });

  String _integration(String version, Map<String, Object> libGdProvenance) =>
      jsonEncode({
        'schemaVersion': 3,
        'artifactKind': 'playmesh-gdevelop-webide-prepared',
        ..._provenanceBase(version),
        'buildTreeSha256': List.filled(64, '1').join(),
        'preparedTreeSha256': List.filled(64, '2').join(),
        'libGdProvenance': libGdProvenance,
        'sourcePolicyScript': 'playmesh/scripts/apply-source-policy.mjs',
        'buildAuditScript': 'playmesh/tests/test-production-build-audit.mjs',
        'packagePolicyScript': 'playmesh/scripts/prepare-webide.mjs',
      });

  Future<List<_ProtectedSentinel>> writeProtectedSentinels() async {
    final values = <String, String>{
      '${root.path}${Platform.pathSeparator}projects'
              '${Platform.pathSeparator}current-project.json':
          'project',
      '${root.path}${Platform.pathSeparator}history'
              '${Platform.pathSeparator}revision.json':
          'history',
      '${root.path}${Platform.pathSeparator}gateway'
              '${Platform.pathSeparator}metadata.json':
          'gateway',
      '${base.path}${Platform.pathSeparator}webview-profile'
              '${Platform.pathSeparator}IndexedDB.keep':
          'webview profile',
    };
    final sentinels = <_ProtectedSentinel>[];
    for (final entry in values.entries) {
      final file = File(entry.key);
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
      sentinels.add(_ProtectedSentinel(file: file, contents: entry.value));
    }
    return sentinels;
  }

  Future<void> close() async {
    if (await base.exists()) await base.delete(recursive: true);
  }
}

class _ProtectedSentinel {
  const _ProtectedSentinel({required this.file, required this.contents});

  final File file;
  final String contents;
}

Future<void> _expectProtectedSentinels(
  Iterable<_ProtectedSentinel> sentinels,
) async {
  for (final sentinel in sentinels) {
    expect(await sentinel.file.readAsString(), sentinel.contents);
  }
}

class _ReleaseFixture {
  const _ReleaseFixture({
    required this.archive,
    required this.bytes,
    required this.spec,
  });

  final File archive;
  final List<int> bytes;
  final GDevelopWebIdeInstallSpec spec;

  Future<void> restoreArchive() => archive.writeAsBytes(bytes);
}

class _BlockingZipExtractor implements SafeZipExtractor {
  final entered = Completer<void>();
  final release = Completer<void>();
  final delegate = const IoSafeZipExtractor();

  @override
  Future<SafeZipExtractionResult> extract({
    required String archivePath,
    required String destinationPath,
    DownloadCancellationToken? cancellationToken,
  }) async {
    entered.complete();
    await release.future;
    return delegate.extract(
      archivePath: archivePath,
      destinationPath: destinationPath,
      cancellationToken: cancellationToken,
    );
  }
}

Future<String> _sha256(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}

Future<GDevelopWebIdeLocalInstallSpec> _wrapLocalArchive(
  _ReleaseFixture release,
) async {
  final decoded = ZipDecoder().decodeBytes(release.bytes);
  final wrapped = Archive();
  for (final entry in decoded.files.where((entry) => entry.isFile)) {
    final content = entry.content as List<int>;
    wrapped.addFile(
      ArchiveFile('GDevelop/${entry.name}', content.length, content),
    );
  }
  return _writeLocalSpec(
    release.spec.gdevelopRootPath,
    ZipEncoder().encode(wrapped)!,
  );
}

Future<GDevelopWebIdeLocalInstallSpec> _writeLocalSpec(
  String rootPath,
  List<int> bytes,
) async {
  final sha256 = await _sha256(bytes);
  final archive = File(
    '$rootPath${Platform.pathSeparator}downloads'
    '${Platform.pathSeparator}$sha256.zip',
  );
  await archive.parent.create(recursive: true);
  await archive.writeAsBytes(bytes);
  return GDevelopWebIdeLocalInstallSpec(
    gdevelopRootPath: rootPath,
    archivePath: archive.path,
    sha256: sha256,
    size: bytes.length,
  );
}
