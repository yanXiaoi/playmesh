import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android declares the API 36 local discovery permissions', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      _occurrences(manifest, 'android.permission.CHANGE_WIFI_MULTICAST_STATE'),
      1,
    );
    expect(manifest, contains('android.permission.INTERNET'));
    expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
    expect(
      manifest,
      isNot(contains('android.permission.ACCESS_LOCAL_NETWORK')),
    );
  });

  test('Android UDP multicast 使用可计数 MulticastLock 并接入 Engine', () {
    final host = File(
      'android/app/src/main/java/top/zfjmm/playmesh/LanMulticastLockHost.java',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/java/top/zfjmm/playmesh/DeveloperForegroundService.java',
    ).readAsStringSync();

    expect(host, contains('createMulticastLock'));
    expect(host, contains('playmesh:lan-game-discovery'));
    expect(host, contains('PackageManager.FEATURE_WIFI'));
    expect(host, contains('case "acquire"'));
    expect(host, contains('case "release"'));
    expect(host, contains('holderIds.add(holderId)'));
    expect(host, contains('holderIds.remove(holderId)'));
    expect(host, contains('case "releaseMany"'));
    expect(host, contains('void dispose(boolean engineWillBeDestroyed)'));
    expect(host, contains('if (!engineWillBeDestroyed) return;'));
    expect(host, contains('releaseAll();'));
    expect(activity, contains('new LanMulticastLockHost('));
    expect(service, isNot(contains('LanMulticastLockHost.releaseAll();')));
  });

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

  test(
    'Android Runtime export channel keeps native work off the UI thread',
    () {
      final source = File(
        'android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java',
      ).readAsStringSync();

      expect(source, contains('"playmesh/runtime_export"'));
      expect(source, contains('"exportAndroid"'));
      expect(source, contains('"exportWindows"'));
      expect(source, contains('call.argument("requestJson")'));
      expect(source, contains('Executors.newSingleThreadExecutor()'));
      expect(source, contains('Appnative.exportAndroidRuntime(requestJson)'));
      expect(source, contains('Appnative.exportWindowsRuntime(requestJson)'));
      expect(source, contains('mainHandler.post('));
      expect(source, contains('runtimeExportExecutor.shutdownNow()'));
    },
  );

  test('Android 主应用与 Runtime 都桥接系统语音识别诊断', () {
    final appSource = File(
      'android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java',
    ).readAsStringSync();
    final runtimeSource = File(
      'runtime/src/android/app/src/main/java/'
      'top/zfjmm/playmesh_runtime/MainActivity.java',
    ).readAsStringSync();

    for (final source in [appSource, runtimeSource]) {
      expect(source, contains('"playmesh/speech_recognition"'));
      expect(source, contains('"diagnoseInitializationFailure"'));
      expect(source, contains('SpeechRecognizer.isRecognitionAvailable(this)'));
      expect(
        source,
        contains('SpeechRecognizer.isOnDeviceRecognitionAvailable(this)'),
      );
      expect(source, contains('"speech_recognizer_unavailable"'));
    }
  });
}

int _occurrences(String source, String value) =>
    value.allMatches(source).length;
