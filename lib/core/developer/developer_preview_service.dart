import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';

import '../../models/game_capabilities.dart';
import '../game_package/game_package_transfer_service.dart';
import 'developer_run_controller.dart';
import 'foundation/package_upload_spooler.dart';
import 'foundation/staged_development_source.dart';

class DeveloperPreviewNotFound implements Exception {
  const DeveloperPreviewNotFound();
}

class DeveloperPreviewGenerationConflict implements Exception {
  const DeveloperPreviewGenerationConflict(this.currentPreviewId);

  final String currentPreviewId;
}

class DeveloperPreviewPackageInvalid implements Exception {
  const DeveloperPreviewPackageInvalid(this.message);

  final String message;
}

enum DeveloperPreviewSurface { app, embedded }

class DeveloperStagedPackageResult {
  const DeveloperStagedPackageResult({
    required this.packageId,
    required this.gameId,
    required this.expiresAt,
  });

  final String packageId;
  final String gameId;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => {
    'protocolVersion': DeveloperPreviewResult.protocolVersion,
    'packageId': packageId,
    'gameId': gameId,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
  };
}

class _StagedRuntimeDeclaration {
  const _StagedRuntimeDeclaration({
    required this.gameId,
    required this.expiresAt,
    required this.declaration,
  });

  final String gameId;
  final DateTime expiresAt;
  final DeveloperRuntimeDeclaration declaration;
}

class DeveloperPreviewResult {
  const DeveloperPreviewResult({
    required this.previewId,
    required this.gameId,
    required this.expiresAt,
    required this.run,
  });

  static const protocolVersion = '1.0.0';

  final String previewId;
  final String gameId;
  final DateTime expiresAt;
  final DeveloperRunStatus run;

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'previewId': previewId,
    'gameId': gameId,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
    'run': run.toJson(),
  };
}

class _DeveloperPreviewRecord {
  const _DeveloperPreviewRecord({
    required this.source,
    required this.generation,
    required this.surface,
    required this.run,
  });

  final StagedDevelopmentSource source;
  final int generation;
  final DeveloperPreviewSurface surface;
  final DeveloperRunStatus run;
}

/// Stages a standard Playmesh package and launches it through the existing
/// DeveloperRun -> GamePage -> GameWebGateway runtime chain.
class DeveloperPreviewService {
  DeveloperPreviewService({
    required this.runController,
    GamePackageTransferService? packageTransfer,
    this.previewTtl = const Duration(hours: 2),
    this.temporaryRoot,
    DateTime Function()? clock,
  }) : packageTransfer = packageTransfer ?? GamePackageTransferService(),
       clock = clock ?? DateTime.now;

  final DeveloperRunController runController;
  final GamePackageTransferService packageTransfer;
  final Duration previewTtl;
  final Directory? temporaryRoot;
  final DateTime Function() clock;
  final Map<String, _DeveloperPreviewRecord> _current = {};
  final Map<String, Timer> _expiryTimers = {};
  final Map<String, Future<void>> _projectTails = {};
  final Map<String, int> _generations = {};
  final Map<String, _StagedRuntimeDeclaration> _stagedDeclarations = {};
  final Map<String, Timer> _stagedDeclarationTimers = {};
  final Random _random = Random.secure();
  bool _disposed = false;

  static Map<String, Object?> get limitsJson => {
    'maxArchiveBytes': GamePackageTransferService.maxCompressedBytes,
    'maxExpandedBytes': GamePackageTransferService.maxExpandedBytes,
    'maxSingleFileBytes': GamePackageTransferService.maxSingleFileBytes,
    'maxFiles': GamePackageTransferService.maxFileCount,
  };

  /// Validates a development package and returns a one-time, in-memory receipt.
  /// It never writes the package into the installed game catalog.
  Future<DeveloperStagedPackageResult> stageRuntimeDeclaration({
    required String gameId,
    required Stream<List<int>> archive,
    int? declaredLength,
  }) async {
    _ensureActive();
    final upload = await PackageUploadSpooler(
      maxBytes: GamePackageTransferService.maxCompressedBytes,
      temporaryRoot: temporaryRoot,
    ).spool(archive, declaredLength: declaredLength);
    try {
      final validated = await _readPackage(upload.file, gameId);
      final packageId = 'package-${_randomHex(16)}';
      final expiresAt = clock().toUtc().add(const Duration(minutes: 15));
      final declaration = DeveloperRuntimeDeclaration(
        manifest: validated.package.manifest,
        capabilities: validated.capabilities,
      );
      await _serializeProject(gameId, () async {
        _stagedDeclarations[packageId] = _StagedRuntimeDeclaration(
          gameId: gameId,
          expiresAt: expiresAt,
          declaration: declaration,
        );
        _stagedDeclarationTimers[packageId] = Timer(
          expiresAt.difference(clock().toUtc()),
          () => _removeStagedDeclaration(packageId),
        );
      });
      return DeveloperStagedPackageResult(
        packageId: packageId,
        gameId: gameId,
        expiresAt: expiresAt,
      );
    } finally {
      await upload.dispose();
    }
  }

  Future<DeveloperRuntimeDeclaration> consumeRuntimeDeclaration({
    required String gameId,
    required String packageId,
  }) => _serializeProject(gameId, () async {
    final staged = _stagedDeclarations[packageId];
    if (staged == null ||
        staged.gameId != gameId ||
        !clock().toUtc().isBefore(staged.expiresAt)) {
      _removeStagedDeclaration(packageId);
      throw const DeveloperPreviewPackageRequired(
        stage: 'development_package_bind',
        operation: 'runtime.development.start',
      );
    }
    _removeStagedDeclaration(packageId);
    return staged.declaration;
  });

  Future<DeveloperPreviewResult> start({
    required String gameId,
    required Stream<List<int>> archive,
    int? declaredLength,
    DeveloperPreviewSurface surface = DeveloperPreviewSurface.app,
    Uri Function(String previewId)? embeddedLinkBuilder,
  }) async {
    _ensureActive();
    final upload = await PackageUploadSpooler(
      maxBytes: GamePackageTransferService.maxCompressedBytes,
      temporaryRoot: temporaryRoot,
    ).spool(archive, declaredLength: declaredLength);
    StagedDevelopmentSource? staged;
    try {
      late final ValidatedGamePackage package;
      try {
        package = await packageTransfer.readPackage(upload.file);
      } on ArchiveException {
        throw const DeveloperPreviewPackageInvalid('预览传输必须是完整且未损坏的 ZIP');
      } on FormatException catch (error) {
        throw DeveloperPreviewPackageInvalid(error.message);
      }
      if (package.manifest.id != gameId) {
        throw const DeveloperPreviewPackageInvalid(
          '预览包 manifest.id 必须与路径 gameId 一致',
        );
      }
      late final GameCapabilities capabilities;
      try {
        capabilities = _capabilities(package);
      } on FormatException catch (error) {
        throw DeveloperPreviewPackageInvalid(error.message);
      }
      final expiresAt = clock().toUtc().add(previewTtl);
      final previewId = 'preview-${_randomHex(16)}';
      if (surface == DeveloperPreviewSurface.embedded &&
          embeddedLinkBuilder == null) {
        throw const DeveloperPreviewPackageInvalid('嵌入式预览缺少同源运行地址');
      }
      late final DeveloperPreviewResult result;
      await _serializeProject(gameId, () async {
        _ensureActive();
        final recordKey = _recordKey(gameId, surface);
        final generation = (_generations[recordKey] ?? 0) + 1;
        staged = await StagedDevelopmentSource.create(
          previewId: previewId,
          gameId: gameId,
          generation: generation,
          expiresAt: expiresAt,
          // Runtime compatibility files may be conservatively bundled when the
          // WebIDE cannot inspect extension usage. The validated manifest stays
          // the sole authority for solo/multiplayer launch semantics.
          runtimeDeclaration: DeveloperRuntimeDeclaration(
            manifest: package.manifest,
            capabilities: capabilities,
          ),
          package: package,
          packageTransfer: packageTransfer,
          temporaryRoot: temporaryRoot,
        );
        final previous = _current[recordKey];
        try {
          final run = surface == DeveloperPreviewSurface.embedded
              ? _embeddedRunStatus(
                  gameId: gameId,
                  previewId: previewId,
                  link: embeddedLinkBuilder!(previewId),
                )
              : await runController.runDevelopment(staged!.resourceSession);
          _generations[recordKey] = generation;
          _current[recordKey] = _DeveloperPreviewRecord(
            source: staged!,
            generation: generation,
            surface: surface,
            run: run,
          );
          _armExpiry(recordKey, staged!);
          if (previous != null) await previous.source.close();
          result = DeveloperPreviewResult(
            previewId: previewId,
            gameId: gameId,
            expiresAt: expiresAt,
            run: run,
          );
          staged = null;
        } on Object {
          await staged?.close();
          staged = null;
          rethrow;
        }
      });
      return result;
    } finally {
      await staged?.close();
      await upload.dispose();
    }
  }

  Future<DeveloperPreviewResult> status(
    String gameId, {
    DeveloperPreviewSurface? surface,
  }) async {
    final record = surface == null
        ? _current[_recordKey(gameId, DeveloperPreviewSurface.app)] ??
              _current[_recordKey(gameId, DeveloperPreviewSurface.embedded)]
        : _current[_recordKey(gameId, surface)];
    if (record == null) throw const DeveloperPreviewNotFound();
    if (!clock().toUtc().isBefore(record.source.expiresAt)) {
      await _expire(_recordKey(gameId, record.surface), record.source);
      throw const DeveloperPreviewNotFound();
    }
    return _result(record);
  }

  DeveloperResourceSession? embeddedResourceSession({
    required String gameId,
    required String previewId,
  }) {
    final record =
        _current[_recordKey(gameId, DeveloperPreviewSurface.embedded)];
    if (record == null || record.source.previewId != previewId) return null;
    if (!clock().toUtc().isBefore(record.source.expiresAt)) return null;
    return record.source.resourceSession;
  }

  Future<DeveloperPreviewResult> stop({
    required String gameId,
    required String previewId,
  }) => _serializeProject(gameId, () async {
    final records = _recordsForProject(gameId);
    if (records.isEmpty) throw const DeveloperPreviewNotFound();
    MapEntry<String, _DeveloperPreviewRecord>? entry;
    for (final candidate in records) {
      if (candidate.value.source.previewId == previewId) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      throw DeveloperPreviewGenerationConflict(
        records.first.value.source.previewId,
      );
    }
    final record = entry.value;
    Object? stopError;
    if (record.surface == DeveloperPreviewSurface.app) {
      try {
        await runController.stopDevelopment(gameId);
      } on StateError catch (error) {
        stopError = error;
      }
    }
    _current.remove(entry.key);
    _expiryTimers.remove(entry.key)?.cancel();
    await record.source.close();
    if (stopError != null &&
        runController.status(gameId).phase != DeveloperRunPhase.stopped) {
      throw stopError;
    }
    return _result(record);
  });

  Future<bool> stopProject(String gameId) =>
      _serializeProject(gameId, () async {
        final records = _recordsForProject(gameId);
        if (records.isEmpty) return false;
        Object? stopError;
        if (records.any(
          (entry) => entry.value.surface == DeveloperPreviewSurface.app,
        )) {
          try {
            await runController.stopDevelopment(gameId);
          } on StateError catch (error) {
            stopError = error;
          }
        }
        for (final entry in records) {
          _current.remove(entry.key);
          _expiryTimers.remove(entry.key)?.cancel();
          await entry.value.source.close();
        }
        if (stopError != null &&
            runController.status(gameId).phase != DeveloperRunPhase.stopped) {
          throw stopError;
        }
        return true;
      });

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _expiryTimers.values) {
      timer.cancel();
    }
    _expiryTimers.clear();
    for (final timer in _stagedDeclarationTimers.values) {
      timer.cancel();
    }
    _stagedDeclarationTimers.clear();
    _stagedDeclarations.clear();
    final entries = _current.entries.toList(growable: false);
    _current.clear();
    for (final entry in entries) {
      if (entry.value.surface == DeveloperPreviewSurface.app) {
        try {
          await runController.stopDevelopment(entry.value.source.gameId);
        } on Object {
          // Gateway shutdown must still revoke and remove every staged source.
        }
      }
      await entry.value.source.close();
    }
  }

  Future<({ValidatedGamePackage package, GameCapabilities capabilities})>
  _readPackage(File archive, String gameId) async {
    late final ValidatedGamePackage package;
    try {
      package = await packageTransfer.readPackage(archive);
    } on ArchiveException {
      throw const DeveloperPreviewPackageInvalid('开发临时包必须是完整且未损坏的 ZIP');
    } on FormatException catch (error) {
      throw DeveloperPreviewPackageInvalid(error.message);
    }
    if (package.manifest.id != gameId) {
      throw const DeveloperPreviewPackageInvalid(
        '开发临时包 manifest.id 必须与路径 gameId 一致',
      );
    }
    try {
      return (package: package, capabilities: _capabilities(package));
    } on FormatException catch (error) {
      throw DeveloperPreviewPackageInvalid(error.message);
    }
  }

  void _removeStagedDeclaration(String packageId) {
    _stagedDeclarations.remove(packageId);
    _stagedDeclarationTimers.remove(packageId)?.cancel();
  }

  void _armExpiry(String recordKey, StagedDevelopmentSource source) {
    _expiryTimers.remove(recordKey)?.cancel();
    final duration = source.expiresAt.difference(clock().toUtc());
    _expiryTimers[recordKey] = Timer(
      duration.isNegative ? Duration.zero : duration,
      () => unawaited(_expire(recordKey, source)),
    );
  }

  Future<void> _expire(
    String recordKey,
    StagedDevelopmentSource expected,
  ) async {
    try {
      await _serializeProject(expected.gameId, () async {
        final record = _current[recordKey];
        if (record == null || !identical(record.source, expected)) return;
        if (record.surface == DeveloperPreviewSurface.app) {
          try {
            await runController.stopDevelopment(expected.gameId);
          } on Object {
            // Expiry is best-effort; source revocation below remains mandatory.
          }
        }
        _current.remove(recordKey);
        _expiryTimers.remove(recordKey)?.cancel();
        await record.source.close();
      });
    } on Object {
      // Timer cleanup must not surface an unhandled asynchronous error.
    }
  }

  DeveloperPreviewResult _result(_DeveloperPreviewRecord record) =>
      DeveloperPreviewResult(
        previewId: record.source.previewId,
        gameId: record.source.gameId,
        expiresAt: record.source.expiresAt,
        run: record.surface == DeveloperPreviewSurface.app
            ? runController.status(record.source.gameId)
            : record.run,
      );

  DeveloperRunStatus _embeddedRunStatus({
    required String gameId,
    required String previewId,
    required Uri link,
  }) {
    if ((link.scheme != 'http' && link.scheme != 'https') ||
        link.query.isNotEmpty ||
        link.fragment.isNotEmpty) {
      throw const DeveloperPreviewPackageInvalid('嵌入式预览地址必须是无查询参数的 HTTP(S) 地址');
    }
    return DeveloperRunStatus(
      projectId: gameId,
      runId: previewId,
      phase: DeveloperRunPhase.running,
      links: [link],
      updatedAt: clock().toUtc(),
    );
  }

  List<MapEntry<String, _DeveloperPreviewRecord>> _recordsForProject(
    String gameId,
  ) => _current.entries
      .where((entry) => entry.value.source.gameId == gameId)
      .toList(growable: false);

  String _recordKey(String gameId, DeveloperPreviewSurface surface) =>
      '$gameId:${surface.name}';

  Future<T> _serializeProject<T>(
    String gameId,
    Future<T> Function() operation,
  ) {
    final previous = _projectTails[gameId] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>((_) {}, onError: (_, _) {});
    _projectTails[gameId] = tail;
    tail.whenComplete(() {
      if (identical(_projectTails[gameId], tail)) {
        _projectTails.remove(gameId);
      }
    });
    return result;
  }

  GameCapabilities _capabilities(ValidatedGamePackage package) {
    final bytes = package.files['capabilities.json'];
    if (bytes == null) return const GameCapabilities();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('capabilities.json 根节点必须是对象');
    }
    return GameCapabilities.fromJson(Map<String, Object?>.from(decoded));
  }

  void _ensureActive() {
    if (_disposed) throw StateError('开发者预览服务已经关闭');
  }

  String _randomHex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
}
