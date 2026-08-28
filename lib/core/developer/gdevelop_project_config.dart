import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'gdevelop_project_root_resolver.dart';
import 'project_provisioning_service.dart';

enum GDevelopProjectGameType {
  single('single'),
  online('online');

  const GDevelopProjectGameType(this.wireName);

  final String wireName;

  static GDevelopProjectGameType parse(String value) => values.firstWhere(
    (type) => type.wireName == value,
    orElse: () => throw const FormatException('GDevelop gameType 无效'),
  );
}

class GDevelopProjectConfig {
  const GDevelopProjectConfig({
    required this.gameId,
    required this.revision,
    required this.gameType,
    required this.minPlayers,
    required this.maxPlayers,
    required this.tags,
    this.webRuntimeMultithreading = false,
    required this.updatedAt,
  });

  static const schemaVersion = 2;
  static const legacySchemaVersion = 1;
  static const defaultOnlineMinPlayers = 2;
  static const defaultOnlineMaxPlayers = 5;
  static const maximumPlayers = 64;
  static const maximumTags = 5;
  static const maximumTagLength = 64;

  final String gameId;
  final int revision;
  final GDevelopProjectGameType gameType;
  final int minPlayers;
  final int maxPlayers;
  final List<String> tags;
  final bool webRuntimeMultithreading;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'gameId': gameId,
    'revision': revision,
    'gameType': gameType.wireName,
    'minPlayers': minPlayers,
    'maxPlayers': maxPlayers,
    'tags': tags,
    'webRuntimeMultithreading': webRuntimeMultithreading,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory GDevelopProjectConfig.fromJson(
    Map<String, Object?> json, {
    required String expectedGameId,
  }) {
    const legacyFields = {
      'schemaVersion',
      'gameId',
      'revision',
      'gameType',
      'updatedAt',
    };
    const previousFields = {
      ...legacyFields,
      'minPlayers',
      'maxPlayers',
      'tags',
    };
    const fields = {...previousFields, 'webRuntimeMultithreading'};
    final rawSchemaVersion = json['schemaVersion'];
    final isLegacy = rawSchemaVersion == legacySchemaVersion;
    final hasLegacyFields =
        json.length == legacyFields.length &&
        json.keys.every(legacyFields.contains);
    final hasPreviousFields =
        json.length == previousFields.length &&
        json.keys.every(previousFields.contains);
    final hasCurrentFields =
        json.length == fields.length && json.keys.every(fields.contains);
    if ((isLegacy && !hasLegacyFields) ||
        (!isLegacy &&
            (rawSchemaVersion != schemaVersion ||
                (!hasPreviousFields && !hasCurrentFields)))) {
      throw const FormatException('GDevelop 项目配置 schema 无效');
    }
    final gameId = json['gameId'];
    final revision = json['revision'];
    final gameType = json['gameType'];
    final minPlayers = json['minPlayers'];
    final maxPlayers = json['maxPlayers'];
    final tags = json['tags'];
    final webRuntimeMultithreading = json['webRuntimeMultithreading'];
    final updatedAt = json['updatedAt'];
    if (gameId is! String ||
        revision is! int ||
        revision < 1 ||
        gameType is! String ||
        updatedAt is! String) {
      throw const FormatException('GDevelop 项目配置格式无效');
    }
    if (json.containsKey('webRuntimeMultithreading') &&
        webRuntimeMultithreading is! bool) {
      throw const FormatException('GDevelop Web Runtime 多线程配置无效');
    }
    final normalizedGameId = ProjectProvisioningService.validateGameId(gameId);
    final normalizedExpected = ProjectProvisioningService.validateGameId(
      expectedGameId,
    );
    final parsedUpdatedAt = DateTime.tryParse(updatedAt);
    if (normalizedGameId != normalizedExpected || parsedUpdatedAt == null) {
      throw const FormatException('GDevelop 项目配置身份或时间无效');
    }
    final parsedGameType = GDevelopProjectGameType.parse(gameType);
    final effectiveMinPlayers = isLegacy
        ? parsedGameType == GDevelopProjectGameType.online
              ? defaultOnlineMinPlayers
              : 1
        : minPlayers;
    final effectiveMaxPlayers = isLegacy
        ? parsedGameType == GDevelopProjectGameType.online
              ? defaultOnlineMaxPlayers
              : 1
        : maxPlayers;
    final normalizedTags = isLegacy
        ? const <String>[]
        : normalizeTags(tags is List ? tags : const <Object?>[null]);
    validatePlayerLimits(
      gameType: parsedGameType,
      minPlayers: effectiveMinPlayers,
      maxPlayers: effectiveMaxPlayers,
    );
    return GDevelopProjectConfig(
      gameId: normalizedGameId,
      revision: revision,
      gameType: parsedGameType,
      minPlayers: effectiveMinPlayers as int,
      maxPlayers: effectiveMaxPlayers as int,
      tags: normalizedTags,
      webRuntimeMultithreading: webRuntimeMultithreading == true,
      updatedAt: parsedUpdatedAt.toUtc(),
    );
  }

  static void validatePlayerLimits({
    required GDevelopProjectGameType gameType,
    required Object? minPlayers,
    required Object? maxPlayers,
  }) {
    if (minPlayers is! int ||
        maxPlayers is! int ||
        minPlayers < 1 ||
        maxPlayers < minPlayers ||
        maxPlayers > maximumPlayers ||
        (gameType == GDevelopProjectGameType.single &&
            (minPlayers != 1 || maxPlayers != 1))) {
      throw const FormatException('GDevelop 玩家人数配置无效');
    }
  }

  static List<String> normalizeTags(Iterable<Object?> values) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in values) {
      if (value is! String) {
        throw const FormatException('GDevelop 标签格式无效');
      }
      final tag = value.trim();
      if (tag.isEmpty || tag.length > maximumTagLength) {
        throw const FormatException('GDevelop 标签格式无效');
      }
      if (seen.add(tag)) normalized.add(tag);
    }
    if (normalized.length > maximumTags) {
      throw const FormatException('GDevelop 标签最多 5 个');
    }
    return List.unmodifiable(normalized);
  }
}

enum GDevelopProjectConfigStatus {
  ready('ready'),
  missing('missing'),
  invalid('invalid');

  const GDevelopProjectConfigStatus(this.wireName);

  final String wireName;
}

class GDevelopProjectConfigReadResult {
  const GDevelopProjectConfigReadResult.ready(this.config)
    : status = GDevelopProjectConfigStatus.ready;

  const GDevelopProjectConfigReadResult.missing()
    : status = GDevelopProjectConfigStatus.missing,
      config = null;

  const GDevelopProjectConfigReadResult.invalid()
    : status = GDevelopProjectConfigStatus.invalid,
      config = null;

  final GDevelopProjectConfigStatus status;
  final GDevelopProjectConfig? config;

  Map<String, Object?> toJson() => {
    'status': status.wireName,
    if (config != null) 'config': config!.toJson(),
  };
}

class GDevelopProjectConfigRevisionConflict implements Exception {
  const GDevelopProjectConfigRevisionConflict(this.currentRevision);

  static const code = 'gdevelop_config_revision_conflict';

  final int currentRevision;
}

class GDevelopProjectConfigInvalidState implements Exception {
  const GDevelopProjectConfigInvalidState();

  static const code = 'gdevelop_config_invalid';
}

class GDevelopProjectConfigApplyConflict implements Exception {
  const GDevelopProjectConfigApplyConflict({
    required this.oldEvidence,
    required this.targetEvidence,
    required this.currentEvidence,
  });

  final GDevelopProjectConfigEvidence oldEvidence;
  final GDevelopProjectConfigEvidence targetEvidence;
  final GDevelopProjectConfigEvidence currentEvidence;
}

class GDevelopProjectConfigEvidence {
  const GDevelopProjectConfigEvidence.ready({
    required this.config,
    required this.contentHash,
  }) : status = GDevelopProjectConfigStatus.ready;

  const GDevelopProjectConfigEvidence.missing()
    : status = GDevelopProjectConfigStatus.missing,
      config = null,
      contentHash = null;

  const GDevelopProjectConfigEvidence.invalid({this.contentHash})
    : status = GDevelopProjectConfigStatus.invalid,
      config = null;

  final GDevelopProjectConfigStatus status;
  final GDevelopProjectConfig? config;
  final String? contentHash;

  int? get revision => config?.revision;

  Map<String, Object?> toJson() => {
    'status': status.wireName,
    if (revision != null) 'revision': revision,
    if (contentHash != null) 'contentHash': contentHash,
    if (config != null) 'config': config!.toJson(),
  };

  bool matches(GDevelopProjectConfigEvidence other) =>
      status == other.status &&
      revision == other.revision &&
      contentHash == other.contentHash;

  static Future<GDevelopProjectConfigEvidence> forReady(
    GDevelopProjectConfig config,
  ) async => GDevelopProjectConfigEvidence.ready(
    config: config,
    contentHash: await contentHashFor(config),
  );

  static Future<String> contentHashFor(GDevelopProjectConfig config) =>
      _hashBytes(utf8.encode(jsonEncode(config.toJson())));
}

abstract interface class GDevelopProjectConfigRepository {
  Future<GDevelopProjectConfigReadResult> read(String gameId);

  Future<GDevelopProjectConfig> put({
    required String gameId,
    required GDevelopProjectGameType gameType,
    int? minPlayers,
    int? maxPlayers,
    List<String>? tags,
    bool webRuntimeMultithreading = false,
    required int expectedRevision,
  });

  Future<void> deleteArtifacts(String gameId);

  Future<GDevelopProjectConfigEvidence> inspect(String gameId);

  Future<GDevelopProjectConfigEvidence> applyPreparedTarget({
    required String gameId,
    required GDevelopProjectConfigEvidence oldEvidence,
    required GDevelopProjectConfigEvidence targetEvidence,
  });
}

typedef GDevelopProjectConfigRename =
    Future<File> Function(File source, String destination);

/// 保存 Playmesh 自有 GDevelop 配置，不读取或修改官方工程 JSON。
class GDevelopProjectConfigStore implements GDevelopProjectConfigRepository {
  GDevelopProjectConfigStore({
    GDevelopProjectRootResolver? rootResolver,
    DateTime Function()? clock,
    GDevelopProjectConfigRename? renameFile,
  }) : rootResolver = rootResolver ?? FileSystemGDevelopProjectRootResolver(),
       clock = clock ?? DateTime.now,
       _renameFile = renameFile ?? _rename;

  static const maxBytes = 16 * 1024;
  final GDevelopProjectRootResolver rootResolver;
  final DateTime Function() clock;
  final GDevelopProjectConfigRename _renameFile;

  @override
  Future<GDevelopProjectConfigReadResult> read(String gameId) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return rootResolver.runInProjectRoot(
      normalized,
      (root) async => _readResult(await _inspectUnlocked(root, normalized)),
    );
  }

  @override
  Future<GDevelopProjectConfigEvidence> inspect(String gameId) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return rootResolver.runInProjectRoot(
      normalized,
      (root) => _inspectUnlocked(root, normalized),
    );
  }

  @override
  Future<GDevelopProjectConfig> put({
    required String gameId,
    required GDevelopProjectGameType gameType,
    int? minPlayers,
    int? maxPlayers,
    List<String>? tags,
    bool webRuntimeMultithreading = false,
    required int expectedRevision,
  }) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    if (expectedRevision < 0) {
      throw const FormatException('GDevelop expectedRevision 无效');
    }
    final effectiveMinPlayers =
        minPlayers ??
        (gameType == GDevelopProjectGameType.online
            ? GDevelopProjectConfig.defaultOnlineMinPlayers
            : 1);
    final effectiveMaxPlayers =
        maxPlayers ??
        (gameType == GDevelopProjectGameType.online
            ? GDevelopProjectConfig.defaultOnlineMaxPlayers
            : 1);
    GDevelopProjectConfig.validatePlayerLimits(
      gameType: gameType,
      minPlayers: effectiveMinPlayers,
      maxPlayers: effectiveMaxPlayers,
    );
    final normalizedTags = GDevelopProjectConfig.normalizeTags(
      tags ?? const [],
    );
    return rootResolver.runInProjectRoot(normalized, (root) async {
      final current = await _inspectUnlocked(root, normalized);
      if (current.status == GDevelopProjectConfigStatus.invalid) {
        throw const GDevelopProjectConfigInvalidState();
      }
      final currentRevision = current.revision ?? 0;
      if (currentRevision != expectedRevision) {
        throw GDevelopProjectConfigRevisionConflict(currentRevision);
      }
      final config = GDevelopProjectConfig(
        gameId: normalized,
        revision: currentRevision + 1,
        gameType: gameType,
        minPlayers: effectiveMinPlayers,
        maxPlayers: effectiveMaxPlayers,
        tags: normalizedTags,
        webRuntimeMultithreading: webRuntimeMultithreading,
        updatedAt: clock().toUtc(),
      );
      await _writeAtomic(_configFile(root), config);
      return config;
    });
  }

  @override
  Future<void> deleteArtifacts(String gameId) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    return rootResolver.runInProjectRoot(normalized, (root) async {
      final file = _configFile(root);
      // 固定文件名便于删除流程和故障恢复完整清理，不生成累积临时文件。
      for (final artifact in [
        File('${file.path}.tmp'),
        File('${file.path}.backup'),
        file,
      ]) {
        if (await artifact.exists()) await artifact.delete();
      }
    });
  }

  @override
  Future<GDevelopProjectConfigEvidence> applyPreparedTarget({
    required String gameId,
    required GDevelopProjectConfigEvidence oldEvidence,
    required GDevelopProjectConfigEvidence targetEvidence,
  }) async {
    final normalized = ProjectProvisioningService.validateGameId(gameId);
    if (oldEvidence.status == GDevelopProjectConfigStatus.invalid ||
        targetEvidence.status == GDevelopProjectConfigStatus.invalid) {
      throw const GDevelopProjectConfigInvalidState();
    }
    if (targetEvidence.config case final targetConfig?) {
      GDevelopProjectConfig.fromJson(
        targetConfig.toJson(),
        expectedGameId: normalized,
      );
      final expectedHash = await GDevelopProjectConfigEvidence.contentHashFor(
        targetConfig,
      );
      if (expectedHash != targetEvidence.contentHash) {
        throw const FormatException('GDevelop prepared config hash 无效');
      }
    }
    return rootResolver.runInProjectRoot(normalized, (root) async {
      final current = await _inspectUnlocked(root, normalized);
      if (current.matches(targetEvidence)) return current;
      if (!current.matches(oldEvidence)) {
        throw GDevelopProjectConfigApplyConflict(
          oldEvidence: oldEvidence,
          targetEvidence: targetEvidence,
          currentEvidence: current,
        );
      }
      final file = _configFile(root);
      if (targetEvidence.status == GDevelopProjectConfigStatus.missing) {
        await _deleteAtomic(file);
      } else {
        await _writeAtomic(file, targetEvidence.config!);
      }
      final applied = await _inspectUnlocked(root, normalized);
      if (!applied.matches(targetEvidence)) {
        throw GDevelopProjectConfigApplyConflict(
          oldEvidence: oldEvidence,
          targetEvidence: targetEvidence,
          currentEvidence: applied,
        );
      }
      return applied;
    });
  }

  Future<GDevelopProjectConfigEvidence> _inspectUnlocked(
    Directory root,
    String gameId,
  ) async {
    final file = _configFile(root);
    try {
      await _recoverArtifacts(file);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return const GDevelopProjectConfigEvidence.missing();
      }
      if (type != FileSystemEntityType.file || await file.length() > maxBytes) {
        return const GDevelopProjectConfigEvidence.invalid();
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) {
        return GDevelopProjectConfigEvidence.invalid(
          contentHash: await _hashBytes(bytes),
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map) {
        return GDevelopProjectConfigEvidence.invalid(
          contentHash: await _hashBytes(bytes),
        );
      }
      final config = GDevelopProjectConfig.fromJson(
        Map<String, Object?>.from(decoded),
        expectedGameId: gameId,
      );
      return GDevelopProjectConfigEvidence.ready(
        config: config,
        contentHash: await _hashBytes(bytes),
      );
    } on FormatException {
      String? contentHash;
      try {
        if (await file.exists() && await file.length() <= maxBytes) {
          contentHash = await _hashBytes(await file.readAsBytes());
        }
      } on FileSystemException {
        // invalid evidence 可省略无法可靠取得的内容 hash。
      }
      return GDevelopProjectConfigEvidence.invalid(contentHash: contentHash);
    } on FileSystemException {
      return const GDevelopProjectConfigEvidence.invalid();
    }
  }

  GDevelopProjectConfigReadResult _readResult(
    GDevelopProjectConfigEvidence evidence,
  ) => switch (evidence.status) {
    GDevelopProjectConfigStatus.ready => GDevelopProjectConfigReadResult.ready(
      evidence.config!,
    ),
    GDevelopProjectConfigStatus.missing =>
      const GDevelopProjectConfigReadResult.missing(),
    GDevelopProjectConfigStatus.invalid =>
      const GDevelopProjectConfigReadResult.invalid(),
  };

  Future<void> _recoverArtifacts(File file) async {
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    final fileType = await FileSystemEntity.type(file.path, followLinks: false);
    if (fileType == FileSystemEntityType.notFound && await backup.exists()) {
      await _renameFile(backup, file.path);
    }
    if (await temporary.exists()) await temporary.delete();
    if (await file.exists() && await backup.exists()) await backup.delete();
  }

  Future<void> _writeAtomic(File file, GDevelopProjectConfig config) async {
    final bytes = utf8.encode(jsonEncode(config.toJson()));
    if (bytes.length > maxBytes) {
      throw const FormatException('GDevelop 项目配置不能超过 16 KiB');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    await _recoverArtifacts(file);
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await _renameFile(file, backup.path);
      try {
        await _renameFile(temporary, file.path);
        if (await backup.exists()) await backup.delete();
      } on Object {
        if (await file.exists()) await file.delete();
        if (await backup.exists()) await _renameFile(backup, file.path);
        rethrow;
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _deleteAtomic(File file) async {
    await _recoverArtifacts(file);
    if (!await file.exists()) return;
    final backup = File('${file.path}.backup');
    if (await backup.exists()) await backup.delete();
    await _renameFile(file, backup.path);
    try {
      await backup.delete();
    } on Object {
      if (!await file.exists() && await backup.exists()) {
        await _renameFile(backup, file.path);
      }
      rethrow;
    }
  }

  File _configFile(Directory root) => File(
    '${root.path}${Platform.pathSeparator}.playmesh'
    '${Platform.pathSeparator}gdevelop'
    '${Platform.pathSeparator}project-config.json',
  );
}

Future<File> _rename(File source, String destination) =>
    source.rename(destination);

Future<String> _hashBytes(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
