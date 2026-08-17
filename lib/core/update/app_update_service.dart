import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../download/endpoint_document.dart';
import '../download/endpoint_probe.dart';
import '../download/named_download_endpoint.dart';
import '../release/playmesh_release_notes.dart';
import '../version/semantic_version.dart';
import 'app_update_models.dart';

typedef AppUpdateAssetLoader = Future<String> Function(String assetKey);
typedef AppUpdateUrlLauncher = Future<bool> Function(Uri url);

abstract interface class AppUpdateChecker {
  Future<AppUpdateCheckResult> checkForUpdates();

  Future<bool> openDownload(AppUpdateDownload download);

  void close();
}

final class AppUpdateService implements AppUpdateChecker {
  factory AppUpdateService({
    required AppUpdateAssetLoader assetLoader,
    required EndpointDocumentLoader documentLoader,
    required EndpointProbeService probeService,
    required String platform,
    required SemanticVersion currentVersion,
    required AppUpdateUrlLauncher urlLauncher,
    void Function()? onClose,
    DateTime Function()? clock,
  }) => AppUpdateService._(
    assetLoader,
    documentLoader,
    probeService,
    platform,
    currentVersion,
    urlLauncher,
    onClose,
    clock,
  );

  AppUpdateService._(
    this._assetLoader,
    this._documentLoader,
    this._probeService,
    String platform,
    this.currentVersion,
    this._urlLauncher,
    this._onClose,
    DateTime Function()? clock,
  ) : platform = _normalizePlatform(platform),
      _clock = clock ?? DateTime.now;

  factory AppUpdateService.bundled() {
    final documentClient = createEndpointDocumentHttpClient();
    final probeService = createEndpointProbeService();
    return AppUpdateService(
      assetLoader: rootBundle.loadString,
      documentLoader: EndpointDocumentLoader(httpClient: documentClient),
      probeService: probeService,
      platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
      currentVersion: SemanticVersion.parse(playmeshVersion),
      urlLauncher: (url) =>
          launchUrl(url, mode: LaunchMode.externalApplication),
      onClose: () {
        documentClient.close();
        probeService.close();
      },
    );
  }

  static const String sourcesAssetKey = 'assets/app/App.json';

  final AppUpdateAssetLoader _assetLoader;
  final EndpointDocumentLoader _documentLoader;
  final EndpointProbeService _probeService;
  final AppUpdateUrlLauncher _urlLauncher;
  final void Function()? _onClose;
  final DateTime Function() _clock;
  final String platform;
  final SemanticVersion currentVersion;

  var _closed = false;

  @override
  Future<AppUpdateCheckResult> checkForUpdates() async {
    if (_closed) {
      throw const AppUpdateCheckException(
        kind: AppUpdateCheckFailureKind.closed,
        diagnostic: 'app_update_service_closed',
      );
    }
    final requestId = 'app-update-${_clock().microsecondsSinceEpoch}';
    final sources = await _loadSources(requestId);
    debugPrint(
      '[$requestId] App update check started: '
      '${sources.endpoints.length} manifest sources, platform=$platform',
    );

    // 清单源必须同时开始请求，避免线路顺序把总等待时间放大；单个坏源不阻断其他源。
    final outcomes = await Future.wait(
      sources.endpoints.map((source) => _loadManifest(source, requestId)),
    );
    final available = outcomes.whereType<_LoadedAppUpdateManifest>().toList();
    if (available.isEmpty) {
      debugPrint('[$requestId] App update check failed: no valid manifest');
      throw const AppUpdateCheckException(
        kind: AppUpdateCheckFailureKind.noAvailableManifest,
        diagnostic: 'no_valid_app_update_manifest',
      );
    }

    // 同版本保持 App.json 的原始顺序，确保多个等价源不会产生随机选择结果。
    var selected = available.first;
    for (final candidate in available.skip(1)) {
      if (candidate.manifest.version > selected.manifest.version) {
        selected = candidate;
      }
    }

    final platformDownloads = selected.manifest.platforms[platform];
    final endpoints = platformDownloads?.endpoints ?? const [];
    final probes = await _probeService.probeAll(
      endpoints.map((item) => item.url),
    );
    final downloads = <AppUpdateDownload>[
      for (var index = 0; index < endpoints.length; index += 1)
        AppUpdateDownload(endpoint: endpoints[index], probe: probes[index]),
    ];
    debugPrint(
      '[$requestId] App update check completed: source=${selected.source.name}, '
      'version=${selected.manifest.version}, valid=${available.length}/'
      '${sources.endpoints.length}, downloads=${downloads.length}',
    );

    return AppUpdateCheckResult(
      currentVersion: currentVersion,
      latestVersion: selected.manifest.version,
      releaseNotes: selected.manifest.releaseNotes,
      source: selected.source,
      platform: platform,
      platformAvailable: platformDownloads != null,
      downloads: List.unmodifiable(downloads),
      sourceCount: sources.endpoints.length,
      successfulSourceCount: available.length,
    );
  }

  @override
  Future<bool> openDownload(AppUpdateDownload download) async {
    if (_closed || !_isSafeExternalUrl(download.endpoint.url)) return false;
    try {
      return await _urlLauncher(download.endpoint.url);
    } on Object catch (error) {
      debugPrint(
        'Unable to open App update URL ${download.endpoint.url}: $error',
      );
      return false;
    }
  }

  Future<NamedDownloadEndpointList> _loadSources(String requestId) async {
    try {
      final source = await _assetLoader(sourcesAssetKey);
      return NamedDownloadEndpointList.parse(
        source,
        allowEmpty: false,
        field: 'appUpdateSources',
      );
    } on Object catch (error) {
      debugPrint(
        '[$requestId] Invalid App update source configuration: $error',
      );
      throw const AppUpdateCheckException(
        kind: AppUpdateCheckFailureKind.invalidConfiguration,
        diagnostic: 'invalid_app_update_source_configuration',
      );
    }
  }

  Future<_LoadedAppUpdateManifest?> _loadManifest(
    NamedDownloadEndpoint source,
    String requestId,
  ) async {
    try {
      final manifest = await _documentLoader.load(
        endpoint: source,
        parse: AppUpdateManifest.parse,
      );
      return _LoadedAppUpdateManifest(source: source, manifest: manifest);
    } on Object catch (error) {
      debugPrint(
        '[$requestId] App update source ${source.name} was ignored: $error',
      );
      return null;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _onClose?.call();
  }

  static String _normalizePlatform(String value) {
    final normalized = value.trim().toLowerCase();
    if (!supportedAppUpdatePlatforms.contains(normalized)) {
      throw ArgumentError.value(value, 'platform', 'unsupported platform');
    }
    return normalized;
  }

  static bool _isSafeExternalUrl(Uri url) =>
      url.scheme == 'https' &&
      url.host.isNotEmpty &&
      url.userInfo.isEmpty &&
      !url.hasFragment;
}

final class _LoadedAppUpdateManifest {
  const _LoadedAppUpdateManifest({
    required this.source,
    required this.manifest,
  });

  final NamedDownloadEndpoint source;
  final AppUpdateManifest manifest;
}
