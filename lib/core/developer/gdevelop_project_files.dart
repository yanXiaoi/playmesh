import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// One JSON document in GDevelop's official folder-project representation.
class GDevelopProjectFile {
  const GDevelopProjectFile({required this.path, required this.content});

  final String path;
  final Map<String, Object?> content;

  Map<String, Object?> toJson() => {'path': path, 'content': content};

  factory GDevelopProjectFile.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    final content = json['content'];
    if (path is! String || content is! Map) {
      throw const FormatException('GDevelop 工程文件无效');
    }
    return GDevelopProjectFile(
      path: path,
      content: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(content),
      ),
    );
  }
}

class GDevelopProjectFileReference {
  const GDevelopProjectFileReference({
    required this.path,
    required this.contentHash,
    required this.size,
  });

  final String path;
  final String contentHash;
  final int size;

  Map<String, Object?> toJson() => {
    'path': path,
    'contentHash': contentHash,
    'size': size,
  };

  factory GDevelopProjectFileReference.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    final hash = json['contentHash'];
    final size = json['size'];
    if (path is! String ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        size is! int ||
        size < 1) {
      throw const FormatException('GDevelop 工程文件引用无效');
    }
    return GDevelopProjectFileReference(
      path: path,
      contentHash: hash,
      size: size,
    );
  }
}

class GDevelopProjectFilesReference {
  const GDevelopProjectFilesReference({
    required this.contentHash,
    required this.size,
    required this.files,
  });

  final String contentHash;
  final int size;
  final List<GDevelopProjectFileReference> files;

  Map<String, Object?> toJson() => {
    'contentHash': contentHash,
    'size': size,
    'files': files.map((file) => file.toJson()).toList(growable: false),
  };

  factory GDevelopProjectFilesReference.fromJson(Map<String, Object?> json) {
    final hash = json['contentHash'];
    final size = json['size'];
    final files = json['files'];
    if (hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        size is! int ||
        size < 1 ||
        files is! List) {
      throw const FormatException('GDevelop 工程文件树引用无效');
    }
    return GDevelopProjectFilesReference(
      contentHash: hash,
      size: size,
      files: List<GDevelopProjectFileReference>.unmodifiable(
        files.map((raw) {
          if (raw is! Map) {
            throw const FormatException('GDevelop 工程文件引用无效');
          }
          return GDevelopProjectFileReference.fromJson(
            Map<String, Object?>.from(raw),
          );
        }),
      ),
    );
  }
}

List<GDevelopProjectFile> gdevelopProjectFilesFromJson(Object? value) {
  if (value is! List) throw const FormatException('projectFiles 必须是数组');
  return List<GDevelopProjectFile>.unmodifiable(
    value.map((raw) {
      if (raw is! Map) throw const FormatException('GDevelop 工程文件无效');
      return GDevelopProjectFile.fromJson(Map<String, Object?>.from(raw));
    }),
  );
}

String encodeOfficialGDevelopProjectFile(Map<String, Object?> content) =>
    '${const JsonEncoder.withIndent('  ').convert(content)}\n';

Uint8List encodeOfficialGDevelopProjectFileBytes(
  Map<String, Object?> content,
) =>
    Uint8List.fromList(utf8.encode(encodeOfficialGDevelopProjectFile(content)));

Uint8List encodeCanonicalGDevelopProjectFiles(
  List<GDevelopProjectFile> files,
) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(
      _canonicalizeJson(
        files.map((file) => file.toJson()).toList(growable: false),
      ),
    ),
  ),
);

Future<String> hashGDevelopProjectFiles(List<GDevelopProjectFile> files) =>
    _sha256(encodeCanonicalGDevelopProjectFiles(files));

Future<GDevelopProjectFilesReference> referenceGDevelopProjectFiles(
  List<GDevelopProjectFile> files,
) async {
  final references = <GDevelopProjectFileReference>[];
  var totalBytes = 0;
  for (final file in files) {
    final bytes = encodeOfficialGDevelopProjectFileBytes(file.content);
    totalBytes += bytes.length;
    references.add(
      GDevelopProjectFileReference(
        path: file.path,
        contentHash: await _sha256(bytes),
        size: bytes.length,
      ),
    );
  }
  return GDevelopProjectFilesReference(
    contentHash: await hashGDevelopProjectFiles(files),
    size: totalBytes,
    files: List.unmodifiable(references),
  );
}

GDevelopProjectFile gdevelopRootProjectFile(List<GDevelopProjectFile> files) =>
    files.firstWhere(
      (file) => file.path == 'game.json',
      orElse: () => throw const FormatException('GDevelop 工程缺少 game.json'),
    );

/// Dart translation of GDevelop ObjectSplitter.unsplit, used where the App
/// must inspect or diff a stored folder project without a JavaScript runtime.
Map<String, Object?> unsplitGDevelopProjectFiles(
  List<GDevelopProjectFile> projectFiles, {
  int maxUnsplitDepth = 3,
}) {
  final files = <String, Map<String, Object?>>{
    for (final file in projectFiles)
      file.path: Map<String, Object?>.from(
        jsonDecode(jsonEncode(file.content)) as Map,
      ),
  };
  final root = files['game.json'];
  if (root == null) throw const FormatException('GDevelop 工程缺少 game.json');

  void unsplitObject(Object? current, int depth) {
    if (depth >= maxUnsplitDepth || current == null) return;
    if (current is List) {
      for (var index = 0; index < current.length; index += 1) {
        final value = current[index];
        if (_isSplitReference(value)) {
          final referencePath = (value as Map)['referenceTo'] as String;
          final partial = files['${referencePath.replaceFirst('/', '')}.json'];
          if (partial == null) {
            throw const FormatException('GDevelop 工程分片不存在');
          }
          current[index] = partial;
          unsplitObject(partial, depth + 1);
        } else {
          unsplitObject(value, depth + 1);
        }
      }
      return;
    }
    if (current is Map) {
      for (final key in current.keys.toList(growable: false)) {
        final value = current[key];
        if (_isSplitReference(value)) {
          final referencePath = (value as Map)['referenceTo'] as String;
          final partial = files['${referencePath.replaceFirst('/', '')}.json'];
          if (partial == null) {
            throw const FormatException('GDevelop 工程分片不存在');
          }
          current[key] = partial;
          unsplitObject(partial, depth + 1);
        } else {
          unsplitObject(value, depth + 1);
        }
      }
    }
  }

  unsplitObject(root, 0);
  return root;
}

bool _isSplitReference(Object? value) =>
    value is Map && value['__REFERENCE_TO_SPLIT_OBJECT'] == true;

Object? _canonicalizeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) return value.map(_canonicalizeJson).toList();
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) throw const FormatException('JSON 对象键必须是字符串');
      return key;
    }).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalizeJson(value[key]),
    };
  }
  throw const FormatException('GDevelop 工程包含不可序列化值');
}

Future<String> _sha256(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
