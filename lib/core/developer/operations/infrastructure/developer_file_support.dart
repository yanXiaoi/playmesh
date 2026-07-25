part of '../../developer_web_gateway_io.dart';

Map<String, Object?> _fileJson(DeveloperProjectFile file) => {
  'path': file.path,
  'readOnly': file.readOnly,
  'revision': file.revision,
  'contentType': file.contentType,
};

void _emitDeveloperFileEvent({
  required String type,
  required String projectId,
  required String path,
  required int revision,
  required String? clientId,
  required List<Map<String, Object?>> operations,
}) {
  developerEventHub.emit({
    'type': type,
    'projectId': projectId,
    'path': path,
    'revision': revision,
    'clientId': clientId ?? 'api',
    'operations': operations,
    'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
  });
}

List<Map<String, Object?>> _minimalOperations(String before, String after) {
  if (before == after) return const [];
  var prefix = 0;
  final shortest = min(before.length, after.length);
  while (prefix < shortest &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix += 1;
  }
  var beforeSuffix = before.length;
  var afterSuffix = after.length;
  while (beforeSuffix > prefix &&
      afterSuffix > prefix &&
      before.codeUnitAt(beforeSuffix - 1) ==
          after.codeUnitAt(afterSuffix - 1)) {
    beforeSuffix -= 1;
    afterSuffix -= 1;
  }
  return [
    {
      'start': prefix,
      'end': beforeSuffix,
      'text': after.substring(prefix, afterSuffix),
    },
  ];
}

String? _chatAiTextContent(DeveloperProjectFile file) {
  const additionalTextExtensions = {
    '.csv',
    '.frag',
    '.glsl',
    '.graphql',
    '.jsx',
    '.ts',
    '.tsx',
    '.vert',
    '.xml',
    '.yaml',
    '.yml',
  };
  final lowerPath = file.path.toLowerCase();
  final isKnownText =
      file.isText ||
      file.contentType.startsWith('image/svg+xml') ||
      additionalTextExtensions.any(lowerPath.endsWith);
  if (!isKnownText) return null;
  try {
    return utf8.decode(file.bytes);
  } on FormatException {
    return null;
  }
}

List<String> _stringValues(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

bool _isPromptRelevantPath(
  String path, {
  required bool includeAuthority,
  required bool includeController,
}) {
  if (!includeController &&
      (path == 'app/controller' || path.startsWith('app/controller/'))) {
    return false;
  }
  if (!includeAuthority &&
      (path == 'app/static/js/service' ||
          path.startsWith('app/static/js/service/'))) {
    return false;
  }
  return true;
}
