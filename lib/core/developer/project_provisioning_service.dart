import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/game_id.dart';
import '../library/playmesh_library_root.dart';

enum PlaymeshProjectKind {
  source('source'),
  gdevelop('gdevelop');

  const PlaymeshProjectKind(this.wireName);

  final String wireName;

  static PlaymeshProjectKind parse(String value) => values.firstWhere(
    (kind) => kind.wireName == value,
    orElse: () => throw const FormatException('Playmesh 项目类型无效'),
  );
}

class ProjectProvisioningConflict implements Exception {
  const ProjectProvisioningConflict({
    required this.gameId,
    required this.requestedKind,
    this.existingKind,
  });

  static const code = 'project_id_conflict';

  final String gameId;
  final PlaymeshProjectKind requestedKind;
  final PlaymeshProjectKind? existingKind;
}

class ProjectProvisioningMissing implements Exception {
  const ProjectProvisioningMissing(this.gameId);

  static const code = 'project_not_found';

  final String gameId;
}

class ProvisionedProject {
  const ProvisionedProject({
    required this.gameId,
    required this.name,
    required this.kind,
    required this.root,
    required this.created,
    required this.metadata,
  });

  final String gameId;
  final String name;
  final PlaymeshProjectKind kind;
  final Directory root;
  final bool created;
  final Map<String, Object?> metadata;
}

/// 项目根枚举时的稳定诊断；只暴露目录名，不泄露宿主机绝对路径。
class ProjectProvisioningListDiagnostic {
  const ProjectProvisioningListDiagnostic({
    required this.code,
    required this.directoryName,
    this.gameId,
  });

  static const metadataUnreadableCode = 'project_metadata_unreadable';
  static const metadataInvalidCode = 'project_metadata_invalid';
  static const rootIdentityMismatchCode = 'project_root_identity_mismatch';
  static const gdevelopMetadataInvalidCode = 'gdevelop_metadata_invalid';
  static const currentEvidenceUnavailableCode =
      'gdevelop_current_evidence_unavailable';

  final String code;
  final String directoryName;
  final String? gameId;

  Map<String, Object?> toJson() => {
    'code': code,
    'entry': directoryName,
    'messageKey': 'gdevelop.projectList.diagnostics.$code',
    if (gameId != null) 'gameId': gameId,
  };
}

/// 枚举结果显式携带坏根诊断，调用方可以独立决定 fail-fast 或部分返回。
class ProjectProvisioningListResult {
  const ProjectProvisioningListResult({
    required this.projects,
    required this.diagnostics,
  });

  final List<ProvisionedProject> projects;
  final List<ProjectProvisioningListDiagnostic> diagnostics;
}

/// Owns allocation and identity for every developer project stored below
/// `playmesh-library/packages/{gameId}`.
///
/// Product-specific services may add fields to `.playmesh/project.json`, but
/// the identity fields written here are reserved and cannot be overridden.
class ProjectProvisioningService {
  ProjectProvisioningService({
    Directory? projectsRoot,
    DateTime Function()? clock,
  }) : _injectedProjectsRoot = projectsRoot,
       clock = clock ?? DateTime.now;

  static const metadataSchemaVersion = 1;
  static const _androidApplicationIdIdentityPolicy =
      'android_application_id_v1';
  static final RegExp _legacyManagedGameIdPattern = RegExp(
    r'^[a-z0-9]+(?:[.-][a-z0-9]+)+$',
  );
  static final Map<String, Future<void>> _projectTails = {};
  static int _stagingSequence = 0;

  final Directory? _injectedProjectsRoot;
  final DateTime Function() clock;
  Directory? _resolvedProjectsRoot;

  static ({String gameId, String name}) validateIdentity({
    required String gameId,
    required String name,
  }) {
    final normalizedGameId = gameId.trim();
    final normalizedName = name.trim();
    if (!isValidPlaymeshGameId(normalizedGameId) ||
        !_legacyManagedGameIdPattern.hasMatch(normalizedGameId)) {
      throw const FormatException('项目 ID 必须是小写反向域名格式');
    }
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const FormatException('项目名称长度必须为 1 到 80 个字符');
    }
    return (gameId: normalizedGameId, name: normalizedName);
  }

  /// Identity policy used only by the source workspace's create-project API.
  /// It intentionally does not replace [validateIdentity], because existing
  /// managed projects may contain a hyphen in their game ID.
  static ({String gameId, String name}) validateNewSourceIdentity({
    required String gameId,
    required String name,
  }) {
    final normalizedGameId = gameId.trim();
    final normalizedName = name.trim();
    if (!isValidPlaymeshNewProjectGameId(normalizedGameId)) {
      throw const FormatException(
        '项目 ID 必须是 Android applicationId 格式：至少两段，以点分隔；'
        '每段以英文字母开头，且只能包含英文字母、数字和下划线；最长 64 个字符',
      );
    }
    if (normalizedName.isEmpty || normalizedName.length > 80) {
      throw const FormatException('项目名称长度必须为 1 到 80 个字符');
    }
    return (gameId: normalizedGameId, name: normalizedName);
  }

  static String validateGameId(String gameId) => validateIdentity(
    gameId: gameId,
    // 只复用 gameId 规则；占位名称不会写入磁盘。
    name: '_',
  ).gameId;

  static String _validateStoredGameId(
    String gameId, {
    required bool allowAndroidApplicationId,
  }) {
    final normalized = gameId.trim();
    if ((_legacyManagedGameIdPattern.hasMatch(normalized) &&
            isValidPlaymeshGameId(normalized)) ||
        (allowAndroidApplicationId &&
            isValidPlaymeshNewProjectGameId(normalized))) {
      return normalized;
    }
    throw const FormatException('项目 ID 无效');
  }

  static ({String gameId, String name}) _validateStoredIdentity({
    required String gameId,
    required String name,
    required String? identityPolicy,
  }) => identityPolicy == _androidApplicationIdIdentityPolicy
      ? validateNewSourceIdentity(gameId: gameId, name: name)
      : validateIdentity(gameId: gameId, name: name);

  Future<ProvisionedProject> createProject({
    required String gameId,
    required String name,
    required PlaymeshProjectKind kind,
    bool requireAndroidApplicationId = false,
    Map<String, Object?> additionalMetadata = const {},
    Future<void> Function(Directory stagingRoot)? initialize,
  }) {
    if (requireAndroidApplicationId && kind != PlaymeshProjectKind.source) {
      throw ArgumentError.value(
        kind,
        'kind',
        'Android applicationId 创建规则只适用于源码项目',
      );
    }
    final identity = requireAndroidApplicationId
        ? validateNewSourceIdentity(gameId: gameId, name: name)
        : validateIdentity(gameId: gameId, name: name);
    return _serialize(identity.gameId, () async {
      final projects = await _projectsRoot();
      final target = _projectRoot(projects, identity.gameId);
      if (await _pathExists(target.path)) {
        throw await _conflict(target, identity.gameId, kind);
      }

      late Directory staging;
      do {
        final sequence = _stagingSequence++;
        staging = Directory(
          '${projects.path}${Platform.pathSeparator}.playmesh-create-'
          '${identity.gameId}-${clock().toUtc().microsecondsSinceEpoch}-'
          '$sequence',
        );
      } while (await _pathExists(staging.path));
      try {
        await staging.create(recursive: true);
        if (initialize != null) await initialize(staging);
        final now = clock().toUtc();
        final metadata = _composeMetadata(
          additionalMetadata,
          gameId: identity.gameId,
          name: identity.name,
          kind: kind,
          identityPolicy: requireAndroidApplicationId
              ? _androidApplicationIdIdentityPolicy
              : null,
          createdAt: now,
          updatedAt: now,
        );
        await _writeMetadata(_metadataFile(staging), metadata);
        try {
          await _renameDirectoryWithRetry(staging, target.path);
        } on FileSystemException {
          if (await _pathExists(target.path)) {
            throw await _conflict(target, identity.gameId, kind);
          }
          rethrow;
        }
        return ProvisionedProject(
          gameId: identity.gameId,
          name: identity.name,
          kind: kind,
          root: target,
          created: true,
          metadata: Map.unmodifiable(metadata),
        );
      } on Object {
        if (await staging.exists()) await staging.delete(recursive: true);
        rethrow;
      }
    });
  }

  Future<ProvisionedProject> openProject({
    required String gameId,
    required PlaymeshProjectKind kind,
  }) {
    final normalized = _validateStoredGameId(
      gameId,
      allowAndroidApplicationId: kind == PlaymeshProjectKind.source,
    );
    return _serialize(normalized, () async {
      final root = _projectRoot(await _projectsRoot(), normalized);
      if (!await root.exists()) throw ProjectProvisioningMissing(normalized);
      final metadata = await _readMetadata(_metadataFile(root));
      if (metadata == null) throw ProjectProvisioningMissing(normalized);
      return _validatedProject(
        root: root,
        metadata: metadata,
        gameId: normalized,
        kind: kind,
        created: false,
      );
    });
  }

  /// Claims a legacy untyped package root, or validates an existing binding.
  Future<ProvisionedProject> bindProject({
    required String gameId,
    required String name,
    required PlaymeshProjectKind kind,
    Map<String, Object?> additionalMetadata = const {},
  }) {
    final normalizedGameId = _validateStoredGameId(
      gameId,
      allowAndroidApplicationId: kind == PlaymeshProjectKind.source,
    );
    return _serialize(normalizedGameId, () async {
      final root = _projectRoot(await _projectsRoot(), normalizedGameId);
      if (!await root.exists()) {
        throw ProjectProvisioningMissing(normalizedGameId);
      }
      final metadataFile = _metadataFile(root);
      final existing = await _readMetadata(metadataFile);
      if (existing != null) {
        return _validatedProject(
          root: root,
          metadata: existing,
          gameId: normalizedGameId,
          kind: kind,
          created: false,
        );
      }
      // Binding an untyped legacy package is not a new-project entry. Keep its
      // historical identity policy; the Android policy is only persisted by
      // createProject(requireAndroidApplicationId: true).
      final identity = validateIdentity(gameId: gameId, name: name);
      final now = clock().toUtc();
      final metadata = _composeMetadata(
        additionalMetadata,
        gameId: identity.gameId,
        name: identity.name,
        kind: kind,
        identityPolicy: null,
        createdAt: now,
        updatedAt: now,
      );
      await _writeMetadata(metadataFile, metadata);
      return ProvisionedProject(
        gameId: identity.gameId,
        name: identity.name,
        kind: kind,
        root: root,
        created: false,
        metadata: Map.unmodifiable(metadata),
      );
    });
  }

  Future<ProvisionedProject> updateMetadata({
    required String gameId,
    required PlaymeshProjectKind kind,
    String? name,
    required Map<String, Object?> Function(Map<String, Object?> current) update,
  }) {
    final normalized = _validateStoredGameId(
      gameId,
      allowAndroidApplicationId: kind == PlaymeshProjectKind.source,
    );
    return _serialize(normalized, () async {
      final root = _projectRoot(await _projectsRoot(), normalized);
      if (!await root.exists()) throw ProjectProvisioningMissing(normalized);
      final file = _metadataFile(root);
      final existing = await _readMetadata(file);
      if (existing == null) throw ProjectProvisioningMissing(normalized);
      final opened = _validatedProject(
        root: root,
        metadata: existing,
        gameId: normalized,
        kind: kind,
        created: false,
      );
      final parsedExisting = _parseMetadata(existing);
      final normalizedName = name == null
          ? opened.name
          : _validateStoredIdentity(
              gameId: normalized,
              name: name,
              identityPolicy: parsedExisting.identityPolicy,
            ).name;
      final updated = _composeMetadata(
        update(Map<String, Object?>.from(existing)),
        gameId: normalized,
        name: normalizedName,
        kind: kind,
        identityPolicy: parsedExisting.identityPolicy,
        createdAt: DateTime.parse(existing['createdAt']! as String),
        updatedAt: clock().toUtc(),
      );
      await _writeMetadata(file, updated);
      return ProvisionedProject(
        gameId: normalized,
        name: normalizedName,
        kind: kind,
        root: root,
        created: false,
        metadata: Map.unmodifiable(updated),
      );
    });
  }

  /// 枚举指定产品类型的托管项目。
  ///
  /// 未包含 `.playmesh/project.json` 的普通目录不是托管项目；已声明为其他
  /// 合法 kind 的项目也不会进入结果。其余不可判定或身份不一致的根会作为
  /// typed diagnostic 返回，避免静默漏项，并把最终容错策略留给 controller。
  Future<ProjectProvisioningListResult> listProjects({
    required PlaymeshProjectKind kind,
  }) async {
    final projectsRoot = await _projectsRoot();
    final entities = await projectsRoot.list(followLinks: false).toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    final projects = <ProvisionedProject>[];
    final diagnostics = <ProjectProvisioningListDiagnostic>[];

    for (final entity in entities) {
      if (entity is! Directory) continue;
      final directoryName = _pathBasename(entity.path);
      final metadataFile = _metadataFile(entity);
      if (!await metadataFile.exists()) continue;

      late final Map<String, Object?> metadata;
      try {
        final decoded = jsonDecode(await metadataFile.readAsString());
        if (decoded is! Map) {
          throw const FormatException('Playmesh 项目元数据无效');
        }
        metadata = Map<String, Object?>.from(decoded);
      } on FileSystemException {
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic.metadataUnreadableCode,
            directoryName: directoryName,
          ),
        );
        continue;
      } on FormatException {
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic.metadataInvalidCode,
            directoryName: directoryName,
          ),
        );
        continue;
      }

      final rawKind = metadata['kind'];
      if (rawKind != kind.wireName) {
        if (rawKind is String) {
          try {
            if (PlaymeshProjectKind.parse(rawKind) != kind) continue;
          } on FormatException {
            // 未知 kind 无法安全归入任一产品入口，必须显式报告。
          }
        }
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic.metadataInvalidCode,
            directoryName: directoryName,
            gameId: metadata['gameId'] is String
                ? metadata['gameId']! as String
                : null,
          ),
        );
        continue;
      }

      try {
        final parsed = _parseMetadata(metadata);
        if (directoryName != parsed.gameId) {
          diagnostics.add(
            ProjectProvisioningListDiagnostic(
              code: ProjectProvisioningListDiagnostic.rootIdentityMismatchCode,
              directoryName: directoryName,
              gameId: parsed.gameId,
            ),
          );
          continue;
        }
        projects.add(
          _validatedProject(
            root: entity,
            metadata: metadata,
            gameId: parsed.gameId,
            kind: kind,
            created: false,
          ),
        );
      } on FormatException {
        diagnostics.add(
          ProjectProvisioningListDiagnostic(
            code: ProjectProvisioningListDiagnostic.metadataInvalidCode,
            directoryName: directoryName,
            gameId: metadata['gameId'] is String
                ? metadata['gameId']! as String
                : null,
          ),
        );
      }
    }

    projects.sort((left, right) => left.gameId.compareTo(right.gameId));
    diagnostics.sort((left, right) {
      final directory = left.directoryName.compareTo(right.directoryName);
      return directory != 0 ? directory : left.code.compareTo(right.code);
    });
    return ProjectProvisioningListResult(
      projects: List.unmodifiable(projects),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  Future<Directory> projectsRoot() => _projectsRoot();

  Future<Directory> projectRoot(String gameId) async =>
      _projectRoot(await _projectsRoot(), validateGameId(gameId));

  Future<Directory> _projectsRoot() async {
    final cached = _resolvedProjectsRoot;
    if (cached != null) return cached;
    final injected = _injectedProjectsRoot;
    if (injected != null) {
      await injected.create(recursive: true);
      return _resolvedProjectsRoot = injected;
    }
    final library = await PlaymeshLibraryRoot.resolve();
    final resolved = Directory(
      '${library.path}${Platform.pathSeparator}packages',
    );
    await resolved.create(recursive: true);
    return _resolvedProjectsRoot = resolved;
  }

  Directory _projectRoot(Directory projects, String gameId) {
    final root = Directory('${projects.path}${Platform.pathSeparator}$gameId');
    final projectsPath = projects.absolute.path;
    final rootPath = root.absolute.path;
    final prefix = '$projectsPath${Platform.pathSeparator}';
    final withinRoot = Platform.isWindows
        ? rootPath.toLowerCase().startsWith(prefix.toLowerCase())
        : rootPath.startsWith(prefix);
    if (!withinRoot) throw const FormatException('Playmesh 项目根越界');
    return root;
  }

  File _metadataFile(Directory root) => File(
    '${root.path}${Platform.pathSeparator}.playmesh'
    '${Platform.pathSeparator}project.json',
  );

  Future<Map<String, Object?>?> _readMetadata(File file) async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('Playmesh 项目元数据无效');
    final metadata = Map<String, Object?>.from(decoded);
    _parseMetadata(metadata);
    return metadata;
  }

  ProvisionedProject _validatedProject({
    required Directory root,
    required Map<String, Object?> metadata,
    required String gameId,
    required PlaymeshProjectKind kind,
    required bool created,
  }) {
    final parsed = _parseMetadata(metadata);
    if (parsed.gameId != gameId || parsed.kind != kind) {
      throw ProjectProvisioningConflict(
        gameId: gameId,
        requestedKind: kind,
        existingKind: parsed.kind,
      );
    }
    return ProvisionedProject(
      gameId: parsed.gameId,
      name: parsed.name,
      kind: parsed.kind,
      root: root,
      created: created,
      metadata: Map.unmodifiable(metadata),
    );
  }

  ({
    String gameId,
    String name,
    PlaymeshProjectKind kind,
    String? identityPolicy,
  })
  _parseMetadata(Map<String, Object?> metadata) {
    final gameId = metadata['gameId'];
    final name = metadata['name'];
    final kind = metadata['kind'];
    final createdAt = metadata['createdAt'];
    final updatedAt = metadata['updatedAt'];
    final identityPolicy = metadata['identityPolicy'];
    if (metadata['schemaVersion'] != metadataSchemaVersion ||
        gameId is! String ||
        name is! String ||
        kind is! String ||
        (identityPolicy != null &&
            identityPolicy != _androidApplicationIdIdentityPolicy) ||
        createdAt is! String ||
        updatedAt is! String ||
        DateTime.tryParse(createdAt) == null ||
        DateTime.tryParse(updatedAt) == null) {
      throw const FormatException('Playmesh 项目元数据无效');
    }
    final parsedKind = PlaymeshProjectKind.parse(kind);
    if (identityPolicy == _androidApplicationIdIdentityPolicy &&
        parsedKind != PlaymeshProjectKind.source) {
      throw const FormatException('Playmesh 项目元数据无效');
    }
    final identity = _validateStoredIdentity(
      gameId: gameId,
      name: name,
      identityPolicy: identityPolicy as String?,
    );
    return (
      gameId: identity.gameId,
      name: identity.name,
      kind: parsedKind,
      identityPolicy: identityPolicy,
    );
  }

  Map<String, Object?> _composeMetadata(
    Map<String, Object?> additional, {
    required String gameId,
    required String name,
    required PlaymeshProjectKind kind,
    required String? identityPolicy,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    final sanitized = Map<String, Object?>.from(additional)
      ..remove('identityPolicy');
    return <String, Object?>{
      ...sanitized,
      'schemaVersion': metadataSchemaVersion,
      'kind': kind.wireName,
      'gameId': gameId,
      'name': name,
      'identityPolicy': ?identityPolicy,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  Future<void> _writeMetadata(File file, Map<String, Object?> metadata) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    await temporary.writeAsString(jsonEncode(metadata), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await file.exists()) await file.delete();
      if (await backup.exists()) await backup.rename(file.path);
      rethrow;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<ProjectProvisioningConflict> _conflict(
    Directory root,
    String gameId,
    PlaymeshProjectKind requestedKind,
  ) async {
    PlaymeshProjectKind? existingKind;
    try {
      if (await root.exists()) {
        final metadata = await _readMetadata(_metadataFile(root));
        if (metadata != null) existingKind = _parseMetadata(metadata).kind;
      }
    } on Object {
      // A malformed or legacy root still owns the gameId; do not overwrite it.
    }
    return ProjectProvisioningConflict(
      gameId: gameId,
      requestedKind: requestedKind,
      existingKind: existingKind,
    );
  }

  Future<T> _serialize<T>(String gameId, Future<T> Function() action) {
    final key =
        '${_injectedProjectsRoot?.absolute.path ?? '<default>'}\n$gameId';
    final previous = _projectTails[key] ?? Future<void>.value();
    final completer = Completer<void>();
    _projectTails[key] = completer.future;
    return previous.then((_) => action()).whenComplete(() {
      completer.complete();
      if (identical(_projectTails[key], completer.future)) {
        _projectTails.remove(key);
      }
    });
  }
}

Future<bool> _pathExists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;

String _pathBasename(String path) => path.split(Platform.pathSeparator).last;

Future<Directory> _renameDirectoryWithRetry(
  Directory source,
  String destination,
) async {
  FileSystemException? lastError;
  for (var attempt = 0; attempt < 10; attempt += 1) {
    try {
      return await source.rename(destination);
    } on FileSystemException catch (error) {
      lastError = error;
      final code = error.osError?.errorCode;
      if (!Platform.isWindows || (code != 5 && code != 32) || attempt == 9) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 50 * (attempt + 1)));
    }
  }
  throw lastError ?? FileSystemException('项目目录原子写入失败', source.path);
}
