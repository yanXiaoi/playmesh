import 'dart:async';
import 'dart:io';

import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Runtime-owned display integration shared by launch orientation and the App
/// SDK fullscreen command. Keeping it isolated makes the platform UI/display
/// slice replaceable without coupling it to a capability implementation.
final class RuntimeDisplayController with FullScreenListener {
  bool? _wasFullscreen;
  Completer<void>? _fullscreenCompleter;
  bool _listening = false;
  bool _closed = false;

  Future<void> enter(String orientation) =>
      setFullscreen(true, orientation: orientation);

  Future<bool> isFullscreen() async {
    if (Platform.isWindows) return windowManager.isFullScreen();
    return FullScreen.isFullScreen || FullScreen.isFullScreenForced;
  }

  Future<void> setFullscreen(bool enabled, {String? orientation}) async {
    if (_closed) throw StateError('Runtime 显示控制器已关闭');
    if (orientation != null &&
        orientation != 'portrait' &&
        orientation != 'landscape') {
      throw const FormatException('orientation 必须是 portrait 或 landscape');
    }
    if (!enabled && orientation != null) {
      throw const FormatException('退出全屏时不能声明 orientation');
    }

    if (Platform.isWindows) {
      _wasFullscreen ??= await windowManager.isFullScreen();
      await windowManager.setFullScreen(enabled);
      return;
    }

    _wasFullscreen ??= FullScreen.isFullScreen;
    if (Platform.isAndroid && enabled && orientation != null) {
      await _setAndroidOrientation(orientation);
    }
    if (enabled && !FullScreen.isFullScreen && !FullScreen.isFullScreenForced) {
      if (!_listening) {
        FullScreen.addListener(this);
        _listening = true;
      }
      final completer = Completer<void>();
      _fullscreenCompleter = completer;
      FullScreen.setFullScreen(true);
      await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          if (identical(_fullscreenCompleter, completer)) {
            _fullscreenCompleter = null;
          }
          throw StateError('当前环境拒绝了全屏请求');
        },
      );
    } else if (!enabled) {
      FullScreen.setFullScreen(false);
    }

    if (Platform.isAndroid && !enabled) {
      await SystemChrome.setPreferredOrientations(const []);
    }
  }

  Future<void> _setAndroidOrientation(String orientation) =>
      SystemChrome.setPreferredOrientations(
        orientation == 'portrait'
            ? const [
                DeviceOrientation.portraitUp,
                DeviceOrientation.portraitDown,
              ]
            : const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ],
      );

  Future<void> restore() async {
    if (_closed) return;
    _closed = true;
    _fullscreenCompleter = null;
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations(const []);
    }
    final wasFullscreen = _wasFullscreen;
    _wasFullscreen = null;
    if (Platform.isWindows) {
      if (wasFullscreen != null) {
        await windowManager.setFullScreen(wasFullscreen);
      }
      return;
    }
    if (wasFullscreen != null) {
      FullScreen.setFullScreen(wasFullscreen);
    }
    if (_listening) {
      FullScreen.removeListener(this);
      _listening = false;
    }
  }

  @override
  void onWindowEnterFullScreen(SystemUiMode? systemUiMode) {
    final completer = _fullscreenCompleter;
    _fullscreenCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}
