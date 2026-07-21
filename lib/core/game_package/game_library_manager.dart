import 'dart:io';

import '../../models/game_summary.dart';
import '../library/playmesh_library_root.dart';

class GameLibraryManager {
  GameLibraryManager({Directory? libraryRoot}) : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;
  Directory? _resolvedRoot;

  Future<void> deleteGame(GameSummary game) async {
    final root = await _root();
    final installedPackage = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}${game.id}',
    );
    final declaredRoot = game.entry.packageRootFilePath;
    final package = declaredRoot == null
        ? installedPackage
        : Directory(declaredRoot);
    final normalized = package.absolute.path.toLowerCase();
    if (normalized != installedPackage.absolute.path.toLowerCase()) {
      throw StateError('游戏包目录不在 Playmesh 游戏库中');
    }
    if (await package.exists()) await package.delete(recursive: true);
  }

  Future<Directory> _root() async {
    final cached = _resolvedRoot;
    if (cached != null) return cached;
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    await root.create(recursive: true);
    return _resolvedRoot = root;
  }
}
