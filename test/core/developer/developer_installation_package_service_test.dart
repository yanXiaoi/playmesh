import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_installation_package_service.dart';
import 'package:playmesh/core/developer/developer_installation_package_service_io.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/core/runtime_distribution/runtime_package_manager.dart';
import 'package:playmesh/core/runtime_export/runtime_native_exporter_contract.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 原生导出请求序列化外观和可选图标路径', () {
    const withIcon = RuntimeWindowsNativeExportRequest(
      templateZipPath: 'runtime.zip',
      clearGamePackagePath: 'game.zip',
      outputZipPath: 'output.zip',
      executableName: 'My Game.exe',
      label: 'My Game',
      versionName: '1.2.3',
      iconPath: 'icon.png',
    );
    expect(withIcon.toJson(), {
      'templateZipPath': 'runtime.zip',
      'clearGamePackagePath': 'game.zip',
      'outputZipPath': 'output.zip',
      'executableName': 'My Game.exe',
      'label': 'My Game',
      'versionName': '1.2.3',
      'iconPath': 'icon.png',
    });

    const withoutIcon = RuntimeWindowsNativeExportRequest(
      templateZipPath: 'runtime.zip',
      clearGamePackagePath: 'game.zip',
      outputZipPath: 'output.zip',
      executableName: 'game.exe',
      label: 'Game',
      versionName: '1.0.0',
    );
    expect(withoutIcon.toJson(), isNot(contains('iconPath')));
  });

  group('runtimeAndroidApplicationId', () {
    test('直接使用格式化后的多段 gameId', () {
      expect(
        runtimeAndroidApplicationId('com.playmesh.game-3b1p45k3a1'),
        'com.playmesh.game3b1p45k3a1',
      );
      expect(
        runtimeAndroidApplicationId('Studio_Name.Game--One'),
        'Studio_Name.GameOne',
      );
    });

    test('单段 ID 补 playmesh 前缀，数字或下划线开头的段补 g', () {
      expect(runtimeAndroidApplicationId('solo-game'), 'playmesh.sologame');
      expect(runtimeAndroidApplicationId('123.demo'), 'g123.demo');
      expect(runtimeAndroidApplicationId('com._private'), 'com.g_private');
    });

    test('拒绝无法形成包名和超过 Android 长度上限的 ID', () {
      expect(
        () => runtimeAndroidApplicationId('---'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => runtimeAndroidApplicationId('a' * 247),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('runtimeAndroidVersionCode', () {
    test('把三段版本稳定映射到正整数 versionCode', () {
      expect(runtimeAndroidVersionCode('0.0.0'), 1);
      expect(runtimeAndroidVersionCode('1.2.3'), 1002003);
      expect(runtimeAndroidVersionCode('2099.999.999'), 2099999999);
    });

    test('拒绝非三段、前导零和超出映射范围的版本', () {
      for (final version in [
        '1.2',
        '1.2.3.4',
        '01.2.3',
        '2100.0.0',
        '1.1000.0',
        '1.0.1000',
      ]) {
        expect(
          () => runtimeAndroidVersionCode(version),
          throwsA(isA<FormatException>()),
          reason: version,
        );
      }
    });
  });

  group('FileDeveloperInstallationPackageService', () {
    late Directory root;
    late _FileBackedRuntimePackageManager runtimePackages;
    late _RecordingPackageTransfer packageTransfer;
    late _RecordingNativeExporter nativeExporter;
    late _StaticSigningKeyProvider signingKeyProvider;
    late FileDeveloperInstallationPackageService service;
    late DateTime now;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'developer-installation-package-service-',
      );
      runtimePackages = _FileBackedRuntimePackageManager(
        Directory('${root.path}${Platform.pathSeparator}runtime'),
      );
      await runtimePackages.installAll();
      packageTransfer = _RecordingPackageTransfer();
      nativeExporter = _RecordingNativeExporter();
      final key = File(
        '${root.path}${Platform.pathSeparator}test-export-key.p12',
      );
      await key.writeAsBytes(const [1, 2, 3, 4], flush: true);
      signingKeyProvider = _StaticSigningKeyProvider(key.path);
      now = DateTime.utc(2026, 8, 20, 12);
      service = FileDeveloperInstallationPackageService(
        runtimePackages: runtimePackages,
        nativeExporter: nativeExporter,
        packageTransfer: packageTransfer,
        signingKeyProvider: signingKeyProvider,
        temporaryRoot: root,
        clock: () => now,
      );
    });

    tearDown(() async {
      await service.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('手工放入的三个底包直接复用，并分别走 Android/Windows 导出', () async {
      final game = _game(id: 'com.playmesh.game-3b1p45k3a1', version: '1.2.3');
      final relay = Uri.parse('http://8.137.106.103:16668?token=666666');

      final arm = await service.create(
        game: game,
        targetId: developerInstallationPackageTargetAndroidArm64,
        refreshRuntime: false,
        relayServer: relay,
      );
      final x86 = await service.create(
        game: game,
        targetId: developerInstallationPackageTargetAndroidX86_64,
        refreshRuntime: false,
      );
      final windows = await service.create(
        game: game,
        targetId: developerInstallationPackageTargetWindowsX64,
        refreshRuntime: false,
        relayServer: relay,
      );

      expect(runtimePackages.downloadCount, 0);
      expect(runtimePackages.configReadCount, 0);
      expect(runtimePackages.manifestReadCount, 0);
      expect(packageTransfer.requests, hasLength(3));
      expect(
        packageTransfer.requests.every((request) => request.validate),
        isTrue,
      );

      expect(nativeExporter.androidCalls, hasLength(2));
      expect(nativeExporter.windowsCalls, hasLength(1));
      expect(
        nativeExporter.androidCalls.map(
          (call) => File(call.request.templateApkPath).path,
        ),
        [
          runtimePackages.pathFor(RuntimePackageTarget.androidArm),
          runtimePackages.pathFor(RuntimePackageTarget.androidX86),
        ],
      );
      for (final call in nativeExporter.androidCalls) {
        expect(call.request.gameId, game.id);
        expect(call.request.applicationId, 'com.playmesh.game3b1p45k3a1');
        expect(call.request.label, game.name);
        expect(call.request.versionName, '1.2.3');
        expect(call.request.versionCode, 1002003);
        expect(call.request.keystorePath, signingKeyProvider.path);
        expect(call.iconBytes, packageTransfer.iconBytes);
        _expectClearRuntimeEntries(call.entries);
      }
      expect(signingKeyProvider.loadCount, 2);

      final armEntries = nativeExporter.androidCalls[0].entries;
      _expectSingleRelayConfig(armEntries, relay);
      expect(
        nativeExporter.androidCalls[1].entries,
        isNot(contains('playmesh-runtime.json')),
      );
      final windowsCall = nativeExporter.windowsCalls.single;
      expect(
        windowsCall.request.templateZipPath,
        runtimePackages.pathFor(RuntimePackageTarget.windowsX64),
      );
      expect(windowsCall.request.executableName, 'Runtime Test Game.exe');
      expect(windowsCall.request.label, game.name);
      expect(windowsCall.request.versionName, game.version);
      expect(windowsCall.iconBytes, packageTransfer.iconBytes);
      _expectClearRuntimeEntries(windowsCall.entries);
      _expectSingleRelayConfig(windowsCall.entries, relay);

      for (final artifact in [arm, x86, windows]) {
        expect(service.find(artifact.id), same(artifact));
        expect(await File(artifact.filePath).exists(), isTrue);
        expect(await File(artifact.filePath).length(), artifact.size);
        expect(artifact.projectId, game.id);
      }
      expect(arm.mimeType, 'application/vnd.android.package-archive');
      expect(x86.mimeType, 'application/vnd.android.package-archive');
      expect(windows.mimeType, 'application/zip');
      expect(arm.filename, endsWith('.apk'));
      expect(x86.filename, endsWith('.apk'));
      expect(windows.filename, endsWith('.zip'));
    });

    test('inspectTargets 只按实际 Runtime 清单逐目标报告可下载状态', () async {
      final source = NamedDownloadEndpoint(
        name: 'Runtime releases',
        url: Uri.parse('https://runtime.example.test/update.json'),
      );
      runtimePackages
        ..configSources = RuntimePackageConfigSources([source])
        ..releaseManifests[source.url] = RuntimePackageReleaseManifest.parse(
          jsonEncode({
            'version': 'v1.0.0-build1',
            'platform': {
              'android': {
                'x86': {
                  'sha256': '0' * 64,
                  'downloads': [
                    {'name': '未配置', 'url': ''},
                  ],
                },
                'arm': {
                  'sha256': 'a' * 64,
                  'downloads': [
                    {
                      'name': 'Github',
                      'url': 'https://runtime.example.test/runtime-arm.apk',
                    },
                  ],
                },
              },
              'windows': {
                'sha256': 'b' * 64,
                'downloads': [
                  {
                    'name': 'Github',
                    'url': 'https://runtime.example.test/runtime-win.zip',
                  },
                ],
              },
            },
          }),
        );

      final statuses = await service.inspectTargets();
      final byId = {for (final status in statuses) status.id: status};

      expect(byId.keys, unorderedEquals(developerInstallationPackageTargetIds));
      expect(
        byId[developerInstallationPackageTargetAndroidArm64]!.downloadAvailable,
        isTrue,
      );
      expect(
        byId[developerInstallationPackageTargetAndroidX86_64]!
            .downloadAvailable,
        isFalse,
      );
      expect(
        byId[developerInstallationPackageTargetWindowsX64]!.downloadAvailable,
        isTrue,
      );
      expect(
        byId[developerInstallationPackageTargetAndroidArm64]!.updateAvailable,
        isTrue,
      );
      expect(
        byId[developerInstallationPackageTargetAndroidX86_64]!.updateAvailable,
        isFalse,
      );
      expect(
        byId[developerInstallationPackageTargetWindowsX64]!.updateAvailable,
        isTrue,
      );
      expect(statuses.map((status) => status.runtimeVersion).toSet(), {
        'v1.0.0-build1',
      });
      expect(runtimePackages.configReadCount, 1);
      expect(runtimePackages.manifestReadCount, 1);
    });

    test('App.json 虽已配置，但 Runtime 清单失败时不得误报可下载', () async {
      final source = NamedDownloadEndpoint(
        name: 'Broken runtime releases',
        url: Uri.parse('https://runtime.example.test/broken-update.json'),
      );
      runtimePackages
        ..configSources = RuntimePackageConfigSources([source])
        ..releaseFailures[source.url] = const FormatException('清单损坏');

      final statuses = await service.inspectTargets();

      expect(statuses, hasLength(RuntimePackageTarget.values.length));
      expect(
        statuses.every((status) => status.downloadAvailable == false),
        isTrue,
      );
      expect(statuses.every((status) => status.runtimeVersion == null), isTrue);
      expect(runtimePackages.configReadCount, 1);
      expect(runtimePackages.manifestReadCount, 1);
    });

    test('Runtime 版本变化但 SHA 相同时不提示可更新', () async {
      final source = NamedDownloadEndpoint(
        name: 'Runtime releases',
        url: Uri.parse('https://runtime.example.test/update.json'),
      );
      Future<String> installedSha(RuntimePackageTarget target) => sha256
          .bind(File(runtimePackages.pathFor(target)).openRead())
          .first
          .then((digest) => digest.toString());

      runtimePackages
        ..configSources = RuntimePackageConfigSources([source])
        ..releaseManifests[source.url] = RuntimePackageReleaseManifest.parse(
          jsonEncode({
            'version': 'v999.0.0-build999',
            'platform': {
              'android': {
                'x86': {
                  'sha256': await installedSha(RuntimePackageTarget.androidX86),
                  'downloads': [
                    {
                      'name': 'HTTPS',
                      'url': 'https://runtime.example.test/runtime-x86.apk',
                    },
                  ],
                },
                'arm': {
                  'sha256': await installedSha(RuntimePackageTarget.androidArm),
                  'downloads': [
                    {
                      'name': 'HTTPS',
                      'url': 'https://runtime.example.test/runtime-arm.apk',
                    },
                  ],
                },
              },
              'windows': {
                'sha256': await installedSha(RuntimePackageTarget.windowsX64),
                'downloads': [
                  {
                    'name': 'HTTPS',
                    'url': 'https://runtime.example.test/runtime-win.zip',
                  },
                ],
              },
            },
          }),
        );

      final statuses = await service.inspectTargets();

      expect(
        statuses.every((status) => status.updateAvailable == false),
        isTrue,
      );
      expect(statuses.map((status) => status.runtimeVersion).toSet(), {
        'v999.0.0-build999',
      });
    });

    test('底包下载复用真实字节进度并按百分比或 256KiB 节流', () async {
      final source = NamedDownloadEndpoint(
        name: 'Runtime releases',
        url: Uri.parse('https://runtime.example.test/update.json'),
      );
      runtimePackages
        ..configSources = RuntimePackageConfigSources([source])
        ..releaseManifests[source.url] = _downloadableReleaseManifest()
        ..allowDownload = true
        ..downloadProgress = const [
          RuntimePackageDownloadProgress(
            receivedBytes: 0,
            totalBytes: 50 * 1024 * 1024,
          ),
          RuntimePackageDownloadProgress(
            receivedBytes: 64 * 1024,
            totalBytes: 50 * 1024 * 1024,
          ),
          RuntimePackageDownloadProgress(
            receivedBytes: 128 * 1024,
            totalBytes: 50 * 1024 * 1024,
          ),
          RuntimePackageDownloadProgress(
            receivedBytes: 256 * 1024,
            totalBytes: 50 * 1024 * 1024,
          ),
          RuntimePackageDownloadProgress(
            receivedBytes: 300 * 1024,
            totalBytes: 50 * 1024 * 1024,
          ),
          RuntimePackageDownloadProgress(
            receivedBytes: 50 * 1024 * 1024,
            totalBytes: 50 * 1024 * 1024,
          ),
        ];
      await File(
        runtimePackages.pathFor(RuntimePackageTarget.androidArm),
      ).delete();
      final progress = <DeveloperInstallationPackageProgress>[];

      await service.create(
        game: _game(),
        targetId: developerInstallationPackageTargetAndroidArm64,
        refreshRuntime: false,
        onProgress: progress.add,
      );

      expect(runtimePackages.downloadCount, 1);
      expect(progress.map((item) => item.stage), [
        DeveloperInstallationPackageProgressStage.runtimeCheck,
        DeveloperInstallationPackageProgressStage.runtimeDownload,
        DeveloperInstallationPackageProgressStage.runtimeDownload,
        DeveloperInstallationPackageProgressStage.runtimeDownload,
        DeveloperInstallationPackageProgressStage.runtimeDownload,
        DeveloperInstallationPackageProgressStage.runtimeVerified,
        DeveloperInstallationPackageProgressStage.packageBuild,
        DeveloperInstallationPackageProgressStage.nativeExport,
      ]);
      final downloads = progress
          .where(
            (item) =>
                item.stage ==
                DeveloperInstallationPackageProgressStage.runtimeDownload,
          )
          .toList();
      expect(downloads.map((item) => item.receivedBytes), [
        0,
        0,
        256 * 1024,
        50 * 1024 * 1024,
      ]);
      expect(downloads.first.totalBytes, isNull);
      expect(downloads.first.fraction, isNull);
      expect(downloads[1].totalBytes, 50 * 1024 * 1024);
      expect(downloads.last.fraction, 1);
      expect(downloads.last.percent, 100);
      expect(progress[progress.length - 3].fraction, 1);
    });

    test(
      '未知 Content-Length 保留 receivedBytes 且 fraction/percent 为 null',
      () async {
        final source = NamedDownloadEndpoint(
          name: 'Runtime releases',
          url: Uri.parse('https://runtime.example.test/update.json'),
        );
        runtimePackages
          ..configSources = RuntimePackageConfigSources([source])
          ..releaseManifests[source.url] = _downloadableReleaseManifest()
          ..allowDownload = true
          ..downloadProgress = const [
            RuntimePackageDownloadProgress(receivedBytes: 0, totalBytes: null),
            RuntimePackageDownloadProgress(
              receivedBytes: 64 * 1024,
              totalBytes: null,
            ),
            RuntimePackageDownloadProgress(
              receivedBytes: 300 * 1024,
              totalBytes: null,
            ),
          ];
        await File(
          runtimePackages.pathFor(RuntimePackageTarget.androidX86),
        ).delete();
        final progress = <DeveloperInstallationPackageProgress>[];

        await service.create(
          game: _game(),
          targetId: developerInstallationPackageTargetAndroidX86_64,
          refreshRuntime: false,
          onProgress: progress.add,
        );

        final downloads = progress
            .where(
              (item) =>
                  item.stage ==
                  DeveloperInstallationPackageProgressStage.runtimeDownload,
            )
            .toList();
        expect(downloads.map((item) => item.receivedBytes), [0, 300 * 1024]);
        for (final item in downloads) {
          expect(item.totalBytes, isNull);
          expect(item.fraction, isNull);
          expect(item.percent, isNull);
          expect(item.toJson(), containsPair('fraction', null));
          expect(item.toJson(), containsPair('percent', null));
        }
      },
    );

    test('进度回调抛错不影响安装包导出', () async {
      final artifact = await service.create(
        game: _game(),
        targetId: developerInstallationPackageTargetWindowsX64,
        refreshRuntime: false,
        onProgress: (_) => throw StateError('observer failed'),
      );

      expect(await File(artifact.filePath).exists(), isTrue);
      expect(service.find(artifact.id), same(artifact));
    });

    test('即使未选择 relay，也拒绝游戏来源自行注入 Runtime 私有配置', () async {
      packageTransfer.entries['app/playmesh-runtime.json'] = utf8.encode(
        '{"relayServer":"http://untrusted.invalid"}',
      );

      await expectLater(
        service.create(
          game: _game(),
          targetId: developerInstallationPackageTargetWindowsX64,
          refreshRuntime: false,
        ),
        throwsA(
          isA<DeveloperInstallationPackageException>().having(
            (error) => error.code,
            'code',
            'installation_package_export_failed',
          ),
        ),
      );

      expect(nativeExporter.windowsCalls, isEmpty);
      expect(nativeExporter.androidCalls, isEmpty);
    });

    test('release、过期和 close 都会撤销产物并清理文件', () async {
      final released = await service.create(
        game: _game(name: 'Release Me'),
        targetId: developerInstallationPackageTargetWindowsX64,
        refreshRuntime: false,
      );
      final releasedDirectory = File(released.filePath).parent;

      await service.release(released.id);

      expect(service.find(released.id), isNull);
      expect(await releasedDirectory.exists(), isFalse);

      final expired = await service.create(
        game: _game(name: 'Expire Me'),
        targetId: developerInstallationPackageTargetAndroidArm64,
        refreshRuntime: false,
      );
      final expiredDirectory = File(expired.filePath).parent;
      now = now.add(
        FileDeveloperInstallationPackageService.artifactLifetime +
            const Duration(seconds: 1),
      );

      expect(service.find(expired.id), isNull);
      await _waitUntilMissing(expiredDirectory);

      final closed = await service.create(
        game: _game(name: 'Close Me'),
        targetId: developerInstallationPackageTargetAndroidX86_64,
        refreshRuntime: false,
      );
      final closedDirectory = File(closed.filePath).parent;

      await service.close();

      expect(service.find(closed.id), isNull);
      expect(await closedDirectory.exists(), isFalse);
      expect(runtimePackages.closeCount, 1);
    });

    test('close 等待进行中的原生导出并以同一 Future 完成一次清理', () async {
      final gate = nativeExporter.blockNextWindowsExport();
      final createOperation = service.create(
        game: _game(name: 'Closing Export'),
        targetId: developerInstallationPackageTargetWindowsX64,
        refreshRuntime: false,
      );
      await nativeExporter.windowsExportStarted.future;

      final firstClose = service.close();
      final repeatedClose = service.close();
      expect(identical(firstClose, repeatedClose), isTrue);
      expect(
        () => service.create(
          game: _game(name: 'Too Late'),
          targetId: developerInstallationPackageTargetWindowsX64,
          refreshRuntime: false,
        ),
        throwsStateError,
      );

      var firstCompleted = false;
      var repeatedCompleted = false;
      firstClose.then((_) => firstCompleted = true);
      repeatedClose.then((_) => repeatedCompleted = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(firstCompleted, isFalse);
      expect(repeatedCompleted, isFalse);
      expect(runtimePackages.closeCount, 0);

      gate.complete();
      final artifact = await createOperation;
      final artifactDirectory = File(artifact.filePath).parent;
      await Future.wait([firstClose, repeatedClose]);

      expect(service.find(artifact.id), isNull);
      expect(await artifactDirectory.exists(), isFalse);
      expect(runtimePackages.closeCount, 1);
      await service.close();
      expect(runtimePackages.closeCount, 1);
    });
  });
}

void _expectClearRuntimeEntries(Map<String, List<int>> entries) {
  expect(
    entries.keys,
    containsAll(<String>[
      'main.json',
      'capabilities.json',
      'index.html',
      'scripts/game.js',
    ]),
  );
  expect(entries.keys.any((path) => path.startsWith('app/')), isFalse);
  expect(entries, isNot(contains('icon.png')));
  expect(
    utf8.decode(entries['index.html']!),
    '<!doctype html><title>Game</title>',
  );
  expect(utf8.decode(entries['scripts/game.js']!), 'window.gameReady = true;');
}

void _expectSingleRelayConfig(Map<String, List<int>> entries, Uri expected) {
  expect(
    entries.keys.where((path) => path == 'playmesh-runtime.json'),
    hasLength(1),
  );
  final config = Map<String, Object?>.from(
    jsonDecode(utf8.decode(entries['playmesh-runtime.json']!)) as Map,
  );
  expect(config, {'schemaVersion': 1, 'relayServer': expected.toString()});
}

Future<void> _waitUntilMissing(Directory directory) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (!await directory.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('目录未在预期时间内清理: ${directory.path}');
}

RuntimePackageReleaseManifest _downloadableReleaseManifest() =>
    RuntimePackageReleaseManifest.parse(
      jsonEncode({
        'version': 'v1.0.0-build1',
        'platform': {
          'android': {
            'x86': {
              'sha256': 'a' * 64,
              'downloads': [
                {
                  'name': 'Github',
                  'url': 'https://runtime.example.test/runtime-x86.apk',
                },
              ],
            },
            'arm': {
              'sha256': 'b' * 64,
              'downloads': [
                {
                  'name': 'Github',
                  'url': 'https://runtime.example.test/runtime-arm.apk',
                },
              ],
            },
          },
          'windows': {
            'sha256': 'c' * 64,
            'downloads': [
              {
                'name': 'Github',
                'url': 'https://runtime.example.test/runtime-win.zip',
              },
            ],
          },
        },
      }),
    );

GameSummary _game({
  String id = 'com.playmesh.game-test',
  String name = 'Runtime Test Game',
  String version = '1.2.3',
}) => GameSummary(
  id: id,
  name: name,
  version: version,
  description: 'Runtime export test',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: const LocalGameEntry(
    statusLabel: '测试',
    gameEntryPath: 'index.html',
    packageRootFilePath: 'unused-by-recording-transfer',
  ),
);

final class _PackageTransferRequest {
  const _PackageTransferRequest({
    required this.game,
    required this.destination,
    required this.validate,
  });

  final GameSummary game;
  final String destination;
  final bool validate;
}

final class _RecordingPackageTransfer extends GamePackageTransferService {
  _RecordingPackageTransfer()
    : entries = <String, List<int>>{
        'main.json': utf8.encode('{"id":"fixture"}'),
        'capabilities.json': utf8.encode('{"vibration":{"optional":true}}'),
        'app/index.html': utf8.encode('<!doctype html><title>Game</title>'),
        'app/scripts/game.js': utf8.encode('window.gameReady = true;'),
        'icon.png': _fixtureIconBytes,
      };

  final Map<String, List<int>> entries;
  final requests = <_PackageTransferRequest>[];

  List<int> get iconBytes => _fixtureIconBytes;

  @override
  Future<File> exportPackage(
    GameSummary game,
    File destination, {
    bool validate = true,
  }) async {
    requests.add(
      _PackageTransferRequest(
        game: game,
        destination: destination.path,
        validate: validate,
      ),
    );
    await destination.parent.create(recursive: true);
    final encoder = ZipFileEncoder();
    encoder.create(destination.path);
    try {
      for (final entry in entries.entries) {
        encoder.addArchiveFile(
          ArchiveFile(entry.key, entry.value.length, entry.value),
        );
      }
      await encoder.close();
    } on Object {
      await encoder.close();
      rethrow;
    }
    return destination;
  }
}

const _fixtureIconBytes = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  1,
  2,
  3,
  4,
];

final class _AndroidExportCall {
  const _AndroidExportCall({
    required this.request,
    required this.entries,
    required this.iconBytes,
  });

  final RuntimeAndroidNativeExportRequest request;
  final Map<String, List<int>> entries;
  final List<int>? iconBytes;
}

final class _WindowsExportCall {
  const _WindowsExportCall({
    required this.request,
    required this.entries,
    required this.iconBytes,
  });

  final RuntimeWindowsNativeExportRequest request;
  final Map<String, List<int>> entries;
  final List<int>? iconBytes;
}

final class _RecordingNativeExporter implements RuntimeNativeExporter {
  final androidCalls = <_AndroidExportCall>[];
  final windowsCalls = <_WindowsExportCall>[];
  final windowsExportStarted = Completer<void>();
  Completer<void>? _windowsExportGate;
  var _sequence = 0;

  Completer<void> blockNextWindowsExport() =>
      _windowsExportGate = Completer<void>();

  @override
  Future<RuntimeNativeExportReport> exportAndroid(
    RuntimeAndroidNativeExportRequest request,
  ) async {
    final entries = await _readArchive(request.clearGamePackagePath);
    final icon = request.iconPath == null
        ? null
        : await File(request.iconPath!).readAsBytes();
    androidCalls.add(
      _AndroidExportCall(request: request, entries: entries, iconBytes: icon),
    );
    return _writeOutput(request.outputApkPath, marker: 0xa0);
  }

  @override
  Future<RuntimeNativeExportReport> exportWindows(
    RuntimeWindowsNativeExportRequest request,
  ) async {
    if (!windowsExportStarted.isCompleted) windowsExportStarted.complete();
    final gate = _windowsExportGate;
    _windowsExportGate = null;
    if (gate != null) await gate.future;
    final icon = request.iconPath == null
        ? null
        : await File(request.iconPath!).readAsBytes();
    windowsCalls.add(
      _WindowsExportCall(
        request: request,
        entries: await _readArchive(request.clearGamePackagePath),
        iconBytes: icon,
      ),
    );
    return _writeOutput(request.outputZipPath, marker: 0xb0);
  }

  Future<RuntimeNativeExportReport> _writeOutput(
    String path, {
    required int marker,
  }) async {
    _sequence += 1;
    final bytes = List<int>.filled(128 + _sequence, marker + _sequence);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return RuntimeNativeExportReport(outputPath: path, sizeBytes: bytes.length);
  }
}

Future<Map<String, List<int>>> _readArchive(String path) async {
  final archive = ZipDecoder().decodeBytes(
    await File(path).readAsBytes(),
    verify: true,
  );
  return <String, List<int>>{
    for (final entry in archive)
      if (entry.isFile) entry.name: _contentBytes(entry.content),
  };
}

List<int> _contentBytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return value;
  return List<int>.from(value as Iterable);
}

final class _StaticSigningKeyProvider
    implements DeveloperAndroidExportSigningKeyProvider {
  _StaticSigningKeyProvider(this.path);

  final String path;
  var loadCount = 0;

  @override
  Future<DeveloperAndroidExportSigningKey> load() async {
    loadCount += 1;
    return DeveloperAndroidExportSigningKey(
      path: path,
      storePassword: 'store-password',
      keyPassword: 'key-password',
      alias: 'test-key',
    );
  }
}

final class _FileBackedRuntimePackageManager implements RuntimePackageManager {
  _FileBackedRuntimePackageManager(this.root);

  final Directory root;
  var configReadCount = 0;
  var manifestReadCount = 0;
  var downloadCount = 0;
  var closeCount = 0;
  RuntimePackageConfigSources configSources = const RuntimePackageConfigSources(
    [],
  );
  final releaseManifests = <Uri, RuntimePackageReleaseManifest>{};
  final releaseFailures = <Uri, Object>{};
  var allowDownload = false;
  List<RuntimePackageDownloadProgress> downloadProgress = const [];

  String pathFor(RuntimePackageTarget target) =>
      '${root.path}${Platform.pathSeparator}${target.fileName}';

  Future<void> installAll() async {
    await root.create(recursive: true);
    for (final target in RuntimePackageTarget.values) {
      await File(pathFor(target)).writeAsBytes(
        utf8.encode('manually-installed-${target.id}'),
        flush: true,
      );
    }
  }

  @override
  Future<RuntimePackageStatus> inspectPackage(
    RuntimePackageTarget target,
  ) async {
    final file = File(pathFor(target));
    final installed = await file.exists();
    return RuntimePackageStatus(
      target: target,
      filePath: file.path,
      installed: installed,
      sizeBytes: installed ? await file.length() : null,
    );
  }

  @override
  Future<List<RuntimePackageStatus>> inspectPackages() =>
      Future.wait(RuntimePackageTarget.values.map(inspectPackage));

  @override
  Future<RuntimePackageConfigSources> loadConfigSources() async {
    configReadCount += 1;
    return configSources;
  }

  @override
  Future<RuntimePackageReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) async {
    manifestReadCount += 1;
    final failure = releaseFailures[selectedSource.url];
    if (failure != null) throw failure;
    final manifest = releaseManifests[selectedSource.url];
    if (manifest == null) {
      throw UnsupportedError('本测试未配置 Runtime 远端清单');
    }
    return manifest;
  }

  @override
  Future<RuntimePackageInstallResult> downloadPackage({
    required RuntimePackageTarget target,
    required RuntimePackageReleaseManifest release,
    required RuntimePackageDownloadEndpoint selectedDownload,
    bool forceRedownload = false,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  }) async {
    downloadCount += 1;
    if (!allowDownload) {
      throw UnsupportedError('本测试不应下载 Runtime 底包');
    }
    for (final progress in downloadProgress) {
      onProgress?.call(progress);
    }
    final file = File(pathFor(target));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(
      utf8.encode('downloaded-and-sha256-verified-${target.id}'),
      flush: true,
    );
    return RuntimePackageInstallResult(
      status: await inspectPackage(target),
      version: release.version,
      downloaded: true,
      reused: false,
      sha256: selectedDownload.sha256,
    );
  }

  @override
  void close() {
    closeCount += 1;
  }
}
