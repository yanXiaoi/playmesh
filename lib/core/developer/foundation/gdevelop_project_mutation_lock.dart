import 'dart:async';
import 'dart:io';

/// 在同一进程内按项目根串行化 GDevelop 变更。
///
/// 多项目操作一次性登记排序后的全部根，因此 rekey 的 old/new 双锁不会与
/// 反向请求死锁；互不相交的项目仍可并行执行。
class GDevelopProjectMutationLock {
  const GDevelopProjectMutationLock();

  static final Map<String, Future<void>> _tails = {};

  Future<T> run<T>({
    required Iterable<Directory> projectRoots,
    required Future<T> Function() action,
  }) async {
    final keys = projectRoots.map(_key).toSet().toList()..sort();
    if (keys.isEmpty) throw ArgumentError.value(projectRoots, 'projectRoots');

    final predecessors = [
      for (final key in keys) _tails[key] ?? Future<void>.value(),
    ];
    final completer = Completer<void>();
    for (final key in keys) {
      _tails[key] = completer.future;
    }
    try {
      await Future.wait(predecessors);
      return await action();
    } finally {
      if (!completer.isCompleted) completer.complete();
      for (final key in keys) {
        if (identical(_tails[key], completer.future)) _tails.remove(key);
      }
    }
  }

  static String _key(Directory root) {
    final path = root.absolute.path;
    return Platform.isWindows ? path.toLowerCase() : path;
  }
}
