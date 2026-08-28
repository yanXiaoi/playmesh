import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../models/game_summary.dart';
import '../catalog/game_catalog_models.dart';
import '../catalog/online_game_catalog.dart';
import '../download/endpoint_probe.dart';
import '../download/named_download_endpoint.dart';
import '../game_package/game_package_icon.dart';
import '../game_package/game_package_share_files.dart';
import '../game_package/game_package_transfer_service.dart';
import '../library/playmesh_library_root.dart';
import '../relay/relay_tunnel_contract.dart';
import '../runtime_distribution/runtime_package_manager.dart';
import '../runtime_export/runtime_native_exporter_contract.dart';
import 'developer_installation_package_service.dart';

const defaultRuntimeExportKeystoreAsset =
    'assets/runtime-export/playmesh-default-export.p12';
const defaultRuntimeExportKeystorePassword = 'playmesh-default-export-v1';
const defaultRuntimeExportKeystoreAlias = 'playmesh-export';

final class GameCatalogDeveloperInstallationPackageRelayServerCatalog
    implements DeveloperInstallationPackageRelayServerCatalog {
  const GameCatalogDeveloperInstallationPackageRelayServerCatalog(
    this.controller,
  );

  final GameCatalogController controller;

  @override
  Future<List<DeveloperInstallationPackageRelayServer>> inspect() async {
    final probes = await controller.probeEnabledSources();
    final servers = <DeveloperInstallationPackageRelayServer>[];
    for (final probe in probes) {
      if (!_isCompatible(probe) || !_isSafeId(probe.source.id)) continue;
      servers.add(
        DeveloperInstallationPackageRelayServer(
          id: probe.source.id,
          name: _displayName(probe.source),
          address: catalogOrigin(probe.source.host),
          token: probe.source.token,
          latencyMs: probe.elapsed.inMilliseconds,
        ),
      );
    }
    servers.sort((left, right) {
      final latency = (left.latencyMs ?? 1 << 30).compareTo(
        right.latencyMs ?? 1 << 30,
      );
      if (latency != 0) return latency;
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return List.unmodifiable(servers);
  }

  static bool _isCompatible(OnlineGameSourceProbe probe) {
    final relay = probe.declaration?.relay;
    return probe.source.enabled &&
        probe.supportsGameRelay &&
        relay != null &&
        relay.transport == 'playmesh-webrtc-datachannel' &&
        relay.protocolVersion == relayProtocolVersion;
  }

  static bool _isSafeId(String value) =>
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

  static String _displayName(OnlineGameSource source) {
    final name = source.name.trim();
    return name.isNotEmpty && name.length <= 160
        ? name
        : formatCatalogHost(source.host);
  }
}

final class DeveloperAndroidExportSigningKey {
  const DeveloperAndroidExportSigningKey({
    required this.path,
    required this.storePassword,
    required this.keyPassword,
    required this.alias,
  });

  final String path;
  final String storePassword;
  final String keyPassword;
  final String alias;
}

abstract interface class DeveloperAndroidExportSigningKeyProvider {
  Future<DeveloperAndroidExportSigningKey> load();
}

final class BundledDeveloperAndroidExportSigningKeyProvider
    implements DeveloperAndroidExportSigningKeyProvider {
  BundledDeveloperAndroidExportSigningKeyProvider({
    AssetBundle? bundle,
    Directory? libraryRoot,
  }) : _bundle = bundle ?? rootBundle,
       _injectedLibraryRoot = libraryRoot;

  final AssetBundle _bundle;
  final Directory? _injectedLibraryRoot;
  Future<DeveloperAndroidExportSigningKey>? _loadOperation;

  @override
  Future<DeveloperAndroidExportSigningKey> load() => _loadOperation ??= _load();

  Future<DeveloperAndroidExportSigningKey> _load() async {
    final data = await _bundle.load(defaultRuntimeExportKeystoreAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.isEmpty) {
      throw StateError('内置 Android 导出签名密钥为空');
    }
    final library = _injectedLibraryRoot ?? await PlaymeshLibraryRoot.resolve();
    final directory = Directory(
      '${library.path}${Platform.pathSeparator}runtime'
      '${Platform.pathSeparator}signing',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}default-export-v1.p12',
    );
    final matches =
        await file.exists() &&
        await file.length() == bytes.length &&
        _constantBytesEqual(await file.readAsBytes(), bytes);
    if (!matches) {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    }
    return DeveloperAndroidExportSigningKey(
      path: file.path,
      storePassword: defaultRuntimeExportKeystorePassword,
      keyPassword: defaultRuntimeExportKeystorePassword,
      alias: defaultRuntimeExportKeystoreAlias,
    );
  }
}

final class FileDeveloperInstallationPackageService
    implements DeveloperInstallationPackageService {
  FileDeveloperInstallationPackageService({
    required this.runtimePackages,
    required this.nativeExporter,
    EndpointProbeService? runtimeDownloadProbeService,
    DeveloperInstallationPackageRelayServerCatalog? relayServerCatalog,
    GamePackageTransferService? packageTransfer,
    DeveloperAndroidExportSigningKeyProvider? signingKeyProvider,
    Directory? temporaryRoot,
    DateTime Function()? clock,
    Random? random,
  }) : runtimeDownloadProbeService =
           runtimeDownloadProbeService ?? createEndpointProbeService(),
       _ownsRuntimeDownloadProbeService = runtimeDownloadProbeService == null,
       packageTransfer = packageTransfer ?? GamePackageTransferService(),
       relayServerCatalog =
           relayServerCatalog ??
           const EmptyDeveloperInstallationPackageRelayServerCatalog(),
       signingKeyProvider =
           signingKeyProvider ??
           BundledDeveloperAndroidExportSigningKeyProvider(),
       _temporaryRoot = temporaryRoot ?? Directory.systemTemp,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  static const artifactLifetime = Duration(days: 1);

  final RuntimePackageManager runtimePackages;
  final RuntimeNativeExporter nativeExporter;
  final EndpointProbeService runtimeDownloadProbeService;
  final bool _ownsRuntimeDownloadProbeService;
  final DeveloperInstallationPackageRelayServerCatalog relayServerCatalog;
  final GamePackageTransferService packageTransfer;
  final DeveloperAndroidExportSigningKeyProvider signingKeyProvider;
  final Directory _temporaryRoot;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, _InstallationArtifactLease> _artifacts = {};
  Future<void> _createTail = Future<void>.value();
  Future<List<_RuntimePackageDownloadSelection>>?
  _runtimeInspectionSelectionsOperation;
  List<_RuntimePackageDownloadSelection>? _runtimeInspectionSelections;
  DateTime? _runtimeInspectionSelectionsAt;
  Future<void>? _closeOperation;
  var _closed = false;

  static const _runtimeInspectionCacheDuration = Duration(seconds: 30);

  Directory get _artifactRoot => Directory(
    '${_temporaryRoot.path}${Platform.pathSeparator}'
    'playmesh-installation-package-exports',
  );

  @override
  Future<List<DeveloperInstallationPackageTargetStatus>>
  inspectLocalTargets() async {
    _ensureOpen();
    final statuses = await Future.wait([
      for (final target in RuntimePackageTarget.values)
        runtimePackages.inspectPackage(target),
    ]);
    return List.unmodifiable([
      for (final status in statuses)
        DeveloperInstallationPackageTargetStatus(
          id: status.target.id,
          platform: status.target.platform,
          architecture: status.target.architecture,
          runtimeFilename: status.target.fileName,
          installed: status.installed,
          downloadAvailable: false,
          updateAvailable: false,
          sizeBytes: status.sizeBytes,
        ),
    ]);
  }

  @override
  Future<List<DeveloperInstallationPackageTargetStatus>>
  inspectTargets() async {
    _ensureOpen();
    final statuses = await runtimePackages.inspectPackages();
    final selections = await _runtimeDownloadSelectionsForInspection();
    final results = <DeveloperInstallationPackageTargetStatus>[];
    for (final status in statuses) {
      final targetSelections = selections
          .where((selection) => selection.target == status.target)
          .toList(growable: false);
      final downloadAvailable = targetSelections.isNotEmpty;
      results.add(
        DeveloperInstallationPackageTargetStatus(
          id: status.target.id,
          platform: status.target.platform,
          architecture: status.target.architecture,
          runtimeFilename: status.target.fileName,
          installed: status.installed,
          downloadAvailable: downloadAvailable,
          updateAvailable: await _runtimeUpdateAvailable(
            status: status,
            selections: targetSelections,
          ),
          runtimeDownloads: targetSelections
              .map((selection) => selection.presentation())
              .toList(growable: false),
          runtimeVersion: targetSelections.firstOrNull?.release.version,
          sizeBytes: status.sizeBytes,
        ),
      );
    }
    return results;
  }

  @override
  Future<DeveloperInstallationPackageTargetStatus> inspectRuntimeTarget(
    String targetId,
  ) async {
    _ensureOpen();
    final target = RuntimePackageTarget.parse(targetId);
    final status = await runtimePackages.inspectPackage(target);
    final selections = (await _runtimeDownloadSelectionsForInspectionCached())
        .where((selection) => selection.target == target)
        .toList(growable: false);
    return DeveloperInstallationPackageTargetStatus(
      id: status.target.id,
      platform: status.target.platform,
      architecture: status.target.architecture,
      runtimeFilename: status.target.fileName,
      installed: status.installed,
      downloadAvailable: selections.isNotEmpty,
      updateAvailable: await _runtimeUpdateAvailable(
        status: status,
        selections: selections,
      ),
      runtimeDownloads: selections
          .map(
            (selection) => selection.presentation(
              fallbackProbeState: EndpointProbeState.probing,
            ),
          )
          .toList(growable: false),
      runtimeVersion: selections.firstOrNull?.release.version,
      sizeBytes: status.sizeBytes,
    );
  }

  @override
  Future<List<DeveloperInstallationPackageRuntimeDownload>>
  probeRuntimeTargetDownloads(String targetId, String manifestSourceId) async {
    _ensureOpen();
    final target = RuntimePackageTarget.parse(targetId);
    final selections = (await _runtimeDownloadSelectionsForInspectionCached())
        .where(
          (selection) =>
              selection.target == target &&
              selection.presentation().manifestSourceId == manifestSourceId,
        )
        .toList(growable: false);
    final probed = await _probeRuntimeDownloadSelections(selections);
    return List.unmodifiable([
      for (final selection in probed) selection.presentation(),
    ]);
  }

  Future<bool> _runtimeUpdateAvailable({
    required RuntimePackageStatus status,
    required List<_RuntimePackageDownloadSelection> selections,
  }) async {
    if (!status.installed || selections.isEmpty) {
      return false;
    }
    try {
      final digest = await sha256.bind(File(status.filePath).openRead()).first;
      final installedSha256 = digest.toString();
      return selections.any(
        (selection) =>
            selection.release.sha256For(status.target) != installedSha256,
      );
    } on FileSystemException {
      return false;
    }
  }

  Future<List<_RuntimePackageDownloadSelection>>
  _runtimeDownloadSelectionsForInspection() async {
    late List<_RuntimePackageDownloadSelection> selections;
    try {
      selections = await _runtimeDownloadSelectionsForInspectionCached();
    } on Object {
      // 本地文件状态仍然可用；远端目录不可用时不误报可下载。
      return const [];
    }
    return _probeRuntimeDownloadSelections(selections);
  }

  Future<List<_RuntimePackageDownloadSelection>>
  _runtimeDownloadSelectionsForInspectionCached() async {
    final cached = _runtimeInspectionSelections;
    final cachedAt = _runtimeInspectionSelectionsAt;
    if (cached != null &&
        cachedAt != null &&
        _clock().difference(cachedAt) < _runtimeInspectionCacheDuration) {
      return cached;
    }
    final active = _runtimeInspectionSelectionsOperation;
    if (active != null) return active;
    final operation = _loadRuntimeDownloadSelections();
    _runtimeInspectionSelectionsOperation = operation;
    try {
      final selections = await operation;
      _runtimeInspectionSelections = selections;
      _runtimeInspectionSelectionsAt = _clock();
      return selections;
    } finally {
      if (identical(_runtimeInspectionSelectionsOperation, operation)) {
        _runtimeInspectionSelectionsOperation = null;
      }
    }
  }

  Future<List<_RuntimePackageDownloadSelection>>
  _probeRuntimeDownloadSelections(
    List<_RuntimePackageDownloadSelection> selections,
  ) async {
    if (selections.isEmpty) return const [];
    try {
      final addresses = <Uri>[];
      final addressKeys = <String>{};
      for (final selection in selections) {
        final address = selection.download.url!;
        if (addressKeys.add(normalizedEndpointProbeCacheKey(address))) {
          addresses.add(address);
        }
      }
      final probes = await runtimeDownloadProbeService.probeAll(addresses);
      final probesByAddress = <String, EndpointProbeResult>{
        for (final probe in probes)
          normalizedEndpointProbeCacheKey(probe.url): probe,
      };
      return List.unmodifiable([
        for (final selection in selections)
          selection.withProbe(
            probesByAddress[normalizedEndpointProbeCacheKey(
              selection.download.url!,
            )],
          ),
      ]);
    } on Object {
      // 测速失败不隐藏有效线路；前端仍允许用户明确选择并实际下载。
      return selections;
    }
  }

  @override
  Future<List<DeveloperInstallationPackageRelayServer>> inspectRelayServers() {
    _ensureOpen();
    return relayServerCatalog.inspect();
  }

  @override
  Future<DeveloperInstallationPackageArtifact> create({
    required GameSummary game,
    required String targetId,
    required bool refreshRuntime,
    String? runtimeDownloadId,
    bool autoApproveCapabilities = false,
    Uri? relayServer,
    DeveloperInstallationPackageProgressCallback? onProgress,
  }) {
    _ensureOpen();
    final operation = _createTail.then(
      (_) => _create(
        game: game,
        targetId: targetId,
        refreshRuntime: refreshRuntime,
        runtimeDownloadId: runtimeDownloadId,
        autoApproveCapabilities: autoApproveCapabilities,
        relayServer: relayServer,
        onProgress: onProgress,
      ),
    );
    _createTail = operation.then<void>((_) {}, onError: (error, stackTrace) {});
    return operation;
  }

  Future<DeveloperInstallationPackageArtifact> _create({
    required GameSummary game,
    required String targetId,
    required bool refreshRuntime,
    required String? runtimeDownloadId,
    required bool autoApproveCapabilities,
    required Uri? relayServer,
    required DeveloperInstallationPackageProgressCallback? onProgress,
  }) async {
    _ensureOpen();
    final target = RuntimePackageTarget.parse(targetId);
    _notifyInstallationPackageProgress(
      onProgress,
      const DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.runtimeCheck,
      ),
    );
    var status = await runtimePackages.inspectPackage(target);
    if (!status.installed || refreshRuntime) {
      status = await _downloadRuntime(
        target,
        force: refreshRuntime,
        selectedId: runtimeDownloadId,
        onProgress: onProgress,
      ).then((result) => result.status);
    }
    if (!status.installed) {
      throw const DeveloperInstallationPackageException(
        kind: DeveloperInstallationPackageFailureKind.targetUnavailable,
        code: 'runtime_package_not_installed',
        message: '所选 Runtime 底包尚未安装',
      );
    }

    _notifyInstallationPackageProgress(
      onProgress,
      const DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.packageBuild,
      ),
    );
    await _cleanupExpiredArtifacts();
    final exportId = _newExportId();
    final leaseDirectory = Directory(
      '${_artifactRoot.path}${Platform.pathSeparator}$exportId',
    );
    await leaseDirectory.create(recursive: true);
    final sourcePackage = File(
      '${leaseDirectory.path}${Platform.pathSeparator}source.playmesh.zip',
    );
    final clearPackage = File(
      '${leaseDirectory.path}${Platform.pathSeparator}game-runtime.zip',
    );
    File? validatedIcon;
    try {
      await packageTransfer.exportPackage(game, sourcePackage, validate: true);
      validatedIcon = await _buildClearRuntimePackage(
        sourcePackage: sourcePackage,
        destination: clearPackage,
        relayServer: relayServer,
        autoApproveCapabilities: autoApproveCapabilities,
        leaseDirectory: leaseDirectory,
      );
      final extension = target.platform == 'android' ? 'apk' : 'zip';
      final filename = _installationPackageFileName(game, extension);
      final output = File(
        '${leaseDirectory.path}${Platform.pathSeparator}$filename',
      );
      _notifyInstallationPackageProgress(
        onProgress,
        const DeveloperInstallationPackageProgress(
          stage: DeveloperInstallationPackageProgressStage.nativeExport,
        ),
      );
      RuntimeNativeExportReport report;
      if (target.platform == 'android') {
        final signingKey = await signingKeyProvider.load();
        report = await nativeExporter.exportAndroid(
          RuntimeAndroidNativeExportRequest(
            templateApkPath: status.filePath,
            clearGamePackagePath: clearPackage.path,
            outputApkPath: output.path,
            keystorePath: signingKey.path,
            storePassword: signingKey.storePassword,
            keyPassword: signingKey.keyPassword,
            keyAlias: signingKey.alias,
            gameId: game.id,
            applicationId: runtimeAndroidApplicationId(game.id),
            label: game.name,
            versionName: game.version,
            versionCode: runtimeAndroidVersionCode(game.version),
            iconPath: validatedIcon?.path,
          ),
        );
      } else {
        report = await nativeExporter.exportWindows(
          RuntimeWindowsNativeExportRequest(
            templateZipPath: status.filePath,
            clearGamePackagePath: clearPackage.path,
            outputZipPath: output.path,
            executableName: gameWindowsExecutableFileName(game.name),
            label: game.name,
            versionName: game.version,
            iconPath: validatedIcon?.path,
          ),
        );
      }
      if (File(report.outputPath).absolute.path != output.absolute.path ||
          !await output.exists()) {
        throw const FormatException('原生导出器没有生成约定的输出文件');
      }
      final size = await output.length();
      if (size <= 0 || size != report.sizeBytes) {
        throw const FormatException('原生导出器返回的文件长度无效');
      }
      final artifact = DeveloperInstallationPackageArtifact(
        id: exportId,
        projectId: game.id,
        filePath: output.path,
        filename: filename,
        mimeType: target.platform == 'android'
            ? 'application/vnd.android.package-archive'
            : 'application/zip',
        size: size,
      );
      _artifacts[exportId] = _InstallationArtifactLease(
        artifact: artifact,
        createdAt: _clock().toUtc(),
        directory: leaseDirectory,
      );
      await _deleteIfExists(sourcePackage);
      await _deleteIfExists(clearPackage);
      if (validatedIcon != null) await _deleteIfExists(validatedIcon);
      return artifact;
    } on DeveloperInstallationPackageException {
      await _deleteDirectoryIfExists(leaseDirectory);
      rethrow;
    } on Object catch (error) {
      await _deleteDirectoryIfExists(leaseDirectory);
      throw DeveloperInstallationPackageException(
        kind: DeveloperInstallationPackageFailureKind.exportFailed,
        code: 'installation_package_export_failed',
        message: '安装包生成失败',
        diagnostic: error.toString(),
      );
    }
  }

  Future<RuntimePackageInstallResult> _downloadRuntime(
    RuntimePackageTarget target, {
    required bool force,
    required String? selectedId,
    required DeveloperInstallationPackageProgressCallback? onProgress,
  }) async {
    if (selectedId == null) {
      throw const DeveloperInstallationPackageException(
        kind:
            DeveloperInstallationPackageFailureKind.runtimeDownloadUnavailable,
        code: 'runtime_package_download_selection_required',
        message: '请选择 Runtime 底包下载线路',
      );
    }
    List<_RuntimePackageDownloadSelection> selections;
    try {
      selections = await _loadRuntimeDownloadSelections();
    } on Object catch (error) {
      throw DeveloperInstallationPackageException(
        kind:
            DeveloperInstallationPackageFailureKind.runtimeDownloadUnavailable,
        code: 'runtime_package_sources_unavailable',
        message: 'Runtime 底包下载源不可用',
        diagnostic: error.toString(),
      );
    }
    final targetSelections = selections
        .where((selection) => selection.target == target)
        .toList(growable: false);
    if (targetSelections.isEmpty) {
      throw const DeveloperInstallationPackageException(
        kind:
            DeveloperInstallationPackageFailureKind.runtimeDownloadUnavailable,
        code: 'runtime_package_download_unavailable',
        message: '所选 Runtime 底包没有可用下载线路',
      );
    }
    final selection = targetSelections
        .where((candidate) => candidate.presentation().id == selectedId)
        .firstOrNull;
    if (selection == null) {
      throw const DeveloperInstallationPackageException(
        kind:
            DeveloperInstallationPackageFailureKind.runtimeDownloadUnavailable,
        code: 'runtime_package_download_selection_invalid',
        message: '所选 Runtime 底包下载线路已失效，请刷新后重选',
      );
    }
    final progress = _RuntimeDownloadProgressEmitter(
      callback: onProgress,
      clock: _clock,
    )..begin();
    try {
      final result = await runtimePackages.downloadPackage(
        target: target,
        release: selection.release,
        selectedDownload: selection.download,
        forceRedownload: force,
        onProgress: progress.add,
      );
      progress.verified();
      return result;
    } on Object catch (error) {
      throw DeveloperInstallationPackageException(
        kind: DeveloperInstallationPackageFailureKind.runtimeDownloadFailed,
        code: 'runtime_package_download_failed',
        message: 'Runtime 底包下载或 SHA-256 校验失败',
        diagnostic: error.toString(),
      );
    }
  }

  Future<List<_RuntimePackageDownloadSelection>>
  _loadRuntimeDownloadSelections() async {
    final sources = await runtimePackages.loadConfigSources();
    if (!sources.configured) return const [];
    final selections = <_RuntimePackageDownloadSelection>[];
    for (final source in sources.sources) {
      RuntimePackageReleaseManifest release;
      try {
        release = await runtimePackages.loadReleaseManifest(source);
      } on Object {
        continue;
      }
      for (final target in RuntimePackageTarget.values) {
        for (final download in release.downloadsFor(target)) {
          if (!download.downloadable) continue;
          selections.add(
            _RuntimePackageDownloadSelection(
              target: target,
              source: source,
              release: release,
              download: download,
            ),
          );
        }
      }
    }
    return List.unmodifiable(selections);
  }

  Future<File?> _buildClearRuntimePackage({
    required File sourcePackage,
    required File destination,
    required Uri? relayServer,
    required bool autoApproveCapabilities,
    required Directory leaseDirectory,
  }) async {
    final input = InputFileStream(sourcePackage.path);
    final encoder = ZipFileEncoder();
    var opened = false;
    File? icon;
    final mappedPaths = <String>{};
    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input, verify: false);
      // Archive keeps every ZipFile in its central-directory model. Detach
      // those references so an entry can be reclaimed immediately after it is
      // verified and rewritten, instead of retaining the whole expanded game
      // in memory on Android.
      decoder.directory.fileHeaders.clear();
      encoder.create(destination.path);
      opened = true;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final sourcePath = entry.name.replaceAll('\\', '/');
        String? targetPath;
        if (sourcePath == 'main.json' || sourcePath == 'capabilities.json') {
          targetPath = sourcePath;
        } else if (sourcePath == gamePackageIconName) {
          final data = _verifiedArchiveBytes(entry);
          icon = File(
            '${leaseDirectory.path}${Platform.pathSeparator}validated-icon.png',
          );
          await icon.writeAsBytes(data, flush: true);
          entry.clear();
          continue;
        } else if (sourcePath.startsWith('app/')) {
          targetPath = sourcePath.substring(4);
        } else {
          throw FormatException('标准游戏包包含未知路径: $sourcePath');
        }
        _validateRuntimePath(targetPath);
        if (targetPath == 'playmesh-runtime.json') {
          throw const FormatException('游戏项目不得内置 Runtime 导出配置');
        }
        if (!mappedPaths.add(targetPath)) {
          throw FormatException('游戏文件扁平化后发生路径冲突: $targetPath');
        }
        final data = _verifiedArchiveBytes(entry);
        encoder.addArchiveFile(ArchiveFile(targetPath, data.length, data));
        entry.clear();
      }
      if (!mappedPaths.contains('main.json')) {
        throw const FormatException('Runtime 游戏包缺少 main.json');
      }
      if (!mappedPaths.add('playmesh-runtime.json')) {
        throw const FormatException('游戏项目占用 playmesh-runtime.json');
      }
      final data = utf8.encode(
        '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, if (relayServer != null) 'relayServer': relayServer.toString(), 'autoApproveCapabilities': autoApproveCapabilities})}\n',
      );
      encoder.addArchiveFile(
        ArchiveFile('playmesh-runtime.json', data.length, data),
      );
      await encoder.close();
      opened = false;
      return icon;
    } finally {
      if (opened) {
        try {
          await encoder.close();
        } on Object {
          // 保留原始转换错误。
        }
      }
      await input.close();
      if (opened) await _deleteIfExists(destination);
    }
  }

  @override
  DeveloperInstallationPackageArtifact? find(String exportId) {
    if (_closed) return null;
    final lease = _artifacts[exportId];
    if (lease == null) return null;
    if (_clock().toUtc().difference(lease.createdAt) > artifactLifetime) {
      _artifacts.remove(exportId);
      unawaited(_deleteDirectoryIfExists(lease.directory));
      return null;
    }
    return lease.artifact;
  }

  @override
  Future<void> release(String exportId) async {
    final lease = _artifacts.remove(exportId);
    if (lease != null) await _deleteDirectoryIfExists(lease.directory);
  }

  Future<void> _cleanupExpiredArtifacts() async {
    await _artifactRoot.create(recursive: true);
    final cutoff = _clock().toUtc().subtract(artifactLifetime);
    final knownDirectories = <String>{};
    for (final entry in _artifacts.entries.toList()) {
      knownDirectories.add(entry.value.directory.absolute.path);
      if (entry.value.createdAt.isBefore(cutoff)) {
        _artifacts.remove(entry.key);
        await _deleteDirectoryIfExists(entry.value.directory);
      }
    }
    await for (final entity in _artifactRoot.list(followLinks: false)) {
      if (entity is! Directory ||
          knownDirectories.contains(entity.absolute.path)) {
        continue;
      }
      try {
        if ((await entity.stat()).modified.toUtc().isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      } on Object {
        // 只清理由本服务创建且已经过期的孤儿目录。
      }
    }
  }

  @override
  Future<void> close() => _closeOperation ??= _close();

  Future<void> _close() async {
    _closed = true;
    // 允许已进入原生导出的任务完成，再关闭下载器并清理
    // 它可能刚刚注册的产物。新 create 已被 _closed 同步拒绝。
    await _createTail;
    runtimePackages.close();
    if (_ownsRuntimeDownloadProbeService) runtimeDownloadProbeService.close();
    final leases = _artifacts.values.toList();
    _artifacts.clear();
    for (final lease in leases) {
      await _deleteDirectoryIfExists(lease.directory);
    }
  }

  String _newExportId() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  void _ensureOpen() {
    if (_closed) throw StateError('安装包导出服务已经关闭');
  }
}

final class _RuntimeDownloadProgressEmitter {
  _RuntimeDownloadProgressEmitter({
    required this.callback,
    required this.clock,
  });

  static const _minimumByteDelta = 256 * 1024;
  static const _maximumSilence = Duration(milliseconds: 100);

  final DeveloperInstallationPackageProgressCallback? callback;
  final DateTime Function() clock;
  RuntimePackageDownloadProgress? _latest;
  int? _lastEmittedBytes;
  int? _lastIntegerPercent;
  int? _lastTotalBytes;
  DateTime? _lastEmittedAt;

  void begin() {
    _emit(
      const RuntimePackageDownloadProgress(receivedBytes: 0, totalBytes: null),
    );
  }

  void add(RuntimePackageDownloadProgress progress) {
    _latest = progress;
    final fraction = progress.fraction;
    final integerPercent = fraction == null
        ? null
        : (fraction * 100).floor().clamp(0, 100);
    final lastBytes = _lastEmittedBytes;
    final lastAt = _lastEmittedAt;
    final now = clock().toUtc();
    final completed =
        progress.totalBytes != null &&
        progress.totalBytes! > 0 &&
        progress.receivedBytes >= progress.totalBytes!;
    final changed =
        progress.receivedBytes != lastBytes ||
        progress.totalBytes != _lastTotalBytes;
    final shouldEmit =
        lastBytes == null ||
        progress.totalBytes != _lastTotalBytes ||
        integerPercent != _lastIntegerPercent ||
        progress.receivedBytes - lastBytes >= _minimumByteDelta ||
        (lastAt != null && now.difference(lastAt) >= _maximumSilence) ||
        (completed && changed);
    if (shouldEmit) _emit(progress, now: now);
  }

  void verified() {
    final latest = _latest;
    _notifyInstallationPackageProgress(
      callback,
      DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.runtimeVerified,
        receivedBytes: latest?.receivedBytes,
        totalBytes: latest?.totalBytes,
      ),
    );
  }

  void _emit(RuntimePackageDownloadProgress progress, {DateTime? now}) {
    _latest = progress;
    _lastEmittedBytes = progress.receivedBytes;
    _lastTotalBytes = progress.totalBytes;
    final fraction = progress.fraction;
    _lastIntegerPercent = fraction == null
        ? null
        : (fraction * 100).floor().clamp(0, 100);
    _lastEmittedAt = (now ?? clock()).toUtc();
    _notifyInstallationPackageProgress(
      callback,
      DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.runtimeDownload,
        receivedBytes: progress.receivedBytes,
        totalBytes: progress.totalBytes,
      ),
    );
  }
}

final class _RuntimePackageDownloadSelection {
  _RuntimePackageDownloadSelection({
    required this.target,
    required this.source,
    required this.release,
    required this.download,
    this.probe,
  });

  final RuntimePackageTarget target;
  final NamedDownloadEndpoint source;
  final RuntimePackageReleaseManifest release;
  final RuntimePackageDownloadEndpoint download;
  final EndpointProbeResult? probe;

  DeveloperInstallationPackageRuntimeDownload presentation({
    EndpointProbeState fallbackProbeState = EndpointProbeState.unsupported,
  }) => DeveloperInstallationPackageRuntimeDownload(
    id: sha256
        .convert(
          utf8.encode(
            jsonEncode([
              source.name,
              source.url.toString(),
              target.id,
              release.version,
              release.sha256For(target),
              download.name,
              download.urlValue,
            ]),
          ),
        )
        .toString(),
    name: download.name,
    address: download.url!,
    manifestSourceId: sha256
        .convert(
          utf8.encode(
            jsonEncode([
              source.name,
              source.url.toString(),
              target.id,
              release.version,
              release.sha256For(target),
            ]),
          ),
        )
        .toString(),
    manifestSourceName: source.name,
    manifestSourceAddress: source.url,
    probeState: probe?.state ?? fallbackProbeState,
    latencyMs: probe?.latencyMs,
  );

  _RuntimePackageDownloadSelection withProbe(EndpointProbeResult? value) =>
      _RuntimePackageDownloadSelection(
        target: target,
        source: source,
        release: release,
        download: download,
        probe: value,
      );
}

void _notifyInstallationPackageProgress(
  DeveloperInstallationPackageProgressCallback? callback,
  DeveloperInstallationPackageProgress progress,
) {
  if (callback == null) return;
  try {
    callback(progress);
  } on Object {
    // 进度只用于观测；监听器异常不能中断底包下载、签名或产物清理。
  }
}

final class _InstallationArtifactLease {
  const _InstallationArtifactLease({
    required this.artifact,
    required this.createdAt,
    required this.directory,
  });

  final DeveloperInstallationPackageArtifact artifact;
  final DateTime createdAt;
  final Directory directory;
}

String runtimeAndroidApplicationId(String gameId) {
  final segments = <String>[];
  for (final rawSegment in gameId.trim().split('.')) {
    final buffer = StringBuffer();
    for (final codeUnit in rawSegment.codeUnits) {
      if (_isAsciiLetter(codeUnit) ||
          (codeUnit >= 0x30 && codeUnit <= 0x39) ||
          codeUnit == 0x5f) {
        buffer.writeCharCode(codeUnit);
      }
    }
    var segment = buffer.toString();
    if (segment.isEmpty) continue;
    if (!_isAsciiLetter(segment.codeUnitAt(0))) segment = 'g$segment';
    segments.add(segment);
  }
  if (segments.isEmpty) {
    throw const FormatException('游戏 ID 无法转换为有效的 Android 包名');
  }
  if (segments.length == 1) segments.insert(0, 'playmesh');
  final applicationId = segments.join('.');
  if (applicationId.length > 255) {
    throw const FormatException('格式化后的 Android 包名超过 255 字符');
  }
  return applicationId;
}

bool _isAsciiLetter(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a);

int runtimeAndroidVersionCode(String version) {
  final match = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
  ).firstMatch(version);
  if (match == null) throw const FormatException('游戏版本必须是 MAJOR.MINOR.PATCH');
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  final patch = int.parse(match.group(3)!);
  if (major > 2099 || minor > 999 || patch > 999) {
    throw const FormatException('游戏版本超出 Android versionCode 可表示范围');
  }
  final value = major * 1000000 + minor * 1000 + patch;
  return value == 0 ? 1 : value;
}

String _installationPackageFileName(GameSummary game, String extension) {
  final source = gamePackageFileName(name: game.name, version: game.version);
  return '${source.substring(0, source.length - 4)}.$extension';
}

Uint8List _archiveBytes(Object? content) {
  if (content is Uint8List) return content;
  if (content is List<int>) return Uint8List.fromList(content);
  return Uint8List.fromList(List<int>.from(content as Iterable));
}

Uint8List _verifiedArchiveBytes(ArchiveFile entry) {
  final data = _archiveBytes(entry.content);
  if (entry.crc32 == null || getCrc32(data) != entry.crc32) {
    throw FormatException('游戏包文件 CRC 校验失败: ${entry.name}');
  }
  return data;
}

void _validateRuntimePath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.contains('\\') ||
      value.contains('%') ||
      value.contains('?') ||
      value.contains('#') ||
      value
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('Runtime 游戏包路径无效: $value');
  }
  final first = value.split('/').first.toLowerCase();
  if (first == 'playmesh' || first == 'bucket') {
    throw FormatException('Runtime 游戏包占用平台目录: $value');
  }
}

bool _constantBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) await file.delete();
}

Future<void> _deleteDirectoryIfExists(Directory directory) async {
  if (await directory.exists()) await directory.delete(recursive: true);
}
