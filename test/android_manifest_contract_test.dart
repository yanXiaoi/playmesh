import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android launcher enables predictive back callbacks', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:enableOnBackInvokedCallback="true"'));
  });

  test(
    'Android WebView permission channel accepts plugin-provided permissions',
    () {
      final source = File(
        'android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java',
      ).readAsStringSync();

      expect(source, contains('call.argument("permissions")'));
      expect(source, contains('requiredPermissions.add((String) permission)'));
      expect(source, isNot(contains('Manifest.permission.CAMERA')));
      expect(source, isNot(contains('Manifest.permission.RECORD_AUDIO')));
      expect(source, isNot(contains('"camera".equals')));
      expect(source, isNot(contains('"microphone".equals')));
    },
  );
}
