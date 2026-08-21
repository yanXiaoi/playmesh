import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

const _windowsRuntimeVendorDirectory = 'top.zfjmm';
const _windowsRuntimeProductDirectory = 'Playmesh Runtime';

/// Resolves the Runtime-owned data root without using mutable PE display
/// metadata as its persistence identity.
///
/// Windows VERSIONINFO ProductName follows the exported game's display name.
/// `path_provider_windows` therefore cannot be used as the data namespace: two
/// same-name games would collide and renaming a game would move its data. The
/// stable gameId hash keeps exported games isolated while allowing labels and
/// executable names to change.
Future<Directory> resolveRuntimeDataDirectory(String gameId) async {
  if (Platform.isWindows) {
    final roamingAppData = Platform.environment['APPDATA']?.trim();
    if (roamingAppData == null || roamingAppData.isEmpty) {
      throw StateError('Windows APPDATA 不可用，无法创建 Runtime 数据目录');
    }
    return Directory(
      runtimeWindowsDataDirectoryPath(
        roamingAppDataPath: roamingAppData,
        gameId: gameId,
      ),
    );
  }
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}playmesh-runtime');
}

String runtimeWindowsDataDirectoryPath({
  required String roamingAppDataPath,
  required String gameId,
}) {
  var base = roamingAppDataPath.trim();
  if (base.isEmpty || base.contains('\u0000')) {
    throw const FormatException('Windows APPDATA 路径无效');
  }
  base = base.replaceAll(RegExp(r'[\\/]+$'), '');
  if (base.isEmpty) {
    throw const FormatException('Windows APPDATA 路径无效');
  }
  final gameNamespace = sha256.convert(utf8.encode(gameId)).toString();
  return '$base\\$_windowsRuntimeVendorDirectory'
      '\\$_windowsRuntimeProductDirectory\\games\\$gameNamespace';
}
