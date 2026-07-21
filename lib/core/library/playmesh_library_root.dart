import 'dart:io';

import 'package:path_provider/path_provider.dart';

class PlaymeshLibraryRoot {
  const PlaymeshLibraryRoot._();

  static Future<Directory> resolve({
    bool? mobile,
    String? executablePath,
    Directory? applicationSupportDirectory,
  }) async {
    final useMobileRoot = mobile ?? (Platform.isAndroid || Platform.isIOS);
    final Directory root;
    if (useMobileRoot) {
      final support =
          applicationSupportDirectory ?? await getApplicationSupportDirectory();
      root = Directory(
        '${support.path}${Platform.pathSeparator}playmesh-library',
      );
    } else {
      final executable = File(executablePath ?? Platform.resolvedExecutable);
      root = Directory(
        '${executable.parent.path}${Platform.pathSeparator}playmesh-library',
      );
    }
    await root.create(recursive: true);
    return root;
  }
}
