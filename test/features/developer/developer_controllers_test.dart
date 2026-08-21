import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_channel.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_distribution.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_local_package_source.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';
import 'package:playmesh/features/developer/developer_mode_controller.dart';
import 'package:playmesh/features/developer/source_development_controller.dart';
import 'package:playmesh/features/developer/visual_gdevelop_controller.dart';
import 'package:playmesh/core/network/lan_endpoint.dart';

void main() {
  test('共享会话控制器不读取任一编辑器链接', () async {
    final provider = _ControllerProvider();
    final controller = DeveloperSessionController(provider);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.enable(portText: '16666', token: 'controller-token');

    expect(controller.state.enabled, isTrue);
    expect(provider.sourceCalls, 0);
    expect(provider.visualCalls, 0);
  });

  test('源代码和 GDevelop 控制器独立加载与失败', () async {
    final provider = _ControllerProvider(
      sourceError: StateError('source down'),
    );
    final session = provider.session;
    final source = SourceDevelopmentController(provider);
    final visual = VisualGDevelopController(provider);
    addTearDown(source.dispose);
    addTearDown(visual.dispose);

    await Future.wait([
      source.synchronize(session),
      visual.synchronize(session),
    ]);

    expect(source.state.error, isA<StateError>());
    expect(source.state.links, isEmpty);
    expect(visual.state.statusError, isNull);
    expect(visual.state.links.single.uri.path, session.gdevelopWorkspacePath);
    expect(provider.sourceCalls, 1);
    expect(provider.visualCalls, 1);
  });

  test('两个入口派生本机地址时保留端口、路径与 token', () {
    final provider = _ControllerProvider();
    final source = SourceDevelopmentController(provider);
    final visual = VisualGDevelopController(provider);
    addTearDown(source.dispose);
    addTearDown(visual.dispose);
    final sourceLan = Uri.parse(
      'http://192.168.1.10:16666/dev/path/workspace?token=source-token',
    );
    final visualLan = Uri.parse(
      'http://192.168.1.11:17777/dev/path/gdevelop/?token=visual-token',
    );

    expect(
      source.inAppWorkspaceUri(sourceLan).toString(),
      'http://127.0.0.1:16666/dev/path/workspace?token=source-token',
    );
    expect(
      visual.inAppWorkspaceUri(visualLan).toString(),
      'http://127.0.0.1:17777/dev/path/gdevelop/?token=visual-token',
    );
  });

  test('同一开发者会话安装完成后立即重新解析可视化链接', () async {
    final provider = _DistributionControllerProvider(initialInstalled: false);
    final probeService = EndpointProbeService(
      httpClient: _ReachableProbeHttpClient(),
    );
    addTearDown(probeService.close);
    final controller = VisualGDevelopController(
      provider,
      probeService: probeService,
    );
    addTearDown(controller.dispose);

    await controller.synchronize(provider.session);
    expect(controller.state.links, isEmpty);
    await _selectDistribution(controller, provider);
    expect(controller.state.primaryOperation, VisualGDevelopOperation.install);

    await controller.startPrimaryOperation();

    expect(
      controller.state.installation?.state,
      GDevelopWebIdeInstallationState.ready,
    );
    expect(controller.state.links, hasLength(1));
    expect(
      controller.state.links.single.uri.path,
      provider.session.gdevelopWorkspacePath,
    );
    expect(provider.workspaceLinkCalls, 2);
    expect(provider.applyForceRedownload, [false]);
  });

  test('同版本修复强制重新下载并刷新 marker', () async {
    final provider = _DistributionControllerProvider(initialInstalled: true);
    final probeService = EndpointProbeService(
      httpClient: _ReachableProbeHttpClient(),
    );
    addTearDown(probeService.close);
    final controller = VisualGDevelopController(
      provider,
      probeService: probeService,
    );
    addTearDown(controller.dispose);

    await controller.synchronize(provider.session);
    final before = controller.state.installation!.marker!.installedAt;
    await _selectDistribution(controller, provider);
    expect(controller.state.releaseMatchesInstallation, isTrue);
    expect(controller.canRepair, isTrue);

    await controller.repair();

    expect(provider.applyForceRedownload, [true]);
    expect(
      controller.state.installation!.marker!.installedAt.isAfter(before),
      isTrue,
    );
    expect(controller.state.completedOperation, VisualGDevelopOperation.repair);
  });

  test('same core version with different SHA is an update', () {
    final installedSha = List.filled(64, 'a').join();
    final releaseSha = List.filled(64, 'b').join();
    final state = VisualGDevelopState(
      installation: GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.ready,
        marker: GDevelopWebIdeInstalledMarker(
          version: '5.6.269',
          sha256: installedSha,
          noticesSha256: List.filled(64, 'd').join(),
          aiToolsPath: 'playmesh/ai/tools.json',
          aiToolsSha256: List.filled(64, 'e').join(),
          aiToolsContractHash: List.filled(64, 'f').join(),
          size: 4096,
          installedAt: DateTime.utc(2026, 8, 8),
          installationKind: GDevelopWebIdeInstallationKind.release,
        ),
      ),
      release: GDevelopWebIdeReleaseManifest(
        version: '5.6.269',
        sha256: releaseSha,
        size: 4096,
        downloads: const [],
      ),
    );

    expect(state.releaseMatchesInstallation, isFalse);
    expect(state.primaryOperation, VisualGDevelopOperation.upgrade);
  });

  test('different display version with the same SHA is already current', () {
    final sha256 = List.filled(64, 'c').join();
    final state = VisualGDevelopState(
      installation: GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.ready,
        marker: GDevelopWebIdeInstalledMarker(
          version: '5.6.268',
          sha256: sha256,
          noticesSha256: List.filled(64, 'd').join(),
          aiToolsPath: 'playmesh/ai/tools.json',
          aiToolsSha256: List.filled(64, 'e').join(),
          aiToolsContractHash: List.filled(64, 'f').join(),
          size: 2048,
          installedAt: DateTime.utc(2026, 8, 8),
          installationKind: GDevelopWebIdeInstallationKind.release,
        ),
      ),
      release: GDevelopWebIdeReleaseManifest(
        version: '5.6.269',
        sha256: sha256,
        size: 4096,
        downloads: const [],
      ),
    );

    expect(state.releaseMatchesInstallation, isTrue);
    expect(state.primaryOperation, isNull);
  });

  test('修复失败继续暴露旧版本及同一会话链接', () async {
    final failure = const VerifiedDownloadException(
      kind: VerifiedDownloadFailureKind.sha256Mismatch,
      diagnostic: 'download_sha256_mismatch',
    );
    final provider = _DistributionControllerProvider(
      initialInstalled: true,
      applyError: failure,
    );
    final probeService = EndpointProbeService(
      httpClient: _ReachableProbeHttpClient(),
    );
    addTearDown(probeService.close);
    final controller = VisualGDevelopController(
      provider,
      probeService: probeService,
    );
    addTearDown(controller.dispose);

    await controller.synchronize(provider.session);
    final oldMarker = controller.state.installation!.marker;
    await _selectDistribution(controller, provider);
    await controller.repair();

    expect(controller.state.operationError, same(failure));
    expect(
      controller.state.installation?.marker?.installedAt,
      oldMarker?.installedAt,
    );
    expect(controller.state.links, hasLength(1));
    expect(provider.applyForceRedownload, [true]);
  });

  test('本地 ZIP 安装复用可视化控制器并立即刷新当前会话', () async {
    final provider = _DistributionControllerProvider(initialInstalled: false);
    final controller = VisualGDevelopController(provider);
    addTearDown(controller.dispose);
    await controller.synchronize(provider.session);

    await controller.installLocalPackage(
      source: GDevelopLocalPackageSource(
        displayName: 'content://picker/GDevelop.zip',
        openRead: () => Stream.value(const [1, 2, 3]),
        readAsBytes: () async => Uint8List.fromList(const [1, 2, 3]),
      ),
      allowMemoryFallback: false,
    );

    expect(provider.localMemoryFallback, [false]);
    expect(
      controller.state.installation?.state,
      GDevelopWebIdeInstallationState.ready,
    );
    expect(controller.state.links, hasLength(1));
    expect(
      controller.state.completedOperation,
      VisualGDevelopOperation.install,
    );
  });

  test('可视化 gateway 启动失败保留安装状态并可重试', () async {
    final failure = StateError('visual gateway failed');
    final provider = _DistributionControllerProvider(
      initialInstalled: true,
      workspaceLinkError: failure,
    );
    final controller = VisualGDevelopController(provider);
    addTearDown(controller.dispose);

    await controller.synchronize(provider.session);
    expect(
      controller.state.installation?.state,
      GDevelopWebIdeInstallationState.ready,
    );
    expect(controller.state.links, isEmpty);
    expect(controller.state.startError, same(failure));

    provider.workspaceLinkError = null;
    await controller.ensureStarted();
    expect(controller.state.startError, isNull);
    expect(controller.state.links, hasLength(1));
    expect(provider.workspaceLinkCalls, 2);
  });
}

Future<void> _selectDistribution(
  VisualGDevelopController controller,
  _DistributionControllerProvider provider,
) async {
  final configPicker = controller.configSourcePicker!;
  await configPicker.probeAll();
  expect(configPicker.select(provider.configSource), isTrue);
  await controller.selectConfigSource(provider.configSource);
  final downloadPicker = controller.downloadSourcePicker!;
  await downloadPicker.probeAll();
  expect(downloadPicker.select(provider.downloadSource), isTrue);
}

class _ControllerProvider
    implements DeveloperModeProvider, DeveloperWorkspacePreferenceProvider {
  _ControllerProvider({this.sourceError});

  final Object? sourceError;
  int sourceCalls = 0;
  int visualCalls = 0;

  final session = const DeveloperSession(
    enabled: true,
    port: 16666,
    path: 'session-path',
    token: 'controller-token',
    tokenHint: 'r-token',
    workspacePath: '/dev/session-path/workspace',
    gdevelopWorkspacePath: '/dev/session-path/gdevelop/',
  );

  @override
  Future<DeveloperSession> developerModeStatus() async =>
      const DeveloperSession(enabled: false);

  @override
  Future<void> disableDeveloperMode() async {}

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) async => session;

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  ) async {
    visualCalls += 1;
    return [
      _lan(
        Uri.parse(
          'http://192.168.1.10:${session.port}${session.gdevelopWorkspacePath}',
        ),
      ),
    ];
  }

  @override
  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation() async =>
      GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.ready,
        marker: GDevelopWebIdeInstalledMarker(
          version: '5.6.269',
          sha256: List.filled(64, 'a').join(),
          noticesSha256: List.filled(64, 'd').join(),
          aiToolsPath: 'playmesh/ai/tools.json',
          aiToolsSha256: List.filled(64, 'e').join(),
          aiToolsContractHash: List.filled(64, 'f').join(),
          size: 123,
          installedAt: DateTime.utc(2026, 8, 5),
          installationKind: GDevelopWebIdeInstallationKind.release,
        ),
      );

  @override
  Future<GDevelopWebIdeInstalledNotices>
  loadInstalledGDevelopWebIdeNotices() async => GDevelopWebIdeInstalledNotices(
    version: '5.6.269',
    archiveSha256: List.filled(64, 'a').join(),
    noticesSha256: List.filled(64, 'b').join(),
    contents: 'installed notices',
  );

  @override
  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources() async =>
      const GDevelopWebIdeConfigSources([]);

  @override
  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) => throw UnimplementedError();

  @override
  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) => throw UnimplementedError();

  @override
  Future<DeveloperWorkspacePreference>
  loadDeveloperWorkspacePreference() async =>
      const DeveloperWorkspacePreference(
        port: 16666,
        token: 'controller-token',
        path: 'session-path',
      );

  @override
  Future<List<LanEndpointCandidate>> sourceWorkspaceLinks(
    DeveloperSession session,
  ) async {
    sourceCalls += 1;
    if (sourceError case final error?) throw error;
    return [
      _lan(
        Uri.parse(
          'http://192.168.1.10:${session.port}${session.workspacePath}',
        ),
      ),
    ];
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) => throw UnimplementedError();
}

class _DistributionControllerProvider extends _ControllerProvider {
  _DistributionControllerProvider({
    required bool initialInstalled,
    this.applyError,
    this.workspaceLinkError,
  }) : _installed = initialInstalled;

  final Object? applyError;
  Object? workspaceLinkError;
  final configSource = NamedDownloadEndpoint(
    name: 'Config',
    url: Uri.parse('https://config.example/update.json'),
  );
  final downloadSource = NamedDownloadEndpoint(
    name: 'ZIP',
    url: Uri.parse('https://download.example/GDevelop-webide-v5.6.269.zip'),
  );
  final List<bool> applyForceRedownload = [];
  final List<bool> localMemoryFallback = [];
  var workspaceLinkCalls = 0;
  bool _installed;
  var _installedAt = DateTime.utc(2026, 8, 5, 1);

  String get _sha256 => List.filled(64, 'b').join();

  GDevelopWebIdeReleaseManifest get release => GDevelopWebIdeReleaseManifest(
    version: '5.6.269',
    sha256: _sha256,
    size: 4096,
    downloads: [downloadSource],
  );

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  ) async {
    workspaceLinkCalls += 1;
    if (workspaceLinkError case final error?) throw error;
    if (!_installed) return const [];
    return [
      _lan(
        Uri.parse(
          'http://192.168.1.10:${session.port}'
          '${session.gdevelopWorkspacePath}',
        ),
      ),
    ];
  }

  @override
  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation() async {
    if (!_installed) {
      return const GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.absent,
      );
    }
    return GDevelopWebIdeInstallationInspection(
      state: GDevelopWebIdeInstallationState.ready,
      marker: GDevelopWebIdeInstalledMarker(
        version: release.version,
        sha256: release.sha256,
        noticesSha256: List.filled(64, 'd').join(),
        aiToolsPath: 'playmesh/ai/tools.json',
        aiToolsSha256: List.filled(64, 'e').join(),
        aiToolsContractHash: List.filled(64, 'f').join(),
        size: release.size,
        installedAt: _installedAt,
        installationKind: GDevelopWebIdeInstallationKind.release,
      ),
    );
  }

  @override
  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources() async =>
      GDevelopWebIdeConfigSources([configSource]);

  @override
  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) async {
    expect(selectedSource, same(configSource));
    return release;
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    applyForceRedownload.add(forceRedownload);
    expect(selectedDownload, same(downloadSource));
    if (applyError case final error?) throw error;
    onProgress?.call(
      VerifiedDownloadProgress(receivedBytes: 4096, totalBytes: 4096),
    );
    _installed = true;
    _installedAt = _installedAt.add(const Duration(minutes: 1));
    return GDevelopWebIdeInstallResult(
      marker: (await inspectGDevelopWebIdeInstallation()).marker!,
    );
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) async {
    localMemoryFallback.add(allowMemoryFallback);
    if (applyError case final error?) throw error;
    _installed = true;
    _installedAt = _installedAt.add(const Duration(minutes: 1));
    return GDevelopWebIdeInstallResult(
      marker: (await inspectGDevelopWebIdeInstallation()).marker!,
    );
  }
}

LanEndpointCandidate _lan(Uri uri) => LanEndpointCandidate(
  uri: uri,
  interfaceName: 'Wi-Fi',
  interfaceIndex: 1,
  addressType: LanAddressType.privateIpv4,
  risk: LanEndpointRisk.low,
);

class _ReachableProbeHttpClient implements EndpointProbeHttpClient {
  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async => EndpointProbeHttpResponse(statusCode: 204);

  @override
  void close() {}
}
