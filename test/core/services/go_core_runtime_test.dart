import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/developer/developer_preferences.dart';
import 'package:playmesh/core/developer/developer_background_host.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_distribution.dart';
import 'package:playmesh/core/developer/gdevelop_ai_tool_registry.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_manager_contract.dart';
import 'package:playmesh/core/developer/gdevelop_local_package_source.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_source_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';
import 'package:playmesh/core/lifecycle/go_core_host.dart';
import 'package:playmesh/core/network/go_core_client.dart';
import 'package:playmesh/core/protocol/go_core_status.dart';
import 'package:playmesh/core/services/go_core_runtime.dart';

import '../../support/gdevelop_ai_tool_contract_test_support.dart';

void main() {
  test('starts the bundled host before checking and stops on close', () async {
    final host = _StubHost();
    final client = _RuntimeClient();
    final runtime = GoCoreRuntime(host: host, client: client);

    final result = await runtime.check();

    expect(host.startCalls, 1);
    expect(client.fetchCalls, 1);
    expect(result.availability, GoCoreAvailability.online);

    await runtime.close();
    expect(host.stopCalls, 1);
    expect(client.closed, isTrue);
  });

  test('close does not wait for an in-flight host start', () async {
    final startCompleter = Completer<void>();
    final host = _StubHost(startCompleter: startCompleter);
    var clientFactoryCalls = 0;
    final runtime = GoCoreRuntime(
      host: host,
      clientFactory: (endpoint) {
        clientFactoryCalls += 1;
        return _RuntimeClient(endpoint: endpoint);
      },
    );

    final startOperation = runtime.start();
    expect(host.startCalls, 1);

    await runtime.close();

    expect(host.stopCalls, 1);
    expect(clientFactoryCalls, 0);

    startCompleter.complete();
    await startOperation;

    expect(host.stopCalls, 2);
    expect(clientFactoryCalls, 0);

    await runtime.close();
    expect(host.stopCalls, 2);
  });

  test('maps a bundled host startup failure to error', () async {
    final host = _StubHost(
      startError: const GoCoreHostException(
        code: 'bundled_core_missing',
        userMessage: '应用缺少内置 Go Core，请重新安装。',
        diagnostic: 'missing executable',
      ),
    );
    final client = _RuntimeClient();
    final runtime = GoCoreRuntime(host: host, client: client);

    final result = await runtime.check();

    expect(result.availability, GoCoreAvailability.error);
    expect(result.message, contains('缺少内置 Go Core'));
    expect(client.fetchCalls, 0);
  });

  test(
    'creates the health client from the address reported by the host',
    () async {
      final host = _StubHost(
        initialEndpoint: Uri.parse('http://127.0.0.1:0/health'),
        boundEndpoint: Uri.parse('http://127.0.0.1:43210/health'),
      );
      Uri? clientEndpoint;
      final runtime = GoCoreRuntime(
        host: host,
        clientFactory: (endpoint) {
          clientEndpoint = endpoint;
          return _RuntimeClient(endpoint: endpoint);
        },
      );

      expect(runtime.endpoint.port, 0);

      final result = await runtime.check();

      expect(result.availability, GoCoreAvailability.online);
      expect(clientEndpoint, Uri.parse('http://127.0.0.1:43210/health'));
      expect(runtime.endpoint.port, 43210);
    },
  );

  test(
    'same session asks the existing Gateway source for fresh WebIDE links',
    () async {
      final library = await Directory.systemTemp.createTemp('runtime-webide-');
      addTearDown(() async {
        if (await library.exists()) await library.delete(recursive: true);
      });
      final source = _MutableGDevelopSource();
      final manager = _RuntimeGDevelopManager();
      final runtime = GoCoreRuntime(
        host: _StubHost(),
        client: _RuntimeClient(),
        developerPreferences: DeveloperPreferences(libraryRoot: library),
        developerGDevelopWebIdeSource: source,
        developerGDevelopWebIdeManager: manager,
      );
      addTearDown(runtime.close);
      final port = await _freePort();
      final session = await runtime.enableDeveloperMode(
        port: port,
        token: 'runtime-test-token',
      );

      expect(await runtime.gdevelopWorkspaceLinks(session), isEmpty);
      final callsBeforeInstall = source.availabilityCalls;
      source.available = true;

      final links = await runtime.gdevelopWorkspaceLinks(session);

      expect(source.availabilityCalls, callsBeforeInstall + 1);
      expect(links, isNotEmpty);
      expect(links.every((link) => link.uri.port == port), isTrue);
      expect(
        links.every((link) => link.uri.path == session.gdevelopWorkspacePath),
        isTrue,
      );
      expect(
        links.every(
          (link) => link.uri.queryParameters['token'] == session.token,
        ),
        isTrue,
      );
    },
  );

  test(
    'blocks remote and local WebIDE installation while Developer Mode is on',
    () async {
      final library = await Directory.systemTemp.createTemp(
        'runtime-webide-guard-',
      );
      addTearDown(() async {
        if (await library.exists()) await library.delete(recursive: true);
      });
      final manager = _RuntimeGDevelopManager();
      final runtime = GoCoreRuntime(
        host: _StubHost(),
        client: _RuntimeClient(),
        developerPreferences: DeveloperPreferences(libraryRoot: library),
        developerGDevelopWebIdeSource: _MutableGDevelopSource(),
        developerGDevelopWebIdeManager: manager,
      );
      addTearDown(runtime.close);
      await runtime.enableDeveloperMode(
        port: await _freePort(),
        token: 'runtime-guard-token',
      );
      final (release, download) = _testRelease();

      await expectLater(
        runtime.applyGDevelopWebIdeRelease(
          release: release,
          selectedDownload: download,
          forceRedownload: false,
        ),
        throwsA(_developerModeInstallGuard()),
      );
      await expectLater(
        runtime.applyLocalGDevelopWebIdePackage(
          source: _testLocalPackage(),
          allowMemoryFallback: false,
        ),
        throwsA(_developerModeInstallGuard()),
      );

      expect(manager.releaseInstallCalls, 0);
      expect(manager.localInstallCalls, 0);
    },
  );

  test(
    'keeps installation blocked until Developer Mode shutdown completes',
    () async {
      final library = await Directory.systemTemp.createTemp(
        'runtime-webide-shutdown-',
      );
      addTearDown(() async {
        if (await library.exists()) await library.delete(recursive: true);
      });
      final backgroundHost = _ControllableDeveloperBackgroundHost();
      final manager = _RuntimeGDevelopManager();
      final runtime = GoCoreRuntime(
        host: _StubHost(),
        client: _RuntimeClient(),
        developerPreferences: DeveloperPreferences(libraryRoot: library),
        developerBackgroundHost: backgroundHost,
        developerGDevelopWebIdeSource: _MutableGDevelopSource(),
        developerGDevelopWebIdeManager: manager,
      );
      addTearDown(runtime.close);
      await runtime.enableDeveloperMode(
        port: await _freePort(),
        token: 'runtime-shutdown-token',
      );
      final stopStarted = backgroundHost.blockNextStop();
      final disabling = runtime.disableDeveloperMode();
      await stopStarted;
      final (release, download) = _testRelease();

      await expectLater(
        runtime.applyGDevelopWebIdeRelease(
          release: release,
          selectedDownload: download,
          forceRedownload: false,
        ),
        throwsA(_developerModeInstallGuard()),
      );
      expect(manager.releaseInstallCalls, 0);

      backgroundHost.completeBlockedStop();
      await disabling;
      await runtime.applyGDevelopWebIdeRelease(
        release: release,
        selectedDownload: download,
        forceRedownload: false,
      );
      await runtime.applyLocalGDevelopWebIdePackage(
        source: _testLocalPackage(),
        allowMemoryFallback: false,
      );

      expect(manager.releaseInstallCalls, 1);
      expect(manager.localInstallCalls, 1);
    },
  );

  test(
    'a concurrent shutdown cannot unlock installation while startup remains pending',
    () async {
      final library = await Directory.systemTemp.createTemp(
        'runtime-webide-startup-race-',
      );
      addTearDown(() async {
        if (await library.exists()) await library.delete(recursive: true);
      });
      final source = _BlockingGDevelopSource();
      final manager = _RuntimeGDevelopManager();
      final runtime = GoCoreRuntime(
        host: _StubHost(),
        client: _RuntimeClient(),
        developerPreferences: DeveloperPreferences(libraryRoot: library),
        developerGDevelopWebIdeSource: source,
        developerGDevelopWebIdeManager: manager,
      );
      addTearDown(runtime.close);
      final enabling = runtime.enableDeveloperMode(
        port: await _freePort(),
        token: 'runtime-startup-race-token',
      );
      await source.availabilityRequested;

      await runtime.disableDeveloperMode();
      await expectLater(
        runtime.applyLocalGDevelopWebIdePackage(
          source: _testLocalPackage(),
          allowMemoryFallback: false,
        ),
        throwsA(_developerModeInstallGuard()),
      );
      expect(manager.localInstallCalls, 0);

      source.completeAvailability(available: false);
      await enabling;
      await runtime.disableDeveloperMode();
    },
  );
}

Matcher _developerModeInstallGuard() =>
    isA<GDevelopWebIdeInstallException>().having(
      (error) => error.diagnostic,
      'diagnostic',
      'gdevelop_developer_mode_must_be_disabled_before_install',
    );

(GDevelopWebIdeReleaseManifest, NamedDownloadEndpoint) _testRelease() {
  final download = NamedDownloadEndpoint(
    name: 'test ZIP',
    url: Uri.parse('https://example.test/gdevelop.zip'),
  );
  return (
    GDevelopWebIdeReleaseManifest(
      version: '5.6.276',
      sha256: List.filled(64, 'a').join(),
      size: 3,
      downloads: [download],
    ),
    download,
  );
}

GDevelopLocalPackageSource _testLocalPackage() => GDevelopLocalPackageSource(
  displayName: 'gdevelop.zip',
  openRead: () => Stream.value(const [1, 2, 3]),
  readAsBytes: () async => Uint8List.fromList(const [1, 2, 3]),
);

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

class _StubHost implements GoCoreHost {
  _StubHost({
    this.startError,
    Uri? initialEndpoint,
    this.boundEndpoint,
    this.startCompleter,
  }) : _endpoint =
           initialEndpoint ?? Uri.parse('http://127.0.0.1:43210/health');

  final GoCoreHostException? startError;
  final Uri? boundEndpoint;
  final Completer<void>? startCompleter;
  Uri _endpoint;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Uri get endpoint => _endpoint;

  @override
  Future<void> start() async {
    startCalls += 1;
    await startCompleter?.future;
    if (startError case final error?) {
      throw error;
    }
    if (boundEndpoint case final endpoint?) {
      _endpoint = endpoint;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }
}

class _RuntimeClient implements GoCoreHealthClient {
  _RuntimeClient({Uri? endpoint})
    : _endpoint = endpoint ?? Uri.parse('http://127.0.0.1:43210/health');

  final Uri _endpoint;
  int fetchCalls = 0;
  bool closed = false;

  @override
  Uri get endpoint => _endpoint;

  @override
  Future<GoCoreStatus> fetchHealth({String? requestId}) async {
    fetchCalls += 1;
    return GoCoreStatus(
      requestId: 'req-runtime',
      status: 'online',
      coreVersion: '0.1.0',
      timestamp: DateTime.utc(2026, 7, 15, 8, 30),
      startedAt: DateTime.utc(2026, 7, 15, 8),
    );
  }

  @override
  void close() {
    closed = true;
  }
}

class _MutableGDevelopSource implements GDevelopWebIdeSource {
  var available = false;
  var availabilityCalls = 0;

  @override
  Future<bool> isAvailable() async {
    availabilityCalls += 1;
    return available;
  }

  @override
  Future<Uint8List?> read(String relativePath) async =>
      available ? Uint8List.fromList(const [1]) : null;
}

class _BlockingGDevelopSource implements GDevelopWebIdeSource {
  final Completer<void> _availabilityRequested = Completer<void>();
  final Completer<bool> _availability = Completer<bool>();

  Future<void> get availabilityRequested => _availabilityRequested.future;

  void completeAvailability({required bool available}) {
    _availability.complete(available);
  }

  @override
  Future<bool> isAvailable() {
    if (!_availabilityRequested.isCompleted) {
      _availabilityRequested.complete();
    }
    return _availability.future;
  }

  @override
  Future<Uint8List?> read(String relativePath) async => null;
}

class _RuntimeGDevelopManager implements GDevelopWebIdeManager {
  var releaseInstallCalls = 0;
  var localInstallCalls = 0;

  @override
  Future<GDevelopAiToolRegistry> loadInstalledAiToolRegistry() async =>
      loadGDevelopAiToolRegistryForTest();
  @override
  Future<GDevelopWebIdeInstallResult> applyLocalPackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) async {
    localInstallCalls += 1;
    return GDevelopWebIdeInstallResult(marker: _testInstalledMarker());
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    releaseInstallCalls += 1;
    return GDevelopWebIdeInstallResult(marker: _testInstalledMarker());
  }

  @override
  void close() {}

  @override
  Future<GDevelopWebIdeInstallationInspection> inspectInstallation() async =>
      const GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.absent,
      );

  @override
  Future<GDevelopWebIdeInstalledNotices> loadInstalledNotices() =>
      throw UnimplementedError();

  @override
  Future<GDevelopWebIdeConfigSources> loadConfigSources() async =>
      const GDevelopWebIdeConfigSources([]);

  @override
  Future<GDevelopWebIdeReleaseManifest> loadReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) => throw UnimplementedError();
}

GDevelopWebIdeInstalledMarker _testInstalledMarker() =>
    GDevelopWebIdeInstalledMarker(
      version: '5.6.276',
      sha256: List.filled(64, 'a').join(),
      noticesSha256: List.filled(64, 'b').join(),
      aiToolsPath: 'playmesh-ai-tools.json',
      aiToolsSha256: List.filled(64, 'c').join(),
      aiToolsContractHash: List.filled(64, 'd').join(),
      size: 3,
      installedAt: DateTime.utc(2026, 8, 13),
      installationKind: GDevelopWebIdeInstallationKind.release,
    );

class _ControllableDeveloperBackgroundHost implements DeveloperBackgroundHost {
  Completer<void>? _blockedStop;
  Completer<void>? _blockedStopStarted;

  Future<void> blockNextStop() {
    _blockedStop = Completer<void>();
    _blockedStopStarted = Completer<void>();
    return _blockedStopStarted!.future;
  }

  void completeBlockedStop() {
    _blockedStop?.complete();
    _blockedStop = null;
  }

  @override
  Future<void> start({
    required int port,
    DeveloperBackgroundNotificationLocalization? localization,
  }) async {}

  @override
  Future<void> stop() async {
    final blockedStop = _blockedStop;
    if (blockedStop == null) return;
    _blockedStopStarted?.complete();
    _blockedStopStarted = null;
    await blockedStop.future;
  }

  @override
  Future<void> updateNotification({
    required int port,
    required DeveloperBackgroundNotificationLocalization localization,
  }) async {}

  @override
  Future<DeveloperViewAvailability> viewAvailability() async =>
      const DeveloperViewAvailability.available();
}
