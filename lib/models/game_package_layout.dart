enum GameWebEntryKind { html, javaScript }

final class GameWebEntryLocation {
  const GameWebEntryLocation({
    required this.value,
    required this.path,
    required this.query,
  });

  /// 完整入口声明。查询串存在时保留参数段顺序、重复键和编码值语义；
  /// 构造运行时 [Uri] 时百分号十六进制字母可被规范化为大写。
  final String value;

  /// `?` 之前、可用于定位游戏包物理文件的 Web 相对路径。
  final String path;

  /// 不含前导 `?` 的原始查询串。
  final String? query;
}

abstract interface class GamePackageLayout {
  String validateRelativePath(String value, {required String field});

  String validateWebPath(String value, {required String field});

  GameWebEntryLocation parseWebEntry(
    String value, {
    required String field,
    required GameWebEntryKind kind,
  });

  String validateWebEntry(
    String value, {
    required String field,
    required GameWebEntryKind kind,
  });

  String packagePathForWebPath(String webPath);

  String webRequestPath(String webPath);

  String validatePackagePath(String value, {required String field});

  bool isRuntimeNamespace(String firstSegment);
}

const GamePackageLayout playmeshGamePackageLayout = PlaymeshGamePackageLayout();

final class PlaymeshGamePackageLayout implements GamePackageLayout {
  const PlaymeshGamePackageLayout();

  static const _runtimeNamespaces = {'playmesh', 'bucket'};

  @override
  String validateRelativePath(String value, {required String field}) =>
      _validateRelativePath(value, field: field);

  @override
  String validateWebPath(String value, {required String field}) {
    final path = validateRelativePath(value, field: field);
    final first = path.split('/').first.toLowerCase();
    if (isRuntimeNamespace(first)) {
      throw FormatException('$field 不得占用平台运行时目录 $first/');
    }
    return path;
  }

  @override
  String validateWebEntry(
    String value, {
    required String field,
    required GameWebEntryKind kind,
  }) => parseWebEntry(value, field: field, kind: kind).value;

  @override
  GameWebEntryLocation parseWebEntry(
    String value, {
    required String field,
    required GameWebEntryKind kind,
  }) {
    if (value.trim() != value) {
      throw FormatException('$field 不得包含首尾空白');
    }
    if (value.contains('#')) {
      throw FormatException('$field 不得包含 URL fragment');
    }
    final querySeparator = value.indexOf('?');
    final pathValue = querySeparator < 0
        ? value
        : value.substring(0, querySeparator);
    final query = querySeparator < 0
        ? null
        : value.substring(querySeparator + 1);
    if (query != null) {
      if (kind != GameWebEntryKind.html) {
        throw FormatException('$field 不得包含查询参数');
      }
      _validateQuery(query, field: field);
    }
    final path = validateWebPath(pathValue, field: field);
    final lower = path.toLowerCase();
    switch (kind) {
      case GameWebEntryKind.html:
        if (!lower.endsWith('.html')) {
          throw FormatException('$field 必须指向 HTML 文件');
        }
        break;
      case GameWebEntryKind.javaScript:
        if (!lower.endsWith('.js') && !lower.endsWith('.mjs')) {
          throw FormatException('$field 必须指向 JavaScript 文件');
        }
        break;
    }
    return GameWebEntryLocation(value: value, path: path, query: query);
  }

  @override
  String packagePathForWebPath(String webPath) {
    final path = validateWebPath(webPath, field: '游戏 Web 路径');
    return 'app/$path';
  }

  @override
  String webRequestPath(String webPath) {
    final path = validateWebPath(webPath, field: '游戏 Web 路径');
    return '/$path';
  }

  @override
  String validatePackagePath(String value, {required String field}) {
    final path = validateRelativePath(value, field: field);
    final segments = path.split('/');
    if (segments.first.toLowerCase() != 'app') {
      return path;
    }
    if (segments.length > 1 && isRuntimeNamespace(segments[1])) {
      throw FormatException('$field 不得包含 app/${segments[1]}/ 平台保留目录');
    }
    return path;
  }

  @override
  bool isRuntimeNamespace(String firstSegment) =>
      _runtimeNamespaces.contains(firstSegment.toLowerCase());

  void _validateQuery(String query, {required String field}) {
    if (query.isEmpty) {
      throw FormatException('$field 的查询参数不能为空');
    }
    if (query.contains(r'\') ||
        query.runes.any((value) => value <= 0x20 || value == 0x7f)) {
      throw FormatException('$field 的查询参数不得包含反斜杠、空白或控制字符');
    }
    for (var index = 0; index < query.length; index += 1) {
      if (query.codeUnitAt(index) != 0x25) continue;
      if (index + 2 >= query.length ||
          !_isHexDigit(query.codeUnitAt(index + 1)) ||
          !_isHexDigit(query.codeUnitAt(index + 2))) {
        throw FormatException('$field 的查询参数包含无效百分号编码');
      }
      index += 2;
    }
  }

  bool _isHexDigit(int value) =>
      (value >= 0x30 && value <= 0x39) ||
      (value >= 0x41 && value <= 0x46) ||
      (value >= 0x61 && value <= 0x66);

  String _validateRelativePath(String value, {required String field}) {
    if (value.isEmpty ||
        value.startsWith('/') ||
        value.startsWith(r'\') ||
        value.contains(r'\') ||
        value.contains('%') ||
        value.contains('?') ||
        value.contains('#') ||
        value.runes.any((value) => value < 0x20 || value == 0x7f) ||
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(value)) {
      throw FormatException('$field 必须是未编码的相对路径');
    }
    final segments = value.split('/');
    if (segments.any(
      (segment) => segment.isEmpty || segment == '.' || segment == '..',
    )) {
      throw FormatException('$field 不能包含空路径段、. 或 ..');
    }
    return segments.join('/');
  }
}
