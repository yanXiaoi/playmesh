import 'dart:io';

import 'package:playmesh_database/playmesh_database.dart';

import '../../models/game_id.dart';
import '../library/playmesh_library_root.dart';

final class GameDatabaseService {
  GameDatabaseService._(this.database);

  final PlaymeshDatabase database;

  static Future<GameDatabaseService> create({
    required String gameId,
    Directory? libraryRoot,
  }) async {
    if (!isValidPlaymeshGameId(gameId)) {
      throw const FormatException('无效的 gameId');
    }
    final root = libraryRoot ?? await PlaymeshLibraryRoot.resolve();
    final databaseFile = File(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
      '${Platform.pathSeparator}db'
      '${Platform.pathSeparator}_game.db',
    );
    return GameDatabaseService._(PlaymeshDatabase(filePath: databaseFile.path));
  }
}
