import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android launcher enables predictive back callbacks', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:enableOnBackInvokedCallback="true"'));
  });
}
