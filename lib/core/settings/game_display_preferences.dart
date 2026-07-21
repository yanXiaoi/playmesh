import 'dart:convert';
import 'dart:io';

import '../library/playmesh_library_root.dart';

class GameDisplayPreferences {
  GameDisplayPreferences({Directory? libraryRoot})
    : _injectedRoot = libraryRoot;

  final Directory? _injectedRoot;

  Future<bool> loadPerformanceVisible() async {
    final file = await _file();
    if (!await file.exists()) return true;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['performanceVisible'] is bool) {
        return decoded['performanceVisible']! as bool;
      }
    } on Object {
      // Broken optional settings fall back to the safe visible default.
    }
    return true;
  }

  Future<void> savePerformanceVisible(bool visible) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.playmesh-tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'formatVersion': 1, 'performanceVisible': visible}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<File> _file() async {
    final root = _injectedRoot ?? await PlaymeshLibraryRoot.resolve();
    return File(
      '${root.path}${Platform.pathSeparator}settings'
      '${Platform.pathSeparator}runtime.json',
    );
  }
}
