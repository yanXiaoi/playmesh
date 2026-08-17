import 'dart:ui';

import 'developer_native_file_save.dart';

enum DeveloperNativeFileSaveOutcome { saved, shared, cancelled }

final class DeveloperNativeFileSaveResult {
  const DeveloperNativeFileSaveResult(this.outcome, {this.path});

  final DeveloperNativeFileSaveOutcome outcome;
  final String? path;
}

abstract interface class DeveloperNativeFileSaveService {
  Future<DeveloperNativeFileSaveResult> save({
    required DeveloperNativeFileSaveMessage message,
    required Uri workspaceUri,
    Rect? sharePositionOrigin,
  });
}
