import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:archive/archive.dart';

import '../../models/game_summary.dart';
import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_capability_registry.dart';
import '../../models/local_game_entry.dart';
import '../game_package/game_library_repository.dart';
import '../library/playmesh_library_root.dart';
import 'developer_local_history.dart';
import 'developer_project_validation.dart';

export 'developer_local_history.dart';
export 'developer_project_validation.dart';

class DeveloperProject {
  const DeveloperProject({
    required this.id,
    required this.name,
    required this.version,
    required this.rootAssetPath,
    required this.readOnly,
    this.rootFilePath,
  });

  final String id;
  final String name;
  final String version;
  final String rootAssetPath;
  final String? rootFilePath;
  final bool readOnly;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'readOnly': readOnly,
    'manifestReadOnly': false,
    'manifestIdReadOnly': true,
  };
}

class DeveloperProjectFile {
  const DeveloperProjectFile({
    required this.path,
    required this.bytes,
    required this.contentType,
    this.readOnly = false,
    this.revision = 0,
  });

  final String path;
  final Uint8List bytes;
  final String contentType;
  final bool readOnly;
  final int revision;

  bool get isText =>
      contentType.startsWith('text/') ||
      contentType.startsWith('application/json');
}

class DeveloperProjectDraft {
  const DeveloperProjectDraft({
    required this.id,
    required this.name,
    required this.orientation,
    required this.displayMode,
    required this.minPlayers,
    required this.maxPlayers,
    this.mode = 'multiplayer',
    this.description = '',
    this.tags = const [],
    this.requiredCapabilities = const [],
  });

  final String id;
  final String name;
  final GameOrientation orientation;
  final String displayMode;
  final int minPlayers;
  final int maxPlayers;
  final String mode;
  final String description;
  final List<String> tags;
  final List<String> requiredCapabilities;
}

class DeveloperFileDiff {
  const DeveloperFileDiff({
    required this.path,
    required this.changed,
    required this.original,
    required this.current,
  });

  final String path;
  final bool changed;
  final String original;
  final String current;

  Map<String, Object?> toJson() => {
    'path': path,
    'changed': changed,
    'original': original,
    'current': current,
  };
}

class DeveloperRevisionConflict implements Exception {
  const DeveloperRevisionConflict(this.currentRevision);

  final int currentRevision;
}

abstract interface class DeveloperProjectCatalog {
  Future<List<DeveloperProject>> listProjects();

  Future<DeveloperProject> createProject(DeveloperProjectDraft draft);

  Future<List<String>> listFiles(String projectId);

  Future<List<String>> listDirectories(String projectId);

  Future<void> createDirectory(String projectId, String path);

  Future<void> deleteDirectory(String projectId, String path);

  Future<void> copyEntry(String projectId, String source, String destination);

  Future<void> moveEntry(String projectId, String source, String destination);

  Future<List<String>> extractZip(
    String projectId,
    String archivePath,
    String destinationDirectory,
  );

  Future<DeveloperProjectFile> readFile(String projectId, String path);

  Future<DeveloperProjectFile> updateManifest(
    String projectId,
    Map<String, Object?> manifest, {
    int? expectedRevision,
  });

  Future<DeveloperProjectFile> writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  });

  Future<List<DeveloperProjectFile>> writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  });

  Future<void> deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  });

  Future<DeveloperFileDiff> diffFile(String projectId, String path);

  Future<List<DeveloperLocalHistoryOperation>> listLocalHistory(
    String projectId,
    String path,
  );

  Future<DeveloperLocalHistoryDiff> localHistoryDiff(
    String projectId,
    String operationId,
    String path,
  );

  Future<void> restoreLocalHistory(
    String projectId,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  );

  Future<DeveloperProjectValidationReport> validateProject(String projectId);

  /// Deletes only the current game's persisted SDK data directory.
  /// Project sources, cache and local history are preserved.
  Future<bool> clearGameData(String projectId);

  Future<GameSummary> prepareGame(String projectId);
}

class GameLibraryDeveloperProjectCatalog implements DeveloperProjectCatalog {
  GameLibraryDeveloperProjectCatalog(
    this.repository, {
    AssetBundle? bundle,
    Directory? workspaceRoot,
  }) : bundle = bundle ?? rootBundle,
       _injectedWorkspaceRoot = workspaceRoot;

  static const _maxFileBytes = 2 * 1024 * 1024;
  static const _templateRoot =
      'assets/playmesh-library/public/developer/templates/default-game/package';

  final GameLibraryRepository repository;
  final AssetBundle bundle;
  final Directory? _injectedWorkspaceRoot;
  final DeveloperLocalHistoryStore _localHistory = DeveloperLocalHistoryStore();
  final DeveloperProjectValidator _validator =
      const DeveloperProjectValidator();
  Directory? _resolvedWorkspaceRoot;
  Map<String, List<String>>? _assetFiles;
  final Map<String, int> _revisions = {};

  @override
  Future<List<DeveloperProject>> listProjects() async {
    if (repository.cachedGames.isEmpty) await repository.refresh();
    final projects = <DeveloperProject>[
      for (final game in repository.cachedGames)
        DeveloperProject(
          id: game.id,
          name: game.name,
          version: game.version,
          rootAssetPath: game.entry.packageRootAssetPath ?? _templateRoot,
          rootFilePath: game.entry.packageRootFilePath,
          readOnly: false,
        ),
    ];
    final known = projects.map((project) => project.id).toSet();
    for (final project in await _customProjects()) {
      if (known.add(project.id)) projects.add(project);
    }
    projects.sort((left, right) => left.name.compareTo(right.name));
    return List.unmodifiable(projects);
  }

  @override
  Future<DeveloperProject> createProject(DeveloperProjectDraft draft) async {
    final id = draft.id.trim();
    final name = draft.name.trim();
    final description = draft.description.trim();
    if (!RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)+$').hasMatch(id)) {
      throw const FormatException('项目 ID 必须是小写反向域名格式');
    }
    if (name.isEmpty || name.length > 80) {
      throw const FormatException('项目名称长度必须为 1 到 80 个字符');
    }
    if (description.length > 500) {
      throw const FormatException('项目描述不能超过 500 个字符');
    }
    if (draft.tags.length > 20 ||
        draft.tags.any((tag) => tag.trim().isEmpty || tag.trim().length > 64)) {
      throw const FormatException('标签最多 20 个，且每个标签长度必须为 1 到 64 个字符');
    }
    for (final capability in draft.requiredCapabilities) {
      if (!gameCapabilityRegistry.containsKey(capability)) {
        throw FormatException('未知能力 code：$capability');
      }
    }
    if (draft.minPlayers < 1 || draft.maxPlayers < draft.minPlayers) {
      throw const FormatException('玩家人数必须满足 1 <= min <= max');
    }
    if (draft.mode != 'solo' && draft.mode != 'multiplayer') {
      throw const FormatException('不支持的游戏模式');
    }
    if (draft.displayMode != 'multi_screen' &&
        draft.displayMode != 'single_screen_multiplayer') {
      throw const FormatException('不支持的显示模式');
    }
    if (draft.mode == 'solo' &&
        (draft.displayMode != 'multi_screen' ||
            draft.minPlayers != 1 ||
            draft.maxPlayers != 1)) {
      throw const FormatException('单机项目必须使用 multi_screen 且玩家人数为 1');
    }
    if ((await listProjects()).any((project) => project.id == id)) {
      throw StateError('项目 ID 已存在');
    }

    final root = await _workspaceRoot();
    final target = Directory('${root.path}${Platform.pathSeparator}$id');
    if (await target.exists()) throw StateError('项目目录已存在');
    final staging = Directory(
      '${root.path}${Platform.pathSeparator}.playmesh-create-'
      '${DateTime.now().toUtc().microsecondsSinceEpoch}',
    );
    try {
      await staging.create(recursive: true);
      final manifest = await AssetManifest.loadFromAssetBundle(bundle);
      final prefix = '$_templateRoot/';
      final assets = manifest
          .listAssets()
          .where((asset) => asset.startsWith(prefix))
          .toList();
      if (assets.isEmpty) throw StateError('默认项目模板不存在');
      for (final asset in assets) {
        final relative = asset.substring(prefix.length);
        final data = await bundle.load(asset);
        final file = _resolveFile(staging, relative);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      final manifestFile = _resolveFile(staging, 'main.json');
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map) throw StateError('默认项目模板清单无效');
      final manifestJson = Map<String, Object?>.from(decoded)
        ..['id'] = id
        ..['name'] = name
        ..['remarks'] = description
        ..['orientation'] = draft.orientation.manifestValue
        ..['modes'] = [draft.mode]
        ..['displayModes'] = [draft.displayMode]
        ..['tags'] = draft.tags.map((tag) => tag.trim()).toSet().toList()
        ..['players'] = {'min': draft.minPlayers, 'max': draft.maxPlayers};
      if (draft.mode == 'solo') {
        manifestJson.remove('authority');
        await _replaceWithSoloSkeleton(staging);
      } else if (draft.displayMode == 'multi_screen') {
        await _removeControllerSkeleton(staging);
      }
      GameManifest.fromJson(manifestJson);
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifestJson),
        flush: true,
      );
      if (draft.requiredCapabilities.isNotEmpty) {
        await _resolveFile(staging, 'capabilities.json').writeAsString(
          const JsonEncoder.withIndent(
            ' ',
          ).convert({'required': draft.requiredCapabilities.toSet().toList()}),
          flush: true,
        );
      }
      await _renameDirectoryWithRetry(staging, target.path);
    } on Object {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
    final game = await _customGame(target);
    repository.upsert(game);
    return DeveloperProject(
      id: game.id,
      name: game.name,
      version: game.version,
      rootAssetPath: _templateRoot,
      readOnly: false,
    );
  }

  @override
  Future<List<String>> listFiles(String projectId) async {
    final directory = await _ensureWorkspace(projectId);
    final files = <String>[];
    await for (final entity in _visibleWorkspaceEntities(directory)) {
      if (entity is! File) continue;
      final relative = _relativePath(directory, entity.path);
      if (!_isInternalProjectPath(relative)) files.add(relative);
    }
    files.sort();
    return List.unmodifiable(files);
  }

  @override
  Future<List<String>> listDirectories(String projectId) async {
    final directory = await _ensureWorkspace(projectId);
    final directories = <String>[];
    await for (final entity in _visibleWorkspaceEntities(directory)) {
      if (entity is! Directory) continue;
      final relative = _relativePath(directory, entity.path);
      if (!_isInternalProjectPath(relative)) {
        directories.add(relative);
      }
    }
    directories.sort();
    return List.unmodifiable(directories);
  }

  @override
  Future<void> createDirectory(String projectId, String path) async {
    final normalized = _normalizeWritablePath(path);
    final workspace = await _ensureWorkspace(projectId);
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '创建文件夹 $normalized',
      path: normalized,
      action: () => _createDirectory(projectId, normalized),
    );
  }

  Future<void> _createDirectory(String projectId, String path) async {
    final normalized = _normalizeWritablePath(path);
    final workspace = await _ensureWorkspace(projectId);
    final directory = _resolveDirectory(workspace, normalized);
    if (await directory.exists()) {
      throw const FormatException('项目文件夹已存在');
    }
    if (await _resolveFile(workspace, normalized).exists()) {
      throw const FormatException('同名项目文件已存在');
    }
    await directory.create(recursive: true);
  }

  @override
  Future<void> deleteDirectory(String projectId, String path) async {
    final normalized = _normalizeWritablePath(path);
    if (normalized == 'app') {
      throw const FormatException('app 是项目必需根目录，不能删除');
    }
    final workspace = await _ensureWorkspace(projectId);
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '删除文件夹 $normalized',
      path: normalized,
      action: () => _deleteDirectory(projectId, normalized),
    );
  }

  Future<void> _deleteDirectory(String projectId, String path) async {
    final normalized = _normalizeWritablePath(path);
    final workspace = await _ensureWorkspace(projectId);
    final directory = _resolveDirectory(workspace, normalized);
    if (!await directory.exists()) {
      throw StateError('项目文件夹不存在');
    }
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = _relativePath(workspace, entity.path);
      _revisions.update(
        _revisionKey(projectId, relative),
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    await directory.delete(recursive: true);
  }

  @override
  Future<void> copyEntry(
    String projectId,
    String source,
    String destination,
  ) async {
    final from = _normalizeWritablePath(source);
    final to = _normalizeWritablePath(destination);
    if (_pathContains(from, to)) {
      throw const FormatException('目标不能位于来源目录内部');
    }
    final workspace = await _ensureWorkspace(projectId);
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '复制 $from 到 $to',
      path: _commonParent([from, to]),
      action: () => _copyEntry(workspace, from, to),
    );
  }

  Future<void> _copyEntry(Directory workspace, String from, String to) async {
    final sourceFile = _resolveFile(workspace, from);
    final sourceDirectory = _resolveDirectory(workspace, from);
    final targetFile = _resolveFile(workspace, to);
    final targetDirectory = _resolveDirectory(workspace, to);
    if (await targetFile.exists() || await targetDirectory.exists()) {
      throw const FormatException('目标路径已存在');
    }
    if (await sourceFile.exists()) {
      await targetFile.parent.create(recursive: true);
      await sourceFile.copy(targetFile.path);
      return;
    }
    if (!await sourceDirectory.exists()) throw StateError('来源路径不存在');
    await targetDirectory.create(recursive: true);
    await for (final entity in sourceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) throw const FormatException('工作区不允许复制符号链接');
      final suffix = entity.path.substring(sourceDirectory.path.length + 1);
      if (entity is Directory) {
        await Directory(
          '${targetDirectory.path}${Platform.pathSeparator}$suffix',
        ).create(recursive: true);
      } else if (entity is File) {
        final output = File(
          '${targetDirectory.path}${Platform.pathSeparator}$suffix',
        );
        await output.parent.create(recursive: true);
        await entity.copy(output.path);
      }
    }
  }

  @override
  Future<void> moveEntry(
    String projectId,
    String source,
    String destination,
  ) async {
    final from = _normalizeWritablePath(source);
    final to = _normalizeWritablePath(destination);
    if (from == 'app') throw const FormatException('app 是项目必需根目录，不能移动');
    if (_pathContains(from, to)) {
      throw const FormatException('目标不能位于来源目录内部');
    }
    final workspace = await _ensureWorkspace(projectId);
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '移动 $from 到 $to',
      path: _commonParent([from, to]),
      action: () async {
        final sourceFile = _resolveFile(workspace, from);
        final sourceDirectory = _resolveDirectory(workspace, from);
        final targetFile = _resolveFile(workspace, to);
        final targetDirectory = _resolveDirectory(workspace, to);
        if (await targetFile.exists() || await targetDirectory.exists()) {
          throw const FormatException('目标路径已存在');
        }
        await targetFile.parent.create(recursive: true);
        if (await sourceFile.exists()) {
          await sourceFile.rename(targetFile.path);
        } else if (await sourceDirectory.exists()) {
          await sourceDirectory.rename(targetDirectory.path);
        } else {
          throw StateError('来源路径不存在');
        }
      },
    );
  }

  @override
  Future<List<String>> extractZip(
    String projectId,
    String archivePath,
    String destinationDirectory,
  ) async {
    final source = _normalizeWritablePath(archivePath);
    if (!source.toLowerCase().endsWith('.zip')) {
      throw const FormatException('仅支持解压 .zip 压缩包');
    }
    final destination = destinationDirectory.trim().isEmpty
        ? ''
        : _normalizeWritablePath(destinationDirectory);
    final workspace = await _ensureWorkspace(projectId);
    final zipFile = _resolveFile(workspace, source);
    if (!await zipFile.exists()) throw StateError('压缩文件不存在');
    if (await zipFile.length() > 64 * 1024 * 1024) {
      throw const FormatException('ZIP 文件不能超过 64 MiB');
    }
    final archive = ZipDecoder().decodeBytes(
      await zipFile.readAsBytes(),
      verify: true,
    );
    final extracted = <({String path, ArchiveFile entry})>[];
    final targets = <String>{};
    var totalBytes = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) throw const FormatException('ZIP 不允许包含符号链接');
      final raw = entry.name.replaceAll('\\', '/');
      if (raw.endsWith('/') || !entry.isFile) continue;
      final relative = _normalizePath(raw);
      final target = _normalizeWritablePath(
        destination.isEmpty ? relative : '$destination/$relative',
      );
      if (entry.size > _maxFileBytes) {
        throw FormatException('解压后的单个文件不能超过 2 MiB：$relative');
      }
      totalBytes += entry.size;
      if (totalBytes > 64 * 1024 * 1024 || extracted.length >= 2048) {
        throw const FormatException('ZIP 解压内容超过 64 MiB 或 2048 个文件限制');
      }
      if (!targets.add(target)) throw FormatException('ZIP 包含重复路径：$target');
      if (await _resolveFile(workspace, target).exists() ||
          await _resolveDirectory(workspace, target).exists()) {
        throw FormatException('解压目标已存在：$target');
      }
      extracted.add((path: target, entry: entry));
    }
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '解压 $source 到 $destination',
      path: destination,
      action: () async {
        for (final item in extracted) {
          final output = _resolveFile(workspace, item.path);
          await output.parent.create(recursive: true);
          await output.writeAsBytes(
            item.entry.content as List<int>,
            flush: true,
          );
        }
      },
    );
    return List.unmodifiable(extracted.map((item) => item.path));
  }

  @override
  Future<DeveloperProjectFile> readFile(String projectId, String path) async {
    final normalized = _normalizePath(path);
    final directory = await _ensureWorkspace(projectId);
    final file = _resolveFile(directory, normalized);
    if (!await file.exists()) throw StateError('项目文件不存在');
    return DeveloperProjectFile(
      path: normalized,
      bytes: await file.readAsBytes(),
      contentType: _contentType(normalized),
      readOnly: normalized == 'main.json',
      revision: _revisions[_revisionKey(projectId, normalized)] ?? 0,
    );
  }

  @override
  Future<DeveloperProjectFile> updateManifest(
    String projectId,
    Map<String, Object?> manifest, {
    int? expectedRevision,
  }) async {
    final workspace = await _ensureWorkspace(projectId);
    final currentFile = _resolveFile(workspace, 'main.json');
    final currentJson = jsonDecode(await currentFile.readAsString());
    if (currentJson is! Map) throw const FormatException('项目 main.json 无效');
    final currentId = Map<String, Object?>.from(currentJson)['id'];
    if (currentId is! String || currentId.isEmpty) {
      throw const FormatException('项目 main.json 缺少有效 id');
    }
    final requestedId = manifest['id'];
    if (requestedId != null && requestedId != currentId) {
      throw const FormatException('main.json.id 是项目稳定标识，不能修改');
    }
    final normalized = Map<String, Object?>.from(manifest)..['id'] = currentId;
    GameManifest.fromJson(normalized);
    final encoded = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(normalized)}\n',
    );
    if (encoded.length > _maxFileBytes) {
      throw const FormatException('main.json 不能超过 2 MiB');
    }
    _checkRevision(projectId, 'main.json', expectedRevision);
    final temporary = File('${currentFile.path}.playmesh-tmp');
    await temporary.writeAsBytes(encoded, flush: true);
    if (await currentFile.exists()) await currentFile.delete();
    await temporary.rename(currentFile.path);
    _revisions.update(
      _revisionKey(projectId, 'main.json'),
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    repository.upsert(await _customGame(workspace));
    return readFile(projectId, 'main.json');
  }

  @override
  Future<DeveloperProjectFile> writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  }) async {
    final normalized = _normalizeWritablePath(path);
    final workspace = await _ensureWorkspace(projectId);
    return _localHistory.recordMutation(
      workspace: workspace,
      label: '保存文件 $normalized',
      path: normalized,
      action: () => _writeFile(
        projectId,
        normalized,
        bytes,
        expectedRevision: expectedRevision,
      ),
    );
  }

  Future<DeveloperProjectFile> _writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  }) async {
    final normalized = _normalizeWritablePath(path);
    if (bytes.length > _maxFileBytes) {
      throw const FormatException('单个开发文件不能超过 2 MiB');
    }
    final directory = await _ensureWorkspace(projectId);
    final file = _resolveFile(directory, normalized);
    _checkRevision(projectId, normalized, expectedRevision);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.playmesh-tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    _revisions.update(
      _revisionKey(projectId, normalized),
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    return readFile(projectId, normalized);
  }

  @override
  Future<List<DeveloperProjectFile>> writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  }) async {
    final workspace = await _ensureWorkspace(projectId);
    final paths = files.keys.map(_normalizeWritablePath).toList()..sort();
    return _localHistory.recordMutation(
      workspace: workspace,
      label: '批量修改 ${paths.length} 个文件',
      path: _commonParent(paths),
      action: () => _writeFilesAtomic(
        projectId,
        files,
        expectedRevisions: expectedRevisions,
      ),
    );
  }

  Future<List<DeveloperProjectFile>> _writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  }) async {
    if (files.isEmpty) throw const FormatException('批量修改不能为空');
    final normalizedFiles = <String, List<int>>{};
    for (final entry in files.entries) {
      final path = _normalizeWritablePath(entry.key);
      if (entry.value.length > _maxFileBytes) {
        throw const FormatException('单个开发文件不能超过 2 MiB');
      }
      normalizedFiles[path] = entry.value;
    }

    final directory = await _ensureWorkspace(projectId);
    final originals = <String, Uint8List?>{};
    for (final path in normalizedFiles.keys) {
      _checkRevision(projectId, path, expectedRevisions?[path]);
      final target = _resolveFile(directory, path);
      originals[path] = await target.exists()
          ? await target.readAsBytes()
          : null;
    }

    final transactionId = DateTime.now().toUtc().microsecondsSinceEpoch;
    final temporaryFiles = <String, File>{};
    try {
      for (final entry in normalizedFiles.entries) {
        final target = _resolveFile(directory, entry.key);
        await target.parent.create(recursive: true);
        final temporary = File('${target.path}.playmesh-batch-$transactionId');
        await temporary.writeAsBytes(entry.value, flush: true);
        temporaryFiles[entry.key] = temporary;
      }
      for (final entry in temporaryFiles.entries) {
        final target = _resolveFile(directory, entry.key);
        if (await target.exists()) await target.delete();
        await entry.value.rename(target.path);
      }
    } on Object {
      for (final path in normalizedFiles.keys) {
        final target = _resolveFile(directory, path);
        final original = originals[path];
        if (original == null) {
          if (await target.exists()) await target.delete();
        } else {
          await target.parent.create(recursive: true);
          await target.writeAsBytes(original, flush: true);
        }
      }
      rethrow;
    } finally {
      for (final temporary in temporaryFiles.values) {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    for (final path in normalizedFiles.keys) {
      _revisions.update(
        _revisionKey(projectId, path),
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    return Future.wait(
      normalizedFiles.keys.map((path) => readFile(projectId, path)),
    );
  }

  @override
  Future<void> deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  }) async {
    final normalized = _normalizeWritablePath(path);
    final workspace = await _ensureWorkspace(projectId);
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '删除文件 $normalized',
      path: normalized,
      action: () => _deleteFile(
        projectId,
        normalized,
        expectedRevision: expectedRevision,
      ),
    );
  }

  Future<void> _deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  }) async {
    final normalized = _normalizeWritablePath(path);
    final directory = await _ensureWorkspace(projectId);
    final file = _resolveFile(directory, normalized);
    _checkRevision(projectId, normalized, expectedRevision);
    if (!await file.exists()) throw StateError('项目文件不存在');
    await file.delete();
    _revisions.update(
      _revisionKey(projectId, normalized),
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }

  @override
  Future<DeveloperFileDiff> diffFile(String projectId, String path) async {
    final normalized = _normalizePath(path);
    final project = await _project(projectId);
    final current = await readFile(projectId, normalized);
    if (!current.isText) throw const FormatException('仅文本文件支持 Diff');
    var original = '';
    try {
      original = await bundle.loadString(
        '${project.rootAssetPath}/$normalized',
      );
    } on Object {
      // 新建文件没有原始资源。
    }
    final currentText = utf8.decode(current.bytes);
    return DeveloperFileDiff(
      path: normalized,
      changed: original != currentText,
      original: original,
      current: currentText,
    );
  }

  @override
  Future<List<DeveloperLocalHistoryOperation>> listLocalHistory(
    String projectId,
    String path,
  ) async {
    final normalized = _normalizeHistoryPath(path);
    final workspace = await _ensureWorkspace(projectId);
    return _localHistory.list(workspace, normalized);
  }

  @override
  Future<DeveloperLocalHistoryDiff> localHistoryDiff(
    String projectId,
    String operationId,
    String path,
  ) async {
    final normalized = _normalizeHistoryPath(path);
    final workspace = await _ensureWorkspace(projectId);
    return _localHistory.diff(workspace, operationId, normalized);
  }

  @override
  Future<void> restoreLocalHistory(
    String projectId,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  ) async {
    final normalized = _normalizeHistoryPath(path);
    if (normalized == 'main.json') {
      throw const FormatException('main.json 由平台管理，不能从本地历史替换');
    }
    final workspace = await _ensureWorkspace(projectId);
    final before = (await listFiles(projectId)).toSet();
    await _localHistory.recordMutation(
      workspace: workspace,
      label: '恢复本地历史 ${normalized.isEmpty ? '整个工作区' : normalized}',
      path: normalized,
      forceNew: true,
      action: () =>
          _localHistory.restore(workspace, operationId, normalized, version),
    );
    final after = (await listFiles(projectId)).toSet();
    for (final file in {...before, ...after}) {
      if (normalized.isNotEmpty && !_pathContains(normalized, file)) continue;
      if (file == 'main.json') continue;
      _revisions.update(
        _revisionKey(projectId, file),
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
  }

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async {
    final workspace = await _ensureWorkspace(projectId);
    return _validator.validate(projectId: projectId, workspace: workspace);
  }

  @override
  Future<bool> clearGameData(String projectId) async {
    final workspace = await _ensureWorkspace(projectId);
    final data = Directory('${workspace.path}${Platform.pathSeparator}data');
    if (!await data.exists()) return false;
    await data.delete(recursive: true);
    _revisions.removeWhere(
      (key, _) =>
          key.startsWith('$projectId\n') &&
          _pathContains('data', key.substring(projectId.length + 1)),
    );
    return true;
  }

  @override
  Future<GameSummary> prepareGame(String projectId) async {
    final validation = await validateProject(projectId);
    if (!validation.valid) {
      throw DeveloperProjectValidationFailure(validation);
    }
    final directory = await _ensureWorkspace(projectId);
    final bundled = repository.cachedGames.where(
      (candidate) => candidate.id == projectId,
    );
    if (bundled.isEmpty) return _customGame(directory);
    final game = bundled.first;
    return GameSummary(
      id: game.id,
      name: game.name,
      version: game.version,
      description: game.description,
      minPlayers: game.minPlayers,
      maxPlayers: game.maxPlayers,
      supportsMultiplayer: game.supportsMultiplayer,
      displayModeLabel: game.displayModeLabel,
      displayMode: game.displayMode,
      orientation: game.orientation,
      tags: game.tags,
      capabilities: await _readCustomCapabilities(directory),
      entry: LocalGameEntry(
        assetPath: game.entry.gameEntryPath,
        gameEntryPath: game.entry.gameEntryPath,
        controllerEntryPath: game.entry.controllerEntryPath,
        statusLabel: '${game.entry.statusLabel} · 开发副本',
        packageRootAssetPath: game.entry.packageRootAssetPath,
        packageRootFilePath: directory.path,
      ),
    );
  }

  Future<List<DeveloperProject>> _customProjects() async {
    final root = await _workspaceRoot();
    final projects = <DeveloperProject>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final manifestFile = File(
        '${entity.path}${Platform.pathSeparator}main.json',
      );
      final appDirectory = Directory(
        '${entity.path}${Platform.pathSeparator}app',
      );
      if (!await manifestFile.exists() || !await appDirectory.exists()) {
        continue;
      }
      try {
        final manifest = await _readCustomManifest(entity);
        projects.add(
          DeveloperProject(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            rootAssetPath: _templateRoot,
            readOnly: false,
          ),
        );
      } on Object {
        // One broken custom project must not hide the remaining projects.
      }
    }
    return projects;
  }

  Future<GameManifest> _readCustomManifest(Directory directory) async {
    final decoded = jsonDecode(
      await _resolveFile(directory, 'main.json').readAsString(),
    );
    if (decoded is! Map) throw const FormatException('项目 main.json 无效');
    return GameManifest.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<GameCapabilities> _readCustomCapabilities(Directory directory) async {
    final file = _resolveFile(directory, 'capabilities.json');
    if (!await file.exists()) return const GameCapabilities();
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('capabilities.json 根节点必须是对象');
    }
    return GameCapabilities.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<void> _replaceWithSoloSkeleton(Directory staging) async {
    final variant = await bundle.load(
      'assets/playmesh-library/public/developer/templates/default-game/'
      'variants/solo/player-index.js',
    );
    final playerEntry = _resolveFile(staging, 'app/static/js/player/index.js');
    await playerEntry.writeAsBytes(
      variant.buffer.asUint8List(variant.offsetInBytes, variant.lengthInBytes),
      flush: true,
    );
    await _removeControllerSkeleton(staging);
    final service = _resolveDirectory(staging, 'app/static/js/service');
    if (await service.exists()) await service.delete(recursive: true);
  }

  Future<void> _removeControllerSkeleton(Directory staging) async {
    for (final path in [
      'app/controller',
      'app/static/js/player/controller.js',
    ]) {
      final entity = path.endsWith('.js')
          ? _resolveFile(staging, path)
          : _resolveDirectory(staging, path);
      if (await entity.exists()) await entity.delete(recursive: true);
    }
  }

  Future<GameSummary> _customGame(Directory directory) async {
    final manifest = await _readCustomManifest(directory);
    final displayMode = manifest.displayModes.first;
    return GameSummary(
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      description: manifest.remarks,
      minPlayers: manifest.players.min,
      maxPlayers: manifest.players.max,
      supportsMultiplayer: manifest.supportsMultiplayer,
      displayModeLabel: displayMode == GameDisplayMode.singleScreenMultiplayer
          ? '大屏模式'
          : '多人多屏',
      displayMode: displayMode.manifestValue,
      orientation: manifest.orientation,
      tags: manifest.tags,
      capabilities: await _readCustomCapabilities(directory),
      entry: LocalGameEntry(
        assetPath: manifest.entries.game,
        gameEntryPath: manifest.entries.game,
        controllerEntryPath: manifest.entries.controller,
        statusLabel: 'Game SDK ${manifest.sdkVersion} · 开发项目',
        packageRootAssetPath: _templateRoot,
        packageRootFilePath: directory.path,
      ),
    );
  }

  Future<DeveloperProject> _project(String projectId) async {
    final projects = await listProjects();
    return projects.firstWhere(
      (project) => project.id == projectId,
      orElse: () => throw StateError('开发者项目不存在'),
    );
  }

  Future<Directory> _workspaceRoot() async {
    final cached = _resolvedWorkspaceRoot;
    if (cached != null) return cached;
    final root = _injectedWorkspaceRoot;
    if (root != null) {
      await root.create(recursive: true);
      return _resolvedWorkspaceRoot = root;
    }
    final libraryRoot = await PlaymeshLibraryRoot.resolve();
    final resolved = Directory(
      '${libraryRoot.path}${Platform.pathSeparator}packages',
    );
    await resolved.create(recursive: true);
    return _resolvedWorkspaceRoot = resolved;
  }

  Future<Directory> _ensureWorkspace(String projectId) async {
    final project = await _project(projectId);
    final root = await _workspaceRoot();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}${project.id}',
    );
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}main.json',
    );
    final appDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}app',
    );
    if (await manifestFile.exists() && await appDirectory.exists()) {
      return directory;
    }
    final sourcePath = project.rootFilePath;
    if (sourcePath != null) {
      final source = Directory(sourcePath);
      if (await source.exists() &&
          source.absolute.path != directory.absolute.path) {
        await directory.create(recursive: true);
        await _copyDirectoryContents(source, directory);
        return directory;
      }
    }
    await directory.create(recursive: true);
    final files = await _sourceFiles(project);
    for (final relative in files) {
      final target = _resolveFile(directory, relative);
      if (await target.exists()) continue;
      final data = await bundle.load('${project.rootAssetPath}/$relative');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return directory;
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == 'data' || name == 'cache' || name == '.playmesh') continue;
      final targetPath = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        final target = Directory(targetPath);
        await target.create(recursive: true);
        await _copyDirectoryContents(entity, target);
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }

  Stream<FileSystemEntity> _visibleWorkspaceEntities(
    Directory workspace, [
    Directory? current,
  ]) async* {
    final directory = current ?? workspace;
    await for (final entity in directory.list(followLinks: false)) {
      final relative = _relativePath(workspace, entity.path);
      if (_isInternalProjectPath(relative)) continue;
      yield entity;
      if (entity is Directory) {
        yield* _visibleWorkspaceEntities(workspace, entity);
      }
    }
  }

  Future<List<String>> _sourceFiles(DeveloperProject project) async {
    final cache = _assetFiles ??= {};
    final cached = cache[project.id];
    if (cached != null) return cached;
    final manifest = await AssetManifest.loadFromAssetBundle(bundle);
    final prefix = '${project.rootAssetPath}/';
    final files =
        manifest
            .listAssets()
            .where((asset) => asset.startsWith(prefix))
            .map((asset) => asset.substring(prefix.length))
            .where((path) => path.isNotEmpty)
            .toList()
          ..sort();
    return cache[project.id] = List.unmodifiable(files);
  }

  void _checkRevision(String projectId, String path, int? expectedRevision) {
    if (expectedRevision == null) return;
    final current = _revisions[_revisionKey(projectId, path)] ?? 0;
    if (current != expectedRevision) {
      throw DeveloperRevisionConflict(current);
    }
  }
}

String _normalizePath(String path) {
  final value = path.trim().replaceAll('\\', '/');
  final segments = value.split('/');
  if (value.isEmpty ||
      value.startsWith('/') ||
      {'.playmesh', 'cache', 'data'}.contains(segments.first) ||
      segments.any(
        (segment) =>
            segment.isEmpty ||
            segment == '.' ||
            segment == '..' ||
            segment.contains(RegExp(r'[<>:"|?*\x00-\x1f]')),
      )) {
    throw const FormatException('项目文件路径无效');
  }
  return value;
}

String _normalizeWritablePath(String path) {
  final normalized = _normalizePath(path);
  if (normalized == 'main.json') {
    throw const FormatException('main.json 由平台管理，开发者工作区不能修改');
  }
  return normalized;
}

String _normalizeHistoryPath(String path) {
  final value = path.trim();
  return value.isEmpty ? '' : _normalizePath(value);
}

String _commonParent(List<String> paths) {
  if (paths.isEmpty) return '';
  final common = paths.first.split('/').toList();
  for (final path in paths.skip(1)) {
    final parts = path.split('/');
    var length = 0;
    while (length < common.length &&
        length < parts.length &&
        common[length] == parts[length]) {
      length += 1;
    }
    common.removeRange(length, common.length);
  }
  return common.join('/');
}

bool _pathContains(String parent, String child) =>
    parent == child || child.startsWith('$parent/');

bool _isInternalProjectPath(String path) => {
  '.playmesh',
  'cache',
  'data',
}.any((root) => path == root || path.startsWith('$root/'));

File _resolveFile(Directory root, String path) {
  final normalized = _normalizePath(path);
  return File(
    '${root.path}${Platform.pathSeparator}'
    '${normalized.replaceAll('/', Platform.pathSeparator)}',
  );
}

Directory _resolveDirectory(Directory root, String path) {
  final normalized = _normalizePath(path);
  return Directory(
    '${root.path}${Platform.pathSeparator}'
    '${normalized.replaceAll('/', Platform.pathSeparator)}',
  );
}

String _relativePath(Directory root, String path) {
  final prefix = '${root.path}${Platform.pathSeparator}';
  if (!path.startsWith(prefix)) throw const FormatException('项目文件路径越界');
  return path.substring(prefix.length).replaceAll(Platform.pathSeparator, '/');
}

String _revisionKey(String projectId, String path) => '$projectId\n$path';

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
  throw lastError!;
}

String _contentType(String path) {
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.js') || path.endsWith('.mjs')) {
    return 'text/javascript; charset=utf-8';
  }
  if (path.endsWith('.json')) return 'application/json; charset=utf-8';
  if (path.endsWith('.md') || path.endsWith('.txt')) {
    return 'text/plain; charset=utf-8';
  }
  if (path.endsWith('.svg')) return 'image/svg+xml';
  if (path.endsWith('.png')) return 'image/png';
  if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
  if (path.endsWith('.gif')) return 'image/gif';
  if (path.endsWith('.webp')) return 'image/webp';
  return 'application/octet-stream';
}
