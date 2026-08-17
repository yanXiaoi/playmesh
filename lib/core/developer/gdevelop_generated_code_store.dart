import 'dart:collection';
import 'dart:typed_data';

/// GDevelop 预览导出期间生成的事件函数代码。
///
/// 这些代码只是当前开发者通道的临时中间产物：项目正文仍以
/// `playmesh-library/GDevelop/packages` 为唯一事实，不能为了预览再写入浏览器
/// IndexedDB 或 App 持久目录。
class GDevelopGeneratedCodeStore {
  GDevelopGeneratedCodeStore({
    this.maximumEntryBytes = 2 * 1024 * 1024,
    this.maximumTotalBytes = 32 * 1024 * 1024,
    this.maximumEntries = 1024,
  }) {
    if (maximumEntryBytes < 1 ||
        maximumTotalBytes < maximumEntryBytes ||
        maximumEntries < 1) {
      throw ArgumentError('GDevelop 临时代码存储限制无效');
    }
  }

  final int maximumEntryBytes;
  final int maximumTotalBytes;
  final int maximumEntries;

  final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap();
  int _totalBytes = 0;

  int get length => _entries.length;
  int get totalBytes => _totalBytes;

  static String validateKey(String value) {
    final key = value.trim();
    if (!RegExp(r'^[A-Za-z0-9._-]{1,200}$').hasMatch(key)) {
      throw const FormatException('GDevelop 临时代码 key 无效');
    }
    return key;
  }

  void put(String rawKey, List<int> bytes) {
    final key = validateKey(rawKey);
    if (bytes.isEmpty) {
      throw const FormatException('GDevelop 临时代码不能为空');
    }
    if (bytes.length > maximumEntryBytes) {
      throw GDevelopGeneratedCodeTooLarge(maximumEntryBytes);
    }

    final owned = Uint8List.fromList(bytes);
    final replaced = _entries.remove(key);
    if (replaced != null) _totalBytes -= replaced.length;
    _entries[key] = owned;
    _totalBytes += owned.length;
    _evictOldestEntries();
  }

  Uint8List? read(String rawKey) {
    final key = validateKey(rawKey);
    final bytes = _entries[key];
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  void clear() {
    _entries.clear();
    _totalBytes = 0;
  }

  void _evictOldestEntries() {
    while (_entries.length > maximumEntries ||
        _totalBytes > maximumTotalBytes) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey)!;
      _totalBytes -= removed.length;
    }
  }
}

class GDevelopGeneratedCodeTooLarge implements Exception {
  const GDevelopGeneratedCodeTooLarge(this.limit);

  final int limit;
}
