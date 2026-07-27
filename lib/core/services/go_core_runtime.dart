import '../developer/developer_channel.dart';
import '../developer/developer_capability_test_service.dart';
import '../developer/developer_ai_prompt_templates.dart';
import '../developer/developer_background_host.dart';
import '../developer/developer_project_catalog.dart';
import '../developer/developer_preferences.dart';
import '../developer/developer_run_controller.dart';
import '../developer/developer_web_gateway.dart';
import '../lifecycle/go_core_host.dart';
import '../network/go_core_client.dart';
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
  }) : assert(client != null || clientFactory != null),
       _client = client,
       _clientFactory = clientFactory,
       _developerPreferences = developerPreferences ?? DeveloperPreferences(),
       _developerBackgroundHost =
           developerBackgroundHost ?? const PlatformDeveloperBackgroundHost(),
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
  GoCoreStatusService? _statusService;
  DeveloperWebGateway? _developerGateway;
  DeveloperSession? _developerSession;
  List<Uri> _developerLinks = const [];
  Future<void>? _startOperation;

  @override
  Uri get endpoint => _statusService?.endpoint ?? host.endpoint;

  Future<void> start() {
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
    await _developerGateway?.close();
    await _developerBackgroundHost.stop();
    _developerGateway = null;
    _developerSession = null;
    _developerLinks = const [];

    final preference = await _developerPreferences.load();
    final requestedToken = token?.trim() ?? '';
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
    );
    try {
      await _developerBackgroundHost.start(
        port: gateway.session.port!,
        localization: _developerBackgroundNotificationLocalizationProvider
            ?.call(),
      );
      _developerGateway = gateway;
      _developerSession = gateway.session;
      _developerLinks = await gateway.workspaceLinks();
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
      rethrow;
    }
    return gateway.session;
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
    final gateway = _developerGateway;
    _developerGateway = null;
    _developerSession = null;
    _developerLinks = const [];
    try {
      await gateway?.close();
    } finally {
      await _developerBackgroundHost.stop();
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
    Future<void> Function() handler,
  ) => developerRunController.registerRestartHandler(projectId, handler);

  void Function() registerDeveloperGameStopHandler(
    String projectId,
    Future<void> Function() handler,
  ) => developerRunController.registerStopHandler(projectId, handler);

  void Function() registerDeveloperGameJavaScriptExecutor(
    String projectId,
    DeveloperWebViewJavaScriptExecutor executor,
  ) => developerRunController.registerJavaScriptExecutor(projectId, executor);

  @override
  Future<List<Uri>> developerWorkspaceLinks(DeveloperSession session) async {
    if (!session.enabled || !identical(session, _developerSession)) {
      return const [];
    }
    return List.unmodifiable(_developerLinks);
  }

  Future<void> _startHost() async {
    try {
      await host.start();
      _statusService ??= GoCoreStatusService(
        _client ?? _clientFactory!(host.endpoint),
      );
    } on Object {
      _startOperation = null;
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
  Future<void> close() async {
    await disableDeveloperMode();
    await _statusService?.close();
    await host.stop();
    _statusService = null;
    _startOperation = null;
  }
}
