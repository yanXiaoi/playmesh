import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows 主应用与 Runtime 注册同一语音识别诊断桥', () {
    final appHost = File(
      'windows/runner/speech_recognition_host.cpp',
    ).readAsStringSync();
    final runtimeHost = File(
      'runtime/src/windows/runner/speech_recognition_host.cpp',
    ).readAsStringSync();

    expect(runtimeHost, appHost);
    expect(appHost, contains('CLSID_SpInprocRecognizer'));
    expect(appHost, contains('CLSID_SpMMAudioIn'));
    expect(appHost, contains('recognizer->SetInput'));
    expect(appHost, contains('grammar->LoadDictation'));
    expect(appHost, contains('speech_audio_input_unavailable'));

    for (final root in ['windows/runner', 'runtime/src/windows/runner']) {
      final header = File('$root/flutter_window.h').readAsStringSync();
      final window = File('$root/flutter_window.cpp').readAsStringSync();
      final cmake = File('$root/CMakeLists.txt').readAsStringSync();
      expect(header, contains('speech_recognition_channel_'));
      expect(window, contains('playmesh::speech_recognition::kChannelName'));
      expect(window, contains('DiagnoseInitializationFailure()'));
      expect(cmake, contains('"speech_recognition_host.cpp"'));
      expect(cmake, contains('"sapi.lib"'));
      expect(cmake, contains('target_compile_options(\${BINARY_NAME} PRIVATE "/utf-8")'));
    }
  });
}
