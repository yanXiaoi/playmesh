import 'dart:convert';
import 'dart:io';

import '../../models/game_manifest.dart';
import '../../models/game_capabilities.dart';
import '../../models/game_package_layout.dart';
import '../game_package/game_package_icon.dart';

enum DeveloperDiagnosticSeverity {
  error,
  warning,
  info;

  String get value => name;
}

class DeveloperProjectDiagnostic {
  const DeveloperProjectDiagnostic({
    required this.code,
    required this.severity,
    required this.message,
    required this.path,
    this.line,
    this.column,
    this.hint,
    this.messageArguments = const {},
    this.hintArguments = const {},
  });

  final String code;
  final DeveloperDiagnosticSeverity severity;
  final String message;
  final String path;
  final int? line;
  final int? column;
  final String? hint;
  final Map<String, Object?> messageArguments;
  final Map<String, Object?> hintArguments;

  Map<String, Object?> toJson() => {
    'code': code,
    'severity': severity.value,
    'message': message,
    'path': path,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
    if (hint != null) 'hint': hint,
    if (messageArguments.isNotEmpty) 'messageArguments': messageArguments,
    if (hintArguments.isNotEmpty) 'hintArguments': hintArguments,
  };
}

class DeveloperProjectValidationReport {
  const DeveloperProjectValidationReport({
    required this.projectId,
    required this.diagnostics,
    required this.fileCount,
    required this.totalBytes,
  });

  final String projectId;
  final List<DeveloperProjectDiagnostic> diagnostics;
  final int fileCount;
  final int totalBytes;

  bool get valid => !diagnostics.any(
    (diagnostic) => diagnostic.severity == DeveloperDiagnosticSeverity.error,
  );
  int get errorCount => diagnostics
      .where(
        (diagnostic) =>
            diagnostic.severity == DeveloperDiagnosticSeverity.error,
      )
      .length;
  int get warningCount => diagnostics
      .where(
        (diagnostic) =>
            diagnostic.severity == DeveloperDiagnosticSeverity.warning,
      )
      .length;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'valid': valid,
    'errorCount': errorCount,
    'warningCount': warningCount,
    'fileCount': fileCount,
    'totalBytes': totalBytes,
    'diagnostics': diagnostics.map((item) => item.toJson()).toList(),
  };
}

class DeveloperProjectValidationFailure implements Exception {
  const DeveloperProjectValidationFailure(this.report);

  final DeveloperProjectValidationReport report;
}

class DeveloperProjectValidator {
  const DeveloperProjectValidator();

  static const _blockedExtensions = {
    '.apk',
    '.app',
    '.bat',
    '.cmd',
    '.com',
    '.dll',
    '.dylib',
    '.exe',
    '.ipa',
    '.msi',
    '.ps1',
    '.sh',
    '.so',
  };
  static final _htmlReferencePattern = RegExp(
    r'''\b(?:src|href|poster)\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final _cssReferencePattern = RegExp(
    r'''url\(\s*["']?([^\s"')]+)["']?\s*\)''',
    caseSensitive: false,
  );
  static final _jsReferencePattern = RegExp(
    r'''(?:\bfrom\s*|\bimport\s*\(\s*)["']([^"']+)["']''',
  );

  Future<DeveloperProjectValidationReport> validate({
    required String projectId,
    required Directory workspace,
  }) async {
    final diagnostics = <DeveloperProjectDiagnostic>[];
    final files = <String, File>{};
    var totalBytes = 0;

    if (!await workspace.exists()) {
      diagnostics.add(
        _error(
          'project_root_missing',
          '',
          '项目工作区不存在',
          hint: '重新加载项目或重新创建开发副本。',
        ),
      );
      return DeveloperProjectValidationReport(
        projectId: projectId,
        diagnostics: diagnostics,
        fileCount: 0,
        totalBytes: 0,
      );
    }

    await for (final entity in workspace.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = _relativePath(workspace, entity.path);
      if (_isInternal(path)) continue;
      if (entity is Link) {
        diagnostics.add(
          _error(
            'symbolic_link_forbidden',
            path,
            '项目不能包含符号链接',
            hint: '删除链接并上传实际文件。',
          ),
        );
        continue;
      }
      if (entity is! File) continue;
      files[path] = entity;
      totalBytes += await entity.length();
      if (path.startsWith('app/')) {
        try {
          playmeshGamePackageLayout.validatePackagePath(path, field: '项目文件路径');
        } on FormatException catch (error) {
          diagnostics.add(
            _error(
              'reserved_runtime_namespace',
              path,
              error.message,
              hint: '将游戏资源移出 app/playmesh/ 和 app/bucket/，并使用未编码的规范路径。',
              messageArguments: {'path': path},
            ),
          );
        }
      }
      final extension = _extension(path);
      if (_blockedExtensions.contains(extension)) {
        diagnostics.add(
          _error(
            'forbidden_publish_file',
            path,
            '项目包含发布包禁止的可执行文件或脚本',
            hint: '删除该文件；游戏包只能包含网页资源。',
          ),
        );
      }
    }

    final manifestFile = files['main.json'];
    GameManifest? manifest;
    if (manifestFile == null) {
      diagnostics.add(
        _error(
          'manifest_missing',
          'main.json',
          '缺少 main.json',
          hint: 'main.json 由平台创建并管理。',
        ),
      );
    } else {
      manifest = await _validateManifest(projectId, manifestFile, diagnostics);
    }
    if (files['capabilities.json'] case final capabilitiesFile?) {
      await _validateCapabilities(
        capabilitiesFile,
        diagnostics,
        manifest: manifest,
      );
    }

    if (manifest != null) {
      final gameEntry = playmeshGamePackageLayout.parseWebEntry(
        manifest.entries.game,
        field: 'entries.game',
        kind: GameWebEntryKind.html,
      );
      _requireFile(
        files,
        diagnostics,
        playmeshGamePackageLayout.packagePathForWebPath(gameEntry.path),
        code: 'app_entry_missing',
        message: 'entries.game 指向的主游戏入口不存在',
      );
      if (manifest.supportsMultiplayer &&
          manifest.displayModes.contains(
            GameDisplayMode.singleScreenMultiplayer,
          )) {
        final controllerEntry = playmeshGamePackageLayout.parseWebEntry(
          manifest.entries.controller!,
          field: 'entries.controller',
          kind: GameWebEntryKind.html,
        );
        _requireFile(
          files,
          diagnostics,
          playmeshGamePackageLayout.packagePathForWebPath(controllerEntry.path),
          code: 'controller_entry_missing',
          message: 'entries.controller 指向的控制器入口不存在',
        );
      }
      final authorityPath = manifest.supportsMultiplayer
          ? manifest.authority?.entry
          : null;
      if (authorityPath != null) {
        final authorityEntry = playmeshGamePackageLayout.parseWebEntry(
          authorityPath,
          field: 'authority.entry',
          kind: GameWebEntryKind.javaScript,
        );
        _requireFile(
          files,
          diagnostics,
          playmeshGamePackageLayout.packagePathForWebPath(authorityEntry.path),
          code: 'authority_entry_missing',
          message: 'authority.entry 指向的文件不存在',
        );
      }
    }
    final rootIcon = files['icon.png'];
    if (rootIcon != null && !isSafeGamePackageIconSync(rootIcon)) {
      diagnostics.add(
        _error(
          'root_icon_invalid',
          'icon.png',
          '包根目录 icon.png 不是安全的 PNG 图片',
          hint: '请删除该文件，或替换为不超过 2 MiB 的有效 PNG。',
        ),
      );
    }

    for (final entry in files.entries) {
      final path = entry.key;
      if (!path.startsWith('app/')) continue;
      final extension = _extension(path);
      if (extension != '.html' &&
          extension != '.css' &&
          extension != '.js' &&
          extension != '.mjs') {
        continue;
      }
      String source;
      try {
        source = utf8.decode(await entry.value.readAsBytes());
      } on FormatException {
        diagnostics.add(
          _error(
            'text_encoding_invalid',
            path,
            '文本资源不是有效的 UTF-8',
            hint: '请将文件转换为 UTF-8 后重新上传。',
            messageArguments: {'path': path},
          ),
        );
        continue;
      }
      final pattern = switch (extension) {
        '.html' => _htmlReferencePattern,
        '.css' => _cssReferencePattern,
        _ => _jsReferencePattern,
      };
      for (final match in pattern.allMatches(source)) {
        final reference = match.group(1)!;
        final resolved = _resolveReference(path, reference);
        if (resolved == null) continue;
        final position = _position(source, match.start);
        if (resolved.escaped) {
          diagnostics.add(
            DeveloperProjectDiagnostic(
              code: 'resource_path_escape',
              severity: DeveloperDiagnosticSeverity.error,
              message: '资源引用越过 app/ 公开目录：$reference',
              messageArguments: {'reference': reference},
              path: path,
              line: position.$1,
              column: position.$2,
              hint: '使用 app/ 内相对路径或 /playmesh/ 平台公共资源路径。',
            ),
          );
        } else if (!files.containsKey(resolved.path)) {
          diagnostics.add(
            DeveloperProjectDiagnostic(
              code: 'resource_missing',
              severity: DeveloperDiagnosticSeverity.error,
              message: '引用的本地资源不存在：$reference',
              messageArguments: {'reference': reference},
              path: path,
              line: position.$1,
              column: position.$2,
              hint: '补充 ${resolved.path}，或修正当前引用路径。',
              hintArguments: {'resolvedPath': resolved.path},
            ),
          );
        }
      }
    }

    diagnostics.sort((left, right) {
      final severity = left.severity.index.compareTo(right.severity.index);
      if (severity != 0) return severity;
      final path = left.path.compareTo(right.path);
      if (path != 0) return path;
      return (left.line ?? 0).compareTo(right.line ?? 0);
    });
    return DeveloperProjectValidationReport(
      projectId: projectId,
      diagnostics: List.unmodifiable(diagnostics),
      fileCount: files.length,
      totalBytes: totalBytes,
    );
  }

  Future<GameManifest?> _validateManifest(
    String projectId,
    File file,
    List<DeveloperProjectDiagnostic> diagnostics,
  ) async {
    String source;
    try {
      source = utf8.decode(await file.readAsBytes());
    } on FormatException {
      diagnostics.add(
        _error(
          'manifest_encoding_invalid',
          'main.json',
          'main.json 不是有效的 UTF-8',
        ),
      );
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      final position = _position(source, error.offset ?? 0);
      diagnostics.add(
        DeveloperProjectDiagnostic(
          code: 'manifest_json_invalid',
          severity: DeveloperDiagnosticSeverity.error,
          message: 'main.json JSON 语法无效：${error.message}',
          messageArguments: {'error': error.message},
          path: 'main.json',
          line: position.$1,
          column: position.$2,
          hint: '修正 JSON 语法后重新校验。',
        ),
      );
      return null;
    }
    if (decoded is! Map) {
      diagnostics.add(
        _error('manifest_root_invalid', 'main.json', 'main.json 根节点必须是对象'),
      );
      return null;
    }
    try {
      final manifest = GameManifest.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      if (manifest.id != projectId) {
        diagnostics.add(
          _error(
            'manifest_id_mismatch',
            'main.json',
            'main.json id 必须与项目目录 ID 一致',
            hint: '当前项目 ID 为 $projectId。',
            hintArguments: {'projectId': projectId},
          ),
        );
      }
      return manifest;
    } on FormatException catch (error) {
      diagnostics.add(
        _error(
          'manifest_semantic_invalid',
          'main.json',
          error.message,
          hint: '按游戏包 main.json 字段规则修正清单。',
          messageArguments: {'error': error.message},
        ),
      );
      return null;
    }
  }

  Future<void> _validateCapabilities(
    File file,
    List<DeveloperProjectDiagnostic> diagnostics, {
    GameManifest? manifest,
  }) async {
    try {
      final source = utf8.decode(await file.readAsBytes());
      final decoded = jsonDecode(source);
      if (decoded is! Map) {
        throw const FormatException('capabilities.json 根节点必须是对象');
      }
      final capabilities = GameCapabilities.fromJson(
        Map<String, Object?>.from(decoded),
      );
      if (manifest != null &&
          !manifest.displayModes.contains(
            GameDisplayMode.singleScreenMultiplayer,
          ) &&
          capabilities.controllerRequired.isNotEmpty) {
        throw const FormatException('仅单屏多人游戏可以声明 controllerRequired');
      }
    } on Object catch (error) {
      diagnostics.add(
        _error(
          'capabilities_invalid',
          'capabilities.json',
          '设备能力声明无效：$error',
          hint: '删除该可选文件，或按当前 capabilities.json Schema 修正。',
          messageArguments: {'error': error.toString()},
        ),
      );
    }
  }

  void _requireFile(
    Map<String, File> files,
    List<DeveloperProjectDiagnostic> diagnostics,
    String path, {
    required String code,
    required String message,
  }) {
    if (files.containsKey(path)) return;
    diagnostics.add(
      _error(
        code,
        path,
        message,
        hint: '创建或恢复该入口文件后重新校验。',
        messageArguments: {'path': path},
        hintArguments: {'path': path},
      ),
    );
  }

  DeveloperProjectDiagnostic _error(
    String code,
    String path,
    String message, {
    String? hint,
    Map<String, Object?> messageArguments = const {},
    Map<String, Object?> hintArguments = const {},
  }) => DeveloperProjectDiagnostic(
    code: code,
    severity: DeveloperDiagnosticSeverity.error,
    message: message,
    path: path,
    hint: hint,
    messageArguments: messageArguments,
    hintArguments: hintArguments,
  );
}

class _ResolvedReference {
  const _ResolvedReference(this.path, {this.escaped = false});

  final String path;
  final bool escaped;
}

_ResolvedReference? _resolveReference(String sourcePath, String raw) {
  final value = raw.trim();
  final lower = value.toLowerCase();
  if (value.isEmpty ||
      value.startsWith('#') ||
      lower.startsWith('data:') ||
      lower.startsWith('blob:') ||
      lower.startsWith('http:') ||
      lower.startsWith('https:') ||
      value.startsWith('//') ||
      _isRuntimeReference(value)) {
    return null;
  }
  final withoutQuery = value.split(RegExp(r'[?#]')).first;
  if (withoutQuery.isEmpty) return null;
  if (withoutQuery.contains(r'\') || withoutQuery.contains('%')) {
    return const _ResolvedReference('', escaped: true);
  }
  final sourceWebPath = sourcePath.startsWith('app/')
      ? sourcePath.substring('app/'.length)
      : sourcePath;
  final candidate = withoutQuery.startsWith('/')
      ? withoutQuery.substring(1)
      : '${_parent(sourceWebPath)}/$withoutQuery';
  final parts = <String>[];
  for (final part in candidate.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return const _ResolvedReference('', escaped: true);
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  if (parts.isEmpty) return const _ResolvedReference('', escaped: true);
  if (playmeshGamePackageLayout.isRuntimeNamespace(parts.first)) return null;
  try {
    return _ResolvedReference(
      playmeshGamePackageLayout.packagePathForWebPath(parts.join('/')),
    );
  } on FormatException {
    return const _ResolvedReference('', escaped: true);
  }
}

bool _isRuntimeReference(String value) {
  if (!value.startsWith('/')) return false;
  final path = value.substring(1).split(RegExp(r'[?#]')).first;
  if (path.isEmpty) return false;
  return playmeshGamePackageLayout.isRuntimeNamespace(path.split('/').first);
}

(int, int) _position(String source, int offset) {
  final safeOffset = offset.clamp(0, source.length);
  var line = 1;
  var column = 1;
  for (var index = 0; index < safeOffset; index += 1) {
    if (source.codeUnitAt(index) == 10) {
      line += 1;
      column = 1;
    } else {
      column += 1;
    }
  }
  return (line, column);
}

String _relativePath(Directory root, String path) {
  final prefix = root.path.endsWith(Platform.pathSeparator)
      ? root.path
      : '${root.path}${Platform.pathSeparator}';
  return path.substring(prefix.length).replaceAll(Platform.pathSeparator, '/');
}

bool _isInternal(String path) =>
    {'.playmesh', 'cache', 'data'}.contains(path.split('/').first);

String _extension(String path) {
  final name = path.split('/').last.toLowerCase();
  final index = name.lastIndexOf('.');
  return index < 0 ? '' : name.substring(index);
}

String _parent(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}
