import '../developer/developer_channel.dart';
import '../developer/developer_capability_test_service.dart';
import '../developer/developer_ai_prompt_templates.dart';
import '../developer/developer_background_host.dart';
import '../developer/developer_project_catalog.dart';
import '../developer/developer_preferences.dart';
import '../developer/developer_run_controller.dart';
import '../developer/developer_web_gateway.dart';
import '../developer/gdevelop_project_history.dart';
import '../developer/gdevelop_web_ide_distribution.dart';
import '../developer/gdevelop_web_ide_installer_contract.dart';
import '../developer/gdevelop_web_ide_manager.dart';
import '../developer/gdevelop_local_package_source.dart';
import '../developer/gdevelop_web_ide_source.dart';
import '../download/named_download_endpoint.dart';
import '../download/verified_resumable_download_contract.dart';
import '../lifecycle/go_core_host.dart';
import '../network/go_core_client.dart';
import '../network/lan_endpoint.dart';
import '../protocol/go_core_status.dart';
import 'go_core_status_service.dart';

typedef GoCoreHealthClientFactory = GoCoreHealthClient Function(Uri endpoint);

class GoCoreRuntime
    implements
        GoCoreStatusProvider,
        DeveloperModeProvider,
        DeveloperWorkspacePreferenceProvider {
  GoCoreRuntime({
    required this.host,
    GoCoreHealthClient? client,
    GoCoreHealthClientFactory? clientFactory,
    this.developerProjectCatalog,
    this.developerAiPromptTemplates,
    DeveloperPreferences? developerPreferences,
    DeveloperRunController? developerRunController,
    this.developerCapabilityTests,
    this.developerAuthorProvider,
    this.developerProjectPublisher,
    this.developerWorkspaceLocalizationBridge,
    this._developerBackgroundNotificationLocalizationProvider,
    DeveloperBackgroundHost? developerBackgroundHost,
    this.developerGDevelopWebIdeSource,
    this.developerGDevelopHistory,
    GDevelopWebIdeManager? developerGDevelopWebIdeManager,
  }) : assert(client != null || clientFactory != null),
       _client = client,
       _clientFactory = clientFactory,
       _developerPreferences = developerPreferences ?? DeveloperPreferences(),
       _developerBackgroundHost =
           developerBackgroundHost ?? const PlatformDeveloperBackgroundHost(),
       _gdevelopWebIdeManager =
           developerGDevelopWebIdeManager ?? createGDevelopWebIdeManager(),
       developerRunController =
           developerRunController ?? DeveloperRunController();

  factory GoCoreRuntime.bundled({
    String address = '0.0.0.0:0',
    DeveloperProjectCatalog? developerProjectCatalog,
    DeveloperAiPromptTemplateStore? developerAiPromptTemplates,
    DeveloperPreferences? developerPreferences,
    DeveloperRunController? developerRunController,
    DeveloperCapabilityTestService? developerCapabilityTests,
    String Function()? developerAuthorProvider,
    DeveloperProjectPublisher? developerProjectPublisher,
    DeveloperWorkspaceLocalizationBridge? developerWorkspaceLocalizationBridge,
    DeveloperBackgroundNotificationLocalizationProvider?
    developerBackgroundNotificationLocalizationProvider,
    DeveloperBackgroundHost? developerBackgroundHost,
    GDevelopWebIdeSource? developerGDevelopWebIdeSource,
    GDevelopWebIdeManager? developerGDevelopWebIdeManager,
  }) {
    final host = createBundledGoCoreHost(address: address);
    return GoCoreRuntime(
      host: host,
      clientFactory: (endpoint) => GoCoreClient(
        baseUri: endpoint.replace(path: '/', query: null, fragment: null),
      ),
      developerProjectCatalog: developerProjectCatalog,
      developerAiPromptTemplates: developerAiPromptTemplates,
      developerPreferences: developerPreferences,
      developerRunController: developerRunController,
      developerCapabilityTests: developerCapabilityTests,
      developerAuthorProvider: developerAuthorProvider,
      developerProjectPublisher: developerProjectPublisher,
      developerWorkspaceLocalizationBridge:
          developerWorkspaceLocalizationBridge,
      developerBackgroundNotificationLocalizationProvider:
          developerBackgroundNotificationLocalizationProvider,
      developerBackgroundHost: developerBackgroundHost,
      developerGDevelopWebIdeSource: developerGDevelopWebIdeSource,
      developerGDevelopWebIdeManager: developerGDevelopWebIdeManager,
    );
  }

  final GoCoreHost host;
  final GoCoreHealthClient? _client;
  final GoCoreHealthClientFactory? _clientFactory;
  final DeveloperProjectCatalog? developerProjectCatalog;
  final DeveloperAiPromptTemplateStore? developerAiPromptTemplates;
  final DeveloperRunController developerRunController;
  final DeveloperCapabilityTestService? developerCapabilityTests;
  final String Function()? developerAuthorProvider;
  final DeveloperProjectPublisher? developerProjectPublisher;
  DeveloperWorkspaceLocalizationBridge? developerWorkspaceLocalizationBridge;
  final DeveloperPreferences _developerPreferences;
  DeveloperBackgroundNotificationLocalizationProvider?
  _developerBackgroundNotificationLocalizationProvider;
  final DeveloperBackgroundHost _developerBackgroundHost;
  final GDevelopWebIdeSource? developerGDevelopWebIdeSource;
  final GDevelopProjectHistoryAdapter? developerGDevelopHistory;
  final GDevelopWebIdeManager _gdevelopWebIdeManager;
  GoCoreStatusService? _statusService;
  DeveloperWebGateway? _developerGateway;
  DeveloperSession? _developerSession;
  List<LanEndpointCandidate> _developerLinks = const [];
  List<LanEndpointCandidate> _gdevelopLinks = const [];
  Future<void>? _startOperation;
  Future<void>? _closeOperation;
  bool _gdevelopWebIdeInstallInProgress = false;
  int _developerModeLifecycleOperations = 0;
  bool _closed = false;

  @override
  Uri get endpoint => _statusService?.endpoint ?? host.endpoint;

  Future<void> start() {
    if (_closed) {
      return Future<void>.error(
        const GoCoreHostException(
          code: 'core_runtime_closed',
          userMessage: '内置 Go Core 已关闭。',
          diagnostic: 'start called after runtime close',
        ),
      );
    }
    return _startOperation ??= _startHost();
  }

  void setDeveloperWorkspaceLocalizationBridge(
    DeveloperWorkspaceLocalizationBridge bridge,
  ) {
    developerWorkspaceLocalizationBridge = bridge;
  }

  void setDeveloperBackgroundNotificationLocalizationProvider(
    DeveloperBackgroundNotificationLocalizationProvider provider,
  ) {
    _developerBackgroundNotificationLocalizationProvider = provider;
  }

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) async {
    if (_gdevelopWebIdeInstallInProgress) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    _developerModeLifecycleOperations += 1;
    try {
      await _developerGateway?.close();
      await _developerBackgroundHost.stop();
      _developerGateway = null;
      _developerSession = null;
      _developerLinks = const [];
      _gdevelopLinks = const [];

      final preference = await _developerPreferences.load();
      final requestedToken = token?.trim() ?? '';
      final gdevelopWebIdeSource =
          developerGDevelopWebIdeSource ?? createGDevelopWebIdeSource();
      final gdevelopWorkspaceAvailable = await gdevelopWebIdeSource
          .isAvailable();
      final gateway = await startDeveloperWebGateway(
        port: port,
        token: requestedToken.isEmpty ? preference.token : requestedToken,
        path: preference.path,
        catalog: developerProjectCatalog,
        promptTemplates: developerAiPromptTemplates,
        runController: developerRunController,
        capabilityTests: developerCapabilityTests,
        currentAuthor: developerAuthorProvider,
        projectPublisher: developerProjectPublisher,
        localizationBridge: developerWorkspaceLocalizationBridge,
        viewAvailability: _developerBackgroundHost.viewAvailability,
        gdevelopWebIdeSource: gdevelopWebIdeSource,
        gdevelopAiToolsProvider:
            _gdevelopWebIdeManager.loadInstalledAiToolRegistry,
        gdevelopHistory: developerGDevelopHistory,
        gdevelopAiFeaturePolicy: GDevelopAiFeaturePolicy.forDeveloperSession(
          developerModeEnabled: true,
          gdevelopWorkspaceAvailable: gdevelopWorkspaceAvailable,
        ),
      );
      try {
        await _developerBackgroundHost.start(
          port: gateway.session.port!,
          localization: _developerBackgroundNotificationLocalizationProvider
              ?.call(),
        );
        _developerGateway = gateway;
        _developerSession = gateway.session;
        _developerLinks = await gateway.sourceWorkspaceEndpoints();
        _gdevelopLinks = await gateway.gdevelopWorkspaceEndpoints();
        await _developerPreferences.save(
          DeveloperWorkspacePreference(
            port: gateway.session.port!,
            token: gateway.session.token!,
            path: gateway.session.path!,
          ),
        );
      } on Object {
        await gateway.close();
        await _developerBackgroundHost.stop();
        _developerGateway = null;
        _developerSession = null;
        _developerLinks = const [];
        _gdevelopLinks = const [];
        rethrow;
      }
      return gateway.session;
    } finally {
      _developerModeLifecycleOperations -= 1;
    }
  }

  @override
  Future<DeveloperSession> developerModeStatus() async {
    return _developerSession ?? const DeveloperSession(enabled: false);
  }

  @override
  Future<DeveloperWorkspacePreference> loadDeveloperWorkspacePreference() =>
      _developerPreferences.load();

  @override
  Future<void> disableDeveloperMode() async {
    _developerModeLifecycleOperations += 1;
    final gateway = _developerGateway;
    _developerGateway = null;
    _developerSession = null;
    _developerLinks = const [];
    _gdevelopLinks = const [];
    try {
      try {
        await gateway?.close();
      } finally {
        await _developerBackgroundHost.stop();
      }
    } finally {
      _developerModeLifecycleOperations -= 1;
    }
  }

  Future<void> refreshDeveloperBackgroundNotification() async {
    final session = _developerSession;
    final port = session?.port;
    if (session?.enabled != true || port == null) return;
    final localization = _developerBackgroundNotificationLocalizationProvider
        ?.call();
    if (localization == null) return;
    await _developerBackgroundHost.updateNotification(
      port: port,
      localization: localization,
    );
  }

  void reportDeveloperGameRunning({
    required String projectId,
    String? expectedRunId,
    String? joinCode,
    List<Uri> links = const [],
  }) {
    developerRunController.reportRunning(
      projectId: projectId,
      expectedRunId: expectedRunId,
      joinCode: joinCode,
      links: links,
    );
  }

  void reportDeveloperGameError(
    String projectId,
    Object error, {
    String? expectedRunId,
  }) {
    developerRunController.reportError(
      projectId,
      error,
      expectedRunId: expectedRunId,
    );
  }

  void reportDeveloperGameStopped(String projectId, {String? expectedRunId}) {
    developerRunController.reportStopped(
      projectId,
      expectedRunId: expectedRunId,
    );
  }

  void Function() registerDeveloperGameRestartHandler(
    String projectId,
    Future<void> Function() handler, {
    String? expectedRunId,
  }) => developerRunController.registerRestartHandler(
    projectId,
    handler,
    expectedRunId: expectedRunId,
  );

  void Function() registerDeveloperGameStopHandler(
    String projectId,
    Future<void> Function() handler, {
    String? expectedRunId,
  }) => developerRunController.registerStopHandler(
    projectId,
    handler,
    expectedRunId: expectedRunId,
  );

  void Function() registerDeveloperGameJavaScriptExecutor(
    String projectId,
    DeveloperWebViewJavaScriptExecutor executor, {
    String? expectedRunId,
  }) => developerRunController.registerJavaScriptExecutor(
    projectId,
    executor,
    expectedRunId: expectedRunId,
  );

  @override
  Future<List<LanEndpointCandidate>> sourceWorkspaceLinks(
    DeveloperSession session,
  ) async {
    if (!session.enabled || !identical(session, _developerSession)) {
      return const [];
    }
    return List.unmodifiable(_developerLinks);
  }

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  ) async {
    if (!session.enabled || !identical(session, _developerSession)) {
      return const [];
    }
    final gateway = _developerGateway;
    if (gateway == null) return const [];
    _gdevelopLinks = await gateway.gdevelopWorkspaceEndpoints();
    return List.unmodifiable(_gdevelopLinks);
  }

  @override
  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation() =>
      _gdevelopWebIdeManager.inspectInstallation();

  @override
  Future<GDevelopWebIdeInstalledNotices> loadInstalledGDevelopWebIdeNotices() =>
      _gdevelopWebIdeManager.loadInstalledNotices();

  @override
  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources() =>
      _gdevelopWebIdeManager.loadConfigSources();

  @override
  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) => _gdevelopWebIdeManager.loadReleaseManifest(selectedSource);

  @override
  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    if (_gdevelopWebIdeInstallInProgress) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    _ensureGDevelopWebIdeInstallationAllowed();
    _gdevelopWebIdeInstallInProgress = true;
    try {
      final result = await _gdevelopWebIdeManager.applyRelease(
        release: release,
        selectedDownload: selectedDownload,
        forceRedownload: forceRedownload,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
      return result;
    } finally {
      _gdevelopWebIdeInstallInProgress = false;
    }
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) async {
    if (_gdevelopWebIdeInstallInProgress) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    _ensureGDevelopWebIdeInstallationAllowed();
    _gdevelopWebIdeInstallInProgress = true;
    try {
      final result = await _gdevelopWebIdeManager.applyLocalPackage(
        source: source,
        allowMemoryFallback: allowMemoryFallback,
        cancellationToken: cancellationToken,
      );
      return result;
    } finally {
      _gdevelopWebIdeInstallInProgress = false;
    }
  }

  void _ensureGDevelopWebIdeInstallationAllowed() {
    if (_developerModeLifecycleOperations > 0 ||
        _developerGateway != null ||
        _developerSession?.enabled == true) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_developer_mode_must_be_disabled_before_install',
      );
    }
  }

  Future<void> _startHost() async {
    try {
      await host.start();
      if (_closed) {
        await host.stop();
        return;
      }
      _statusService ??= GoCoreStatusService(
        _client ?? _clientFactory!(host.endpoint),
      );
    } on Object {
      _startOperation = null;
      if (_closed) return;
      rethrow;
    }
  }

  @override
  Future<GoCoreStatusResult> check() async {
    try {
      await start();
    } on GoCoreHostException catch (error) {
      return GoCoreStatusResult.error(
        message: error.userMessage,
        requestId: 'host-${DateTime.now().millisecondsSinceEpoch}',
      );
    }

    final statusService = _statusService!;
    GoCoreStatusResult result = await statusService.check();
    for (
      var attempt = 0;
      attempt < 5 && result.availability == GoCoreAvailability.offline;
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      result = await statusService.check();
    }
    return result;
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closeOperation ??= _close();
  }

  Future<void> _close() async {
    await host.stop();
    await disableDeveloperMode();
    _gdevelopWebIdeManager.close();
    await _statusService?.close();
    _statusService = null;
    _startOperation = null;
  }
}
