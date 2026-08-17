import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/developer/developer_channel.dart';
import '../../core/developer/gdevelop_web_ide_distribution.dart';
import '../../core/developer/gdevelop_web_ide_installer_contract.dart';
import '../../core/developer/gdevelop_local_package_source.dart';
import '../../core/download/endpoint_picker_controller.dart';
import '../../core/download/endpoint_probe.dart';
import '../../core/download/named_download_endpoint.dart';
import '../../core/download/verified_resumable_download_contract.dart';
import '../../core/network/lan_endpoint.dart';

const _unchangedVisualValue = Object();

enum VisualGDevelopOperation { install, upgrade, repair }

class VisualGDevelopState {
  const VisualGDevelopState({
    this.links = const [],
    this.loading = false,
    this.starting = false,
    this.loadingRelease = false,
    this.installation,
    this.configSources = const [],
    this.release,
    this.operation,
    this.progress,
    this.completedOperation,
    this.statusError,
    this.startError,
    this.configError,
    this.releaseError,
    this.operationError,
  });

  final List<LanEndpointCandidate> links;
  final bool loading;
  final bool starting;
  final bool loadingRelease;
  final GDevelopWebIdeInstallationInspection? installation;
  final List<NamedDownloadEndpoint> configSources;
  final GDevelopWebIdeReleaseManifest? release;
  final VisualGDevelopOperation? operation;
  final VerifiedDownloadProgress? progress;
  final VisualGDevelopOperation? completedOperation;
  final Object? statusError;
  final Object? startError;
  final Object? configError;
  final Object? releaseError;
  final Object? operationError;

  bool get available => links.isNotEmpty;
  bool get configured => configSources.isNotEmpty;
  bool get operationRunning => operation != null;

  bool get releaseMatchesInstallation {
    final currentRelease = release;
    final currentInstallation = installation;
    return currentRelease != null &&
        currentInstallation != null &&
        currentInstallation.matchesSha256(currentRelease.sha256);
  }

  VisualGDevelopOperation? get primaryOperation {
    if (release == null || operationRunning) return null;
    return switch (installation?.state) {
      GDevelopWebIdeInstallationState.absent => VisualGDevelopOperation.install,
      GDevelopWebIdeInstallationState.needsRepair =>
        VisualGDevelopOperation.repair,
      GDevelopWebIdeInstallationState.ready =>
        releaseMatchesInstallation ? null : VisualGDevelopOperation.upgrade,
      null => null,
    };
  }

  VisualGDevelopState copyWith({
    List<LanEndpointCandidate>? links,
    bool? loading,
    bool? starting,
    bool? loadingRelease,
    Object? installation = _unchangedVisualValue,
    List<NamedDownloadEndpoint>? configSources,
    Object? release = _unchangedVisualValue,
    Object? operation = _unchangedVisualValue,
    Object? progress = _unchangedVisualValue,
    Object? completedOperation = _unchangedVisualValue,
    Object? statusError = _unchangedVisualValue,
    Object? startError = _unchangedVisualValue,
    Object? configError = _unchangedVisualValue,
    Object? releaseError = _unchangedVisualValue,
    Object? operationError = _unchangedVisualValue,
  }) => VisualGDevelopState(
    links: links ?? this.links,
    loading: loading ?? this.loading,
    starting: starting ?? this.starting,
    loadingRelease: loadingRelease ?? this.loadingRelease,
    installation: identical(installation, _unchangedVisualValue)
        ? this.installation
        : installation as GDevelopWebIdeInstallationInspection?,
    configSources: configSources ?? this.configSources,
    release: identical(release, _unchangedVisualValue)
        ? this.release
        : release as GDevelopWebIdeReleaseManifest?,
    operation: identical(operation, _unchangedVisualValue)
        ? this.operation
        : operation as VisualGDevelopOperation?,
    progress: identical(progress, _unchangedVisualValue)
        ? this.progress
        : progress as VerifiedDownloadProgress?,
    completedOperation: identical(completedOperation, _unchangedVisualValue)
        ? this.completedOperation
        : completedOperation as VisualGDevelopOperation?,
    statusError: identical(statusError, _unchangedVisualValue)
        ? this.statusError
        : statusError,
    startError: identical(startError, _unchangedVisualValue)
        ? this.startError
        : startError,
    configError: identical(configError, _unchangedVisualValue)
        ? this.configError
        : configError,
    releaseError: identical(releaseError, _unchangedVisualValue)
        ? this.releaseError
        : releaseError,
    operationError: identical(operationError, _unchangedVisualValue)
        ? this.operationError
        : operationError,
  );
}

/// GDevelop 可视化入口；独立处理 WebIDE 分发、安装状态与链接派生。
class VisualGDevelopController extends ChangeNotifier {
  VisualGDevelopController(this.provider, {EndpointProbeService? probeService})
    : _probeService = probeService ?? createEndpointProbeService(),
      _ownsProbeService = probeService == null;

  final VisualGDevelopProvider? provider;
  final EndpointProbeService _probeService;
  final bool _ownsProbeService;
  VisualGDevelopState _state = const VisualGDevelopState();
  EndpointPickerController? _configSourcePicker;
  EndpointPickerController? _downloadSourcePicker;
  DeveloperSession? _session;
  DownloadCancellationToken? _cancellationToken;
  int _synchronizeGeneration = 0;
  int _releaseGeneration = 0;
  int _operationGeneration = 0;
  int _startGeneration = 0;
  bool _disposed = false;

  VisualGDevelopState get state => _state;
  EndpointPickerController? get configSourcePicker => _configSourcePicker;
  EndpointPickerController? get downloadSourcePicker => _downloadSourcePicker;
  NamedDownloadEndpoint? get selectedDownload =>
      _downloadSourcePicker?.selected;

  bool get canStartPrimaryOperation =>
      state.primaryOperation != null &&
      selectedDownload != null &&
      !state.loadingRelease;

  bool get canRepair =>
      state.installation?.state == GDevelopWebIdeInstallationState.ready &&
      state.releaseMatchesInstallation &&
      selectedDownload != null &&
      !state.operationRunning &&
      !state.loadingRelease;

  Future<void> synchronize(DeveloperSession? session) async {
    final generation = ++_synchronizeGeneration;
    _startGeneration += 1;
    _releaseGeneration += 1;
    _session = session;
    final activeProvider = provider;
    if (activeProvider == null) {
      _cancellationToken?.cancel();
      _replaceConfigSourcePicker(null);
      _replaceDownloadSourcePicker(null);
      _setState(const VisualGDevelopState());
      return;
    }

    _setState(
      VisualGDevelopState(loading: true, starting: session?.enabled == true),
    );
    final installationFuture = _capture(
      activeProvider.inspectGDevelopWebIdeInstallation,
    );
    final sourcesFuture = _capture(
      activeProvider.loadGDevelopWebIdeConfigSources,
    );
    final linksFuture = session?.enabled == true
        ? _capture(() => activeProvider.gdevelopWorkspaceLinks(session!))
        : Future.value(const _Captured<List<LanEndpointCandidate>>(value: []));
    final results = await Future.wait<Object?>([
      installationFuture,
      sourcesFuture,
      linksFuture,
    ]);
    if (_disposed || generation != _synchronizeGeneration) return;

    final installation =
        results[0] as _Captured<GDevelopWebIdeInstallationInspection>;
    final sources = results[1] as _Captured<GDevelopWebIdeConfigSources>;
    final links = results[2] as _Captured<List<LanEndpointCandidate>>;
    final configuredSources = sources.value?.sources ?? const [];
    _replaceConfigSourcePicker(
      EndpointPickerController(
        endpoints: configuredSources,
        probeService: _probeService,
      ),
    );
    _replaceDownloadSourcePicker(null);
    _setState(
      VisualGDevelopState(
        links: List.unmodifiable(links.value ?? const []),
        installation: installation.value,
        configSources: List.unmodifiable(configuredSources),
        starting: false,
        statusError: installation.error,
        startError: links.error,
        configError: sources.error,
      ),
    );
  }

  /// Ensures the visual workspace gateway is available for the active
  /// Developer Mode session and refreshes its visual-only LAN endpoints.
  Future<void> ensureStarted() async {
    final activeProvider = provider;
    final session = _session;
    if (activeProvider == null || session?.enabled != true || state.starting) {
      return;
    }
    final generation = ++_startGeneration;
    _setState(_state.copyWith(starting: true, startError: null));
    try {
      final links = await activeProvider.gdevelopWorkspaceLinks(session!);
      if (_disposed || generation != _startGeneration) return;
      _setState(
        _state.copyWith(
          links: List.unmodifiable(links),
          starting: false,
          startError: null,
        ),
      );
    } on Object catch (error) {
      if (_disposed || generation != _startGeneration) return;
      _setState(_state.copyWith(starting: false, startError: error));
    }
  }

  Future<void> selectConfigSource(NamedDownloadEndpoint endpoint) async {
    final activeProvider = provider;
    final picker = _configSourcePicker;
    if (activeProvider == null || picker?.selected != endpoint) return;
    final generation = ++_releaseGeneration;
    _replaceDownloadSourcePicker(null);
    _setState(
      _state.copyWith(
        loadingRelease: true,
        release: null,
        releaseError: null,
        operationError: null,
        completedOperation: null,
      ),
    );
    debugPrint(
      'GDevelop WebIDE 读取版本清单: '
      'source=${endpoint.name}, host=${endpoint.url.host}',
    );
    try {
      final release = await activeProvider.loadGDevelopWebIdeReleaseManifest(
        endpoint,
      );
      if (_disposed || generation != _releaseGeneration) return;
      _replaceDownloadSourcePicker(
        EndpointPickerController(
          endpoints: release.downloads,
          probeService: _probeService,
        ),
      );
      _setState(
        _state.copyWith(
          loadingRelease: false,
          release: release,
          releaseError: null,
        ),
      );
    } on Object catch (error) {
      debugPrint('GDevelop WebIDE 版本清单失败: $error');
      if (_disposed || generation != _releaseGeneration) return;
      _setState(
        _state.copyWith(
          loadingRelease: false,
          release: null,
          releaseError: error,
        ),
      );
    }
  }

  Future<void> startPrimaryOperation() async {
    final operation = state.primaryOperation;
    if (operation == null) return;
    await _apply(operation);
  }

  Future<void> repair() async {
    if (!canRepair) return;
    await _apply(VisualGDevelopOperation.repair);
  }

  Future<void> installLocalPackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
  }) async {
    final activeProvider = provider;
    if (activeProvider == null || state.operationRunning) return;
    final generation = ++_operationGeneration;
    final cancellation = DownloadCancellationToken();
    _cancellationToken = cancellation;
    _setState(
      _state.copyWith(
        operation: VisualGDevelopOperation.install,
        progress: null,
        operationError: null,
        completedOperation: null,
      ),
    );
    try {
      await activeProvider.applyLocalGDevelopWebIdePackage(
        source: source,
        allowMemoryFallback: allowMemoryFallback,
        cancellationToken: cancellation,
      );
      final installation = await activeProvider
          .inspectGDevelopWebIdeInstallation();
      final session = _session;
      final links = session?.enabled == true
          ? await activeProvider.gdevelopWorkspaceLinks(session!)
          : const <LanEndpointCandidate>[];
      if (_disposed || generation != _operationGeneration) return;
      _setState(
        _state.copyWith(
          links: List.unmodifiable(links),
          installation: installation,
          operation: null,
          operationError: null,
          completedOperation: VisualGDevelopOperation.install,
          statusError: null,
        ),
      );
    } on GDevelopLocalPackageStreamingUnavailable {
      if (!_disposed && generation == _operationGeneration) {
        _setState(_state.copyWith(operation: null, operationError: null));
      }
      rethrow;
    } on Object catch (error) {
      if (_disposed || generation != _operationGeneration) return;
      final installation = await _capture(
        activeProvider.inspectGDevelopWebIdeInstallation,
      );
      if (_disposed || generation != _operationGeneration) return;
      _setState(
        _state.copyWith(
          installation: installation.value ?? _state.installation,
          operation: null,
          operationError: error,
          completedOperation: null,
          statusError: installation.error,
        ),
      );
    } finally {
      if (generation == _operationGeneration) _cancellationToken = null;
    }
  }

  void cancelOperation() => _cancellationToken?.cancel();

  Uri inAppWorkspaceUri(Uri workspaceUri) =>
      workspaceUri.replace(host: '127.0.0.1');

  Future<void> _apply(VisualGDevelopOperation operation) async {
    final activeProvider = provider;
    final release = state.release;
    final download = selectedDownload;
    final session = _session;
    if (activeProvider == null ||
        release == null ||
        download == null ||
        state.operationRunning) {
      return;
    }
    final generation = ++_operationGeneration;
    final cancellation = DownloadCancellationToken();
    _cancellationToken = cancellation;
    _setState(
      _state.copyWith(
        operation: operation,
        progress: null,
        operationError: null,
        completedOperation: null,
      ),
    );
    debugPrint(
      'GDevelop WebIDE ${operation.name} 开始: '
      'version=${release.version}, sha256=${release.sha256}, '
      'download=${download.name}, '
      'host=${download.url.host}',
    );
    try {
      await activeProvider.applyGDevelopWebIdeRelease(
        release: release,
        selectedDownload: download,
        forceRedownload: operation == VisualGDevelopOperation.repair,
        cancellationToken: cancellation,
        onProgress: (progress) {
          if (_disposed || generation != _operationGeneration) return;
          _setState(_state.copyWith(progress: progress));
        },
      );
      final installation = await activeProvider
          .inspectGDevelopWebIdeInstallation();
      final links = session?.enabled == true
          ? await activeProvider.gdevelopWorkspaceLinks(session!)
          : const <LanEndpointCandidate>[];
      if (_disposed || generation != _operationGeneration) return;
      _setState(
        _state.copyWith(
          links: List.unmodifiable(links),
          installation: installation,
          operation: null,
          progress: null,
          operationError: null,
          completedOperation: operation,
          statusError: null,
        ),
      );
      debugPrint(
        'GDevelop WebIDE ${operation.name} 完成: '
        'version=${installation.marker?.version ?? release.version}, '
        'sha256=${installation.marker?.sha256 ?? release.sha256}',
      );
    } on Object catch (error) {
      debugPrint('GDevelop WebIDE ${operation.name} 失败: $error');
      if (_disposed || generation != _operationGeneration) return;
      final installation = await _capture(
        activeProvider.inspectGDevelopWebIdeInstallation,
      );
      final links = session?.enabled == true
          ? await _capture(
              () => activeProvider.gdevelopWorkspaceLinks(session!),
            )
          : const _Captured<List<LanEndpointCandidate>>(value: []);
      if (_disposed || generation != _operationGeneration) return;
      _setState(
        _state.copyWith(
          links: List.unmodifiable(links.value ?? _state.links),
          installation: installation.value ?? _state.installation,
          operation: null,
          progress: null,
          operationError: error,
          completedOperation: null,
          statusError: installation.error ?? links.error,
        ),
      );
    } finally {
      if (generation == _operationGeneration) _cancellationToken = null;
    }
  }

  void _handleConfigSourcePickerChanged() {
    if (_configSourcePicker?.selected == null && _state.release != null) {
      _releaseGeneration += 1;
      _replaceDownloadSourcePicker(null);
      _setState(
        _state.copyWith(
          release: null,
          loadingRelease: false,
          releaseError: null,
        ),
      );
      return;
    }
    if (!_disposed) notifyListeners();
  }

  void _handleDownloadSourcePickerChanged() {
    if (!_disposed) notifyListeners();
  }

  void _replaceConfigSourcePicker(EndpointPickerController? next) {
    final previous = _configSourcePicker;
    if (identical(previous, next)) return;
    previous?.removeListener(_handleConfigSourcePickerChanged);
    previous?.dispose();
    _configSourcePicker = next;
    next?.addListener(_handleConfigSourcePickerChanged);
  }

  void _replaceDownloadSourcePicker(EndpointPickerController? next) {
    final previous = _downloadSourcePicker;
    if (identical(previous, next)) return;
    previous?.removeListener(_handleDownloadSourcePickerChanged);
    previous?.dispose();
    _downloadSourcePicker = next;
    next?.addListener(_handleDownloadSourcePickerChanged);
  }

  void _setState(VisualGDevelopState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _synchronizeGeneration += 1;
    _releaseGeneration += 1;
    _operationGeneration += 1;
    _startGeneration += 1;
    _cancellationToken?.cancel();
    _replaceConfigSourcePicker(null);
    _replaceDownloadSourcePicker(null);
    if (_ownsProbeService) _probeService.close();
    super.dispose();
  }
}

class _Captured<T> {
  const _Captured({this.value, this.error});

  final T? value;
  final Object? error;
}

Future<_Captured<T>> _capture<T>(Future<T> Function() operation) async {
  try {
    return _Captured(value: await operation());
  } on Object catch (error) {
    return _Captured(error: error);
  }
}
