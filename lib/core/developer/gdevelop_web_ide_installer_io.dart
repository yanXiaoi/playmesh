import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../download/safe_zip_extractor_contract.dart';
import '../download/safe_zip_extractor_io.dart';
import '../download/verified_resumable_download_contract.dart';
import 'gdevelop_ai_project_context.dart';
import 'gdevelop_ai_tool_registry.dart';
import 'gdevelop_web_ide_installer_contract.dart';

GDevelopWebIdeInstaller createGDevelopWebIdeInstaller() =>
    FileGDevelopWebIdeInstaller();

class FileGDevelopWebIdeInstaller implements GDevelopWebIdeInstaller {
  FileGDevelopWebIdeInstaller({
    SafeZipExtractor? zipExtractor,
    DateTime Function()? clock,
    Future<Directory> Function(Directory source, String destination)?
    renameDirectory,
  }) : zipExtractor = zipExtractor ?? const IoSafeZipExtractor(),
       clock = clock ?? DateTime.now,
       renameDirectory = renameDirectory ?? _renameDirectory;

  static const installedMarkerName = '.playmesh-installed.json';
  static const _journalName = 'official-install.json';
  static const _backupName = '.official-backup';
  static const _lockName = '.official-install.lock';
  static const _journalSchemaVersion = 1;
  static const _noticesName = 'THIRD_PARTY_NOTICES.md';
  static const aiToolsPath = 'playmesh/ai/tools.json';
  static const _maxNoticesBytes = 4 * 1024 * 1024;
  static final Set<String> _activeInstallRoots = {};
  static final Map<String, Future<void>> _rootOperationTails = {};

  final SafeZipExtractor zipExtractor;
  final DateTime Function() clock;
  final Future<Directory> Function(Directory source, String destination)
  renameDirectory;

  @override
  Future<GDevelopWebIdeInstallationInspection> inspect({
    required String gdevelopRootPath,
  }) => _withFileLock(gdevelopRootPath, () async {
    final root = Directory(gdevelopRootPath).absolute;
    await root.create(recursive: true);
    await _recoverUnlocked(root);
    return _inspectOfficial(_official(root));
  });

  @override
  Future<void> recover({required String gdevelopRootPath}) =>
      _withFileLock(gdevelopRootPath, () async {
        final root = Directory(gdevelopRootPath).absolute;
        await root.create(recursive: true);
        await _recoverUnlocked(root);
      });

  @override
  Future<GDevelopWebIdeInstalledAiTools> loadInstalledAiTools({
    required String gdevelopRootPath,
  }) async {
    try {
      return await _withFileLock(gdevelopRootPath, () async {
        final root = Directory(gdevelopRootPath).absolute;
        await root.create(recursive: true);
        await _recoverUnlocked(root);
        final official = _official(root);
        final inspected = await _inspectOfficialWithAiTools(official);
        final inspection = inspected.inspection;
        final marker = inspection.marker;
        if (inspection.state != GDevelopWebIdeInstallationState.ready ||
            marker == null ||
            inspected.aiTools == null) {
          throw GDevelopWebIdeInstallException(
            inspection.diagnostic ?? 'gdevelop_webide_not_installed',
          );
        }
        return GDevelopWebIdeInstalledAiTools(
          marker: marker,
          registry: inspected.aiTools!.registry,
        );
      });
    } on GDevelopWebIdeInstallException {
      rethrow;
    } on FileSystemException {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_install_io_unavailable',
      );
    }
  }

  @override
  Future<GDevelopWebIdeInstallResult> install({
    required GDevelopWebIdeInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) async {
    _validateSpec(spec);
    return _installArchive(
      gdevelopRootPath: spec.gdevelopRootPath,
      archivePath: spec.archivePath,
      sha256: spec.sha256,
      size: spec.size,
      expectedVersion: spec.version,
      allowSingleRootDirectory: false,
      installationKind: GDevelopWebIdeInstallationKind.release,
      cancellationToken: cancellationToken,
      deleteArchiveOnSuccess: deleteArchiveOnSuccess,
    );
  }

  @override
  Future<GDevelopWebIdeInstallResult> installLocalArchive({
    required GDevelopWebIdeLocalInstallSpec spec,
    DownloadCancellationToken? cancellationToken,
    bool deleteArchiveOnSuccess = true,
  }) async {
    if (spec.size <= 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(spec.sha256)) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_archive_identity_invalid',
      );
    }
    return _installArchive(
      gdevelopRootPath: spec.gdevelopRootPath,
      archivePath: spec.archivePath,
      sha256: spec.sha256,
      size: spec.size,
      expectedVersion: null,
      allowSingleRootDirectory: true,
      installationKind: GDevelopWebIdeInstallationKind.userProvided,
      cancellationToken: cancellationToken,
      deleteArchiveOnSuccess: deleteArchiveOnSuccess,
    );
  }

  Future<GDevelopWebIdeInstallResult> _installArchive({
    required String gdevelopRootPath,
    required String archivePath,
    required String sha256,
    required int size,
    required String? expectedVersion,
    required bool allowSingleRootDirectory,
    required GDevelopWebIdeInstallationKind installationKind,
    required DownloadCancellationToken? cancellationToken,
    required bool deleteArchiveOnSuccess,
  }) async {
    final rootKey = _pathKey(Directory(gdevelopRootPath).absolute.path);
    if (!_activeInstallRoots.add(rootKey)) {
      throw const GDevelopWebIdeInstallBusyException();
    }
    try {
      return await _withFileLock(gdevelopRootPath, () async {
        final root = Directory(gdevelopRootPath).absolute;
        await root.create(recursive: true);
        await _recoverUnlocked(root);
        cancellationToken?.throwIfCancellationRequested();
        final archive = File(archivePath);
        final expectedArchive = File(
          '${root.path}${Platform.pathSeparator}downloads'
          '${Platform.pathSeparator}$sha256.zip',
        ).absolute;
        if (_pathKey(archive.absolute.path) != _pathKey(expectedArchive.path)) {
          throw const GDevelopWebIdeInstallException(
            'gdevelop_archive_path_invalid',
          );
        }
        if (!await archive.exists() ||
            await archive.length() != size ||
            await _sha256(archive) != sha256) {
          throw const GDevelopWebIdeInstallException(
            'gdevelop_archive_identity_mismatch',
          );
        }
        final stagingName =
            '.official-staging-${clock().toUtc().microsecondsSinceEpoch}'
            '-${pid.toString()}';
        final staging = Directory(
          '${root.path}${Platform.pathSeparator}$stagingName',
        );
        final journalFile = _journal(root);
        var journalWritten = false;
        var committed = false;
        try {
          await zipExtractor.extract(
            archivePath: archive.path,
            destinationPath: staging.path,
            cancellationToken: cancellationToken,
          );
          cancellationToken?.throwIfCancellationRequested();
          if (allowSingleRootDirectory) {
            await _normalizeSingleRootDirectory(staging);
          }
          if (installationKind == GDevelopWebIdeInstallationKind.release) {
            await _validateIntegration(staging, expectedVersion);
          } else {
            await _validateUserProvidedRuntime(staging);
          }
          final noticesSha256 = await _validateNotices(staging);
          final aiTools = await _loadAiTools(staging);
          final version =
              installationKind == GDevelopWebIdeInstallationKind.release
              ? expectedVersion!
              : await _userProvidedVersion(staging, aiTools.registry);
          final marker = GDevelopWebIdeInstalledMarker(
            version: version,
            sha256: sha256,
            noticesSha256: noticesSha256,
            aiToolsPath: aiToolsPath,
            aiToolsSha256: aiTools.rawSha256,
            aiToolsContractHash: aiTools.registry.contractHash,
            size: size,
            installedAt: clock().toUtc(),
            installationKind: installationKind,
          );
          await _writeMarker(staging, marker);
          final stagedInspection = await _inspectOfficial(staging);
          if (stagedInspection.state != GDevelopWebIdeInstallationState.ready ||
              !stagedInspection.matches(
                version: version,
                sha256: sha256,
                size: size,
              )) {
            throw const GDevelopWebIdeInstallException(
              'gdevelop_staging_identity_invalid',
            );
          }

          var journal = _InstallJournal(
            phase: _InstallPhase.prepared,
            stagingName: stagingName,
            version: version,
            sha256: sha256,
            size: size,
          );
          await _writeJournal(journalFile, journal);
          journalWritten = true;
          final official = _official(root);
          final backup = _backup(root);
          if (await backup.exists()) await backup.delete(recursive: true);
          if (await official.exists()) {
            await renameDirectory(official, backup.path);
          }
          journal = journal.withPhase(_InstallPhase.backupMoved);
          await _writeJournal(journalFile, journal);
          await renameDirectory(staging, official.path);
          journal = journal.withPhase(_InstallPhase.installed);
          await _writeJournal(journalFile, journal);

          final installed = await _inspectOfficial(official);
          if (installed.state != GDevelopWebIdeInstallationState.ready ||
              !installed.matches(
                version: version,
                sha256: sha256,
                size: size,
              )) {
            throw const GDevelopWebIdeInstallException(
              'gdevelop_installed_identity_invalid',
            );
          }
          if (await backup.exists()) await backup.delete(recursive: true);
          if (await journalFile.exists()) await journalFile.delete();
          committed = true;
          await _deleteStaleStaging(root);
          if (deleteArchiveOnSuccess && await archive.exists()) {
            try {
              await archive.delete();
            } on Object {
              // 已验证的事务缓存可在下一次运行时清理。
            }
          }
          return GDevelopWebIdeInstallResult(marker: installed.marker!);
        } on Object {
          if (journalWritten && !committed) {
            await _rollbackUnlocked(root, staging);
          } else if (await staging.exists()) {
            await staging.delete(recursive: true);
          }
          rethrow;
        }
      });
    } finally {
      _activeInstallRoots.remove(rootKey);
    }
  }

  Future<void> _recoverUnlocked(Directory root) async {
    final journalFile = _journal(root);
    final temporaryJournal = File('${journalFile.path}.tmp');
    if (await temporaryJournal.exists()) await temporaryJournal.delete();
    final official = _official(root);
    final backup = _backup(root);
    final journal = await _readJournal(journalFile);
    if (journal == null) {
      if (!await official.exists() && await backup.exists()) {
        await renameDirectory(backup, official.path);
      } else if (await official.exists() && await backup.exists()) {
        final inspection = await _inspectOfficial(official);
        if (inspection.state == GDevelopWebIdeInstallationState.ready) {
          await backup.delete(recursive: true);
        } else {
          await _restoreBackup(official, backup);
        }
      }
      if (await journalFile.exists()) await journalFile.delete();
      await _deleteStaleStaging(root);
      return;
    }

    final staging = Directory(
      '${root.path}${Platform.pathSeparator}${journal.stagingName}',
    );
    final officialMatches =
        await official.exists() && await _matchesJournal(official, journal);
    if (officialMatches) {
      if (await backup.exists()) await backup.delete(recursive: true);
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await journalFile.exists()) await journalFile.delete();
      return;
    }

    if (journal.phase == _InstallPhase.backupMoved &&
        !await official.exists() &&
        await staging.exists()) {
      try {
        await renameDirectory(staging, official.path);
        if (await _matchesJournal(official, journal)) {
          if (await backup.exists()) await backup.delete(recursive: true);
          if (await journalFile.exists()) await journalFile.delete();
          return;
        }
      } on Object {
        // 后续恢复原来的 official 目录。
      }
    }
    if (await backup.exists()) {
      await _restoreBackup(official, backup);
    } else if (await official.exists() &&
        !await _matchesJournal(official, journal)) {
      // 没有已知完好的备份，因此保留现有目录。
    }
    if (await staging.exists()) await staging.delete(recursive: true);
    if (await journalFile.exists()) await journalFile.delete();
    await _deleteStaleStaging(root);
  }

  Future<void> _rollbackUnlocked(Directory root, Directory staging) async {
    final official = _official(root);
    final backup = _backup(root);
    if (await backup.exists()) {
      await _restoreBackup(official, backup);
    } else if (await official.exists()) {
      // 首次安装可能在 staging 提升后失败；没有旧安装可恢复时，
      // 回滚到最初的未安装状态。
      await official.delete(recursive: true);
    }
    if (await staging.exists()) await staging.delete(recursive: true);
    final journal = _journal(root);
    if (await journal.exists()) await journal.delete();
    final temporaryJournal = File('${journal.path}.tmp');
    if (await temporaryJournal.exists()) await temporaryJournal.delete();
    await _deleteStaleStaging(root);
  }

  Future<GDevelopWebIdeInstallationInspection> _inspectOfficial(
    Directory official,
  ) async => (await _inspectOfficialWithAiTools(official)).inspection;

  Future<
    ({GDevelopWebIdeInstallationInspection inspection, _LoadedAiTools? aiTools})
  >
  _inspectOfficialWithAiTools(Directory official) async {
    final type = await FileSystemEntity.type(official.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (
        inspection: const GDevelopWebIdeInstallationInspection(
          state: GDevelopWebIdeInstallationState.absent,
        ),
        aiTools: null,
      );
    }
    if (type != FileSystemEntityType.directory) {
      return (
        inspection: const GDevelopWebIdeInstallationInspection(
          state: GDevelopWebIdeInstallationState.needsRepair,
          diagnostic: 'gdevelop_official_not_directory',
        ),
        aiTools: null,
      );
    }
    try {
      final marker = await _readMarker(official);
      if (marker.installationKind == GDevelopWebIdeInstallationKind.release) {
        await _validateIntegration(official, marker.version);
      } else {
        await _validateUserProvidedRuntime(official);
      }
      await _validateNotices(official, expectedSha256: marker.noticesSha256);
      final aiTools = await _loadAiTools(
        official,
        expectedPath: marker.aiToolsPath,
        expectedSha256: marker.aiToolsSha256,
        expectedContractHash: marker.aiToolsContractHash,
      );
      return (
        inspection: GDevelopWebIdeInstallationInspection(
          state: GDevelopWebIdeInstallationState.ready,
          marker: marker,
        ),
        aiTools: aiTools,
      );
    } on Object catch (error) {
      return (
        inspection: GDevelopWebIdeInstallationInspection(
          state: GDevelopWebIdeInstallationState.needsRepair,
          diagnostic: error is GDevelopWebIdeInstallException
              ? error.diagnostic
              : error is FileSystemException
              ? 'gdevelop_install_io_unavailable'
              : 'gdevelop_install_identity_invalid',
        ),
        aiTools: null,
      );
    }
  }

  Future<String> _validateIntegration(
    Directory root,
    String? expectedVersion,
  ) async {
    final index = File('${root.path}${Platform.pathSeparator}index.html');
    final integration = File(
      '${root.path}${Platform.pathSeparator}playmesh-integration.json',
    );
    final buildProvenance = File(
      '${root.path}${Platform.pathSeparator}playmesh-build-provenance.json',
    );
    final notices = File('${root.path}${Platform.pathSeparator}$_noticesName');
    for (final file in [index, integration, buildProvenance, notices]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const GDevelopWebIdeInstallException(
          'gdevelop_required_file_missing',
        );
      }
    }
    if (await index.length() <= 0 ||
        await integration.length() <= 0 ||
        await integration.length() > 64 * 1024 ||
        await buildProvenance.length() <= 0 ||
        await buildProvenance.length() > 64 * 1024) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_required_file_invalid',
      );
    }
    final decoded = jsonDecode(await integration.readAsString());
    final decodedBuild = jsonDecode(await buildProvenance.readAsString());
    const baseKeys = <String>{
      'policyRevision',
      'upstreamTag',
      'upstreamCommit',
      'upstreamSourceArchiveSha256',
      'sourcePolicyManifestSha256',
      'sourcePolicyOverlayTreeSha256',
      'sourcePolicyGeneratedFilesSha256',
      'sourcePolicyPatchedOfficialFilesSha256',
      'patchedSourceSha256',
    };
    const digestKeys = <String>{
      'upstreamSourceArchiveSha256',
      'sourcePolicyManifestSha256',
      'sourcePolicyOverlayTreeSha256',
      'sourcePolicyGeneratedFilesSha256',
      'sourcePolicyPatchedOfficialFilesSha256',
      'patchedSourceSha256',
      'buildTreeSha256',
    };
    final sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
    final markerKeys = <String>{
      'schemaVersion',
      'artifactKind',
      ...baseKeys,
      'buildTreeSha256',
      'preparedTreeSha256',
      'libGdProvenance',
      'sourcePolicyScript',
      'buildAuditScript',
      'packagePolicyScript',
    };
    final buildKeys = <String>{
      'schemaVersion',
      'artifactKind',
      ...baseKeys,
      'buildTreeSha256',
      'libGdProvenance',
      'sourcePolicyScript',
      'buildAuditScript',
    };
    final markerLibGdProvenance = decoded is Map
        ? decoded['libGdProvenance']
        : null;
    final buildLibGdProvenance = decodedBuild is Map
        ? decodedBuild['libGdProvenance']
        : null;
    // Schema 3 有意拒绝旧的 marker-only schema 2。B 例外也是证明链的
    // 必填部分，不能作为安装器可忽略的扩展字段。
    if (decoded is! Map ||
        decodedBuild is! Map ||
        !_hasExactKeys(decoded, markerKeys) ||
        !_hasExactKeys(decodedBuild, buildKeys) ||
        decoded['schemaVersion'] != 3 ||
        decoded['artifactKind'] != 'playmesh-gdevelop-webide-prepared' ||
        decodedBuild['schemaVersion'] != 1 ||
        decodedBuild['artifactKind'] != 'playmesh-gdevelop-webide-build' ||
        !_isValidLibGdProvenance(markerLibGdProvenance, sha256Pattern) ||
        !_isValidLibGdProvenance(buildLibGdProvenance, sha256Pattern) ||
        !_deepJsonEquals(markerLibGdProvenance, buildLibGdProvenance) ||
        decoded['policyRevision'] is! int ||
        (decoded['policyRevision']! as int) <= 0 ||
        decodedBuild['policyRevision'] != decoded['policyRevision'] ||
        decoded['upstreamTag'] is! String ||
        !RegExp(
          r'^v[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
        ).hasMatch(decoded['upstreamTag']! as String) ||
        (expectedVersion != null &&
            decoded['upstreamTag'] != 'v$expectedVersion') ||
        decodedBuild['upstreamTag'] != decoded['upstreamTag'] ||
        (markerLibGdProvenance! as Map)['upstreamVersion'] !=
            (decoded['upstreamTag']! as String).substring(1) ||
        decoded['upstreamCommit'] is! String ||
        !RegExp(
          r'^[a-f0-9]{40}$',
        ).hasMatch(decoded['upstreamCommit']! as String) ||
        decodedBuild['upstreamCommit'] != decoded['upstreamCommit'] ||
        digestKeys.any(
          (key) =>
              decoded[key] is! String ||
              !sha256Pattern.hasMatch(decoded[key]! as String) ||
              decodedBuild[key] != decoded[key],
        ) ||
        decoded['preparedTreeSha256'] is! String ||
        !sha256Pattern.hasMatch(decoded['preparedTreeSha256']! as String) ||
        decoded['sourcePolicyScript'] !=
            'playmesh/scripts/apply-source-policy.mjs' ||
        decodedBuild['sourcePolicyScript'] != decoded['sourcePolicyScript'] ||
        decoded['buildAuditScript'] !=
            'playmesh/tests/test-production-build-audit.mjs' ||
        decodedBuild['buildAuditScript'] != decoded['buildAuditScript'] ||
        decoded['packagePolicyScript'] !=
            'playmesh/scripts/prepare-webide.mjs') {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_integration_identity_mismatch',
      );
    }
    return (decoded['upstreamTag']! as String).substring(1);
  }

  Future<void> _validateUserProvidedRuntime(Directory root) async {
    final index = File('${root.path}${Platform.pathSeparator}index.html');
    if (await FileSystemEntity.type(index.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await index.length() <= 0) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_required_file_missing',
      );
    }
  }

  Future<String> _userProvidedVersion(
    Directory root,
    GDevelopAiToolRegistry registry,
  ) async {
    final integration = File(
      '${root.path}${Platform.pathSeparator}playmesh-integration.json',
    );
    try {
      if (await integration.exists()) {
        final decoded = jsonDecode(await integration.readAsString());
        final tag = decoded is Map ? decoded['upstreamTag'] : null;
        if (tag is String &&
            RegExp(r'^v[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(tag)) {
          return tag.substring(1);
        }
      }
    } on Object {
      // User-provided packages do not need Playmesh release provenance.
    }
    final reported = registry.contractJson()['gdevelopVersion'];
    if (reported is String &&
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(reported)) {
      return reported;
    }
    return 'custom';
  }

  Future<String> _validateNotices(
    Directory root, {
    String? expectedSha256,
  }) async {
    final notices = File('${root.path}${Platform.pathSeparator}$_noticesName');
    if (await FileSystemEntity.type(notices.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_missing',
      );
    }
    final length = await notices.length();
    if (length <= 0 || length > _maxNoticesBytes) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_invalid',
      );
    }
    final actualSha256 = await _sha256(notices);
    if (expectedSha256 != null && actualSha256 != expectedSha256) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_distribution_notices_identity_mismatch',
      );
    }
    return actualSha256;
  }

  Future<_LoadedAiTools> _loadAiTools(
    Directory root, {
    String? expectedPath,
    String? expectedSha256,
    String? expectedContractHash,
  }) async {
    if (expectedPath != null && expectedPath != aiToolsPath) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_ai_tools_path_invalid',
      );
    }
    final file = File(
      '${root.path}${Platform.pathSeparator}'
      '${aiToolsPath.replaceAll('/', Platform.pathSeparator)}',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GDevelopWebIdeInstallException('gdevelop_ai_tools_missing');
    }
    try {
      final bytes = await file.readAsBytes();
      final rawSha256 = await _sha256Bytes(bytes);
      if (expectedSha256 != null && rawSha256 != expectedSha256) {
        throw const GDevelopWebIdeInstallException(
          'gdevelop_ai_tools_identity_mismatch',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map) {
        throw const GDevelopWebIdeInstallException('gdevelop_ai_tools_invalid');
      }
      final contract = Map<String, Object?>.from(decoded);
      final capabilities = await GDevelopAiProjectContext.capabilitiesReference(
        contract,
      );
      final registry = GDevelopAiToolRegistry.fromContract(
        contract,
        contractHash: capabilities['contractHash']! as String,
      );
      if (expectedContractHash != null &&
          registry.contractHash != expectedContractHash) {
        throw const GDevelopWebIdeInstallException(
          'gdevelop_ai_tools_contract_identity_mismatch',
        );
      }
      return _LoadedAiTools(rawSha256: rawSha256, registry: registry);
    } on GDevelopWebIdeInstallException {
      rethrow;
    } on GDevelopAiToolValidationException catch (error) {
      throw GDevelopWebIdeInstallException(
        error.code == 'unsupported_tool_execution_kind'
            ? 'incompatible_ai_tools'
            : 'gdevelop_ai_tools_invalid',
      );
    } on FileSystemException {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_install_io_unavailable',
      );
    } on Object {
      throw const GDevelopWebIdeInstallException('gdevelop_ai_tools_invalid');
    }
  }

  Future<void> _normalizeSingleRootDirectory(Directory staging) async {
    if (await _hasUserRuntimeRoot(staging)) return;
    final entries = await staging.list(followLinks: false).toList();
    if (entries.length != 1 || entries.single is! Directory) return;
    final nested = entries.single as Directory;
    if (!await _hasUserRuntimeRoot(nested)) return;
    final normalized = Directory('${staging.path}.normalized');
    if (await normalized.exists()) await normalized.delete(recursive: true);
    await renameDirectory(nested, normalized.path);
    await staging.delete(recursive: true);
    await renameDirectory(normalized, staging.path);
  }

  Future<bool> _hasUserRuntimeRoot(Directory root) async {
    final index = File('${root.path}${Platform.pathSeparator}index.html');
    final tools = File(
      '${root.path}${Platform.pathSeparator}'
      '${aiToolsPath.replaceAll('/', Platform.pathSeparator)}',
    );
    return await index.exists() && await tools.exists();
  }

  Future<GDevelopWebIdeInstalledMarker> _readMarker(Directory root) async {
    final file = File(
      '${root.path}${Platform.pathSeparator}$installedMarkerName',
    );
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const GDevelopWebIdeInstallException('gdevelop_marker_missing');
    }
    if (await file.length() <= 0 || await file.length() > 16 * 1024) {
      throw const GDevelopWebIdeInstallException('gdevelop_marker_invalid');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        !_hasExactKeys(decoded, const {
          'schemaVersion',
          'version',
          'sha256',
          'noticesSha256',
          'aiToolsPath',
          'aiToolsSha256',
          'aiToolsContractHash',
          'size',
          'installedAt',
          'installationKind',
        }) ||
        decoded['schemaVersion'] != 3 ||
        decoded['version'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
        ).hasMatch(decoded['version']! as String) ||
        decoded['sha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['sha256']! as String) ||
        decoded['noticesSha256'] is! String ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(decoded['noticesSha256']! as String) ||
        decoded['aiToolsPath'] != aiToolsPath ||
        decoded['aiToolsSha256'] is! String ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(decoded['aiToolsSha256']! as String) ||
        decoded['aiToolsContractHash'] is! String ||
        !RegExp(
          r'^[a-f0-9]{64}$',
        ).hasMatch(decoded['aiToolsContractHash']! as String) ||
        decoded['size'] is! int ||
        (decoded['size']! as int) <= 0 ||
        decoded['installedAt'] is! String) {
      throw const GDevelopWebIdeInstallException('gdevelop_marker_invalid');
    }
    final installedAt = DateTime.tryParse(decoded['installedAt']! as String);
    final installationKind = switch (decoded['installationKind']) {
      'release' => GDevelopWebIdeInstallationKind.release,
      'user-provided' => GDevelopWebIdeInstallationKind.userProvided,
      _ => null,
    };
    if (installedAt == null || !installedAt.isUtc || installationKind == null) {
      throw const GDevelopWebIdeInstallException('gdevelop_marker_invalid');
    }
    return GDevelopWebIdeInstalledMarker(
      version: decoded['version']! as String,
      sha256: decoded['sha256']! as String,
      noticesSha256: decoded['noticesSha256']! as String,
      aiToolsPath: decoded['aiToolsPath']! as String,
      aiToolsSha256: decoded['aiToolsSha256']! as String,
      aiToolsContractHash: decoded['aiToolsContractHash']! as String,
      size: decoded['size']! as int,
      installedAt: installedAt,
      installationKind: installationKind,
    );
  }

  Future<void> _writeMarker(
    Directory root,
    GDevelopWebIdeInstalledMarker marker,
  ) async {
    final file = File(
      '${root.path}${Platform.pathSeparator}$installedMarkerName',
    );
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 3,
        'version': marker.version,
        'sha256': marker.sha256,
        'noticesSha256': marker.noticesSha256,
        'aiToolsPath': marker.aiToolsPath,
        'aiToolsSha256': marker.aiToolsSha256,
        'aiToolsContractHash': marker.aiToolsContractHash,
        'size': marker.size,
        'installedAt': marker.installedAt.toIso8601String(),
        'installationKind': switch (marker.installationKind) {
          GDevelopWebIdeInstallationKind.release => 'release',
          GDevelopWebIdeInstallationKind.userProvided => 'user-provided',
        },
      }),
      flush: true,
    );
  }

  Future<_InstallJournal?> _readJournal(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          !_hasExactKeys(decoded, const {
            'schemaVersion',
            'phase',
            'stagingName',
            'version',
            'sha256',
            'size',
          }) ||
          decoded['schemaVersion'] != _journalSchemaVersion ||
          decoded['phase'] is! String ||
          decoded['stagingName'] is! String ||
          !RegExp(
            r'^\.official-staging-[A-Za-z0-9_-]{1,80}$',
          ).hasMatch(decoded['stagingName']! as String) ||
          decoded['version'] is! String ||
          !RegExp(
            r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
          ).hasMatch(decoded['version']! as String) ||
          decoded['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(decoded['sha256']! as String) ||
          decoded['size'] is! int ||
          (decoded['size']! as int) <= 0) {
        return null;
      }
      final phase = _InstallPhase.values.firstWhere(
        (candidate) => candidate.name == decoded['phase'],
      );
      return _InstallJournal(
        phase: phase,
        stagingName: decoded['stagingName']! as String,
        version: decoded['version']! as String,
        sha256: decoded['sha256']! as String,
        size: decoded['size']! as int,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeJournal(File file, _InstallJournal journal) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(journal.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<bool> _matchesJournal(
    Directory official,
    _InstallJournal journal,
  ) async {
    final inspection = await _inspectOfficial(official);
    return inspection.state == GDevelopWebIdeInstallationState.ready &&
        inspection.marker?.version == journal.version &&
        inspection.marker?.sha256 == journal.sha256 &&
        inspection.marker?.size == journal.size;
  }

  Future<void> _restoreBackup(Directory official, Directory backup) async {
    if (await official.exists()) await official.delete(recursive: true);
    await renameDirectory(backup, official.path);
  }

  Future<void> _deleteStaleStaging(Directory root) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (RegExp(r'^\.official-staging-[A-Za-z0-9_-]{1,80}$').hasMatch(name)) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<T> _withFileLock<T>(
    String rootPath,
    Future<T> Function() action,
  ) async {
    final root = Directory(rootPath).absolute;
    final rootKey = _pathKey(root.path);
    final previous = _rootOperationTails[rootKey] ?? Future<void>.value();
    final completed = Completer<void>();
    final queued = completed.future;
    _rootOperationTails[rootKey] = queued;
    await previous;
    RandomAccessFile? lock;
    var locked = false;
    try {
      await root.create(recursive: true);
      final lockFile = File('${root.path}${Platform.pathSeparator}$_lockName');
      lock = await lockFile.open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      locked = true;
      return await action();
    } finally {
      try {
        if (lock != null) {
          try {
            if (locked) await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        // Keep one stable lock inode/path for the installed root. Deleting it
        // after every read can fail on Windows while another provider call has
        // the file open, and can split waiters across different files on Unix.
        completed.complete();
        if (identical(_rootOperationTails[rootKey], queued)) {
          _rootOperationTails.remove(rootKey);
        }
      }
    }
  }

  void _validateSpec(GDevelopWebIdeInstallSpec spec) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(spec.version) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(spec.sha256) ||
        spec.size <= 0) {
      throw const GDevelopWebIdeInstallException(
        'gdevelop_install_spec_invalid',
      );
    }
  }

  Directory _official(Directory root) =>
      Directory('${root.path}${Platform.pathSeparator}official');

  Directory _backup(Directory root) =>
      Directory('${root.path}${Platform.pathSeparator}$_backupName');

  File _journal(Directory root) =>
      File('${root.path}${Platform.pathSeparator}$_journalName');

  String _pathKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  Future<String> _sha256(File file) async {
    final sink = Sha256().toSync().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final hash = await sink.hash();
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<String> _sha256Bytes(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Future<Directory> _renameDirectory(
    Directory source,
    String destination,
  ) => source.rename(destination);

  static bool _hasExactKeys(Map source, Set<String> expected) {
    final keys = source.keys;
    return keys.every((key) => key is String) &&
        keys.length == expected.length &&
        keys.every(expected.contains);
  }

  static bool _isValidLibGdProvenance(Object? value, RegExp sha256Pattern) {
    if (value is! Map ||
        !_hasExactKeys(value, const {
          'kind',
          'source',
          'upstreamVersion',
          'files',
          'userDecision',
        }) ||
        value['source'] is! String ||
        value['upstreamVersion'] is! String ||
        !RegExp(
          r'^\d+\.\d+\.\d+$',
        ).hasMatch(value['upstreamVersion']! as String) ||
        value['files'] is! Map) {
      return false;
    }
    final kind = value['kind'];
    final source = value['source']! as String;
    final userDecision = value['userDecision'];
    final validSource = switch (kind) {
      'approved-legacy-prepared-exception' =>
        _isCanonicalAbsoluteProvenancePath(source) && userDecision == 'B',
      'official-exact-commit-artifact' =>
        RegExp(
              r'^https://s3\.amazonaws\.com/gdevelop-gdevelop\.js/master/commit/[a-f0-9]{40}$',
            ).hasMatch(source) &&
            userDecision == 'not-required',
      _ => false,
    };
    if (!validSource) return false;
    final files = value['files']! as Map;
    if (!_hasExactKeys(files, const {'libGD.js', 'libGD.wasm'})) return false;
    for (final fileName in const ['libGD.js', 'libGD.wasm']) {
      final record = files[fileName];
      if (record is! Map ||
          !_hasExactKeys(record, const {'sha256', 'size'}) ||
          record['sha256'] is! String ||
          !sha256Pattern.hasMatch(record['sha256']! as String) ||
          record['size'] is! int ||
          (record['size']! as int) <= 0) {
        return false;
      }
    }
    return true;
  }

  static bool _isCanonicalAbsoluteProvenancePath(String value) {
    if (value.isEmpty || value.contains('\u0000')) return false;
    if (value.startsWith('/')) {
      if (value.length > 1 && value.endsWith('/')) return false;
      return value
          .substring(1)
          .split('/')
          .every(
            (segment) =>
                segment.isNotEmpty && segment != '.' && segment != '..',
          );
    }
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(value) || value.contains('/')) {
      return false;
    }
    if (value.length > 3 && value.endsWith('\\')) return false;
    return value
        .substring(3)
        .split('\\')
        .every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
        );
  }

  static bool _deepJsonEquals(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length ||
          left.keys.any((key) => !right.containsKey(key))) {
        return false;
      }
      return left.keys.every((key) => _deepJsonEquals(left[key], right[key]));
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index += 1) {
        if (!_deepJsonEquals(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }
}

class _LoadedAiTools {
  const _LoadedAiTools({required this.rawSha256, required this.registry});

  final String rawSha256;
  final GDevelopAiToolRegistry registry;
}

enum _InstallPhase { prepared, backupMoved, installed }

class _InstallJournal {
  const _InstallJournal({
    required this.phase,
    required this.stagingName,
    required this.version,
    required this.sha256,
    required this.size,
  });

  final _InstallPhase phase;
  final String stagingName;
  final String version;
  final String sha256;
  final int size;

  _InstallJournal withPhase(_InstallPhase next) => _InstallJournal(
    phase: next,
    stagingName: stagingName,
    version: version,
    sha256: sha256,
    size: size,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': FileGDevelopWebIdeInstaller._journalSchemaVersion,
    'phase': phase.name,
    'stagingName': stagingName,
    'version': version,
    'sha256': sha256,
    'size': size,
  };
}
