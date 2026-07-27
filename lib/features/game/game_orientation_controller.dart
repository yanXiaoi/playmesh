import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/platform/app_device_service.dart';
import '../../core/platform/app_platform.dart';
import '../../models/game_summary.dart';

abstract interface class GameOrientationController {
  Future<void> enter(GameOrientation orientation);

  Future<void> exitFullscreen();

  Future<void> restore();
}

class SystemGameOrientationController
    with FullScreenListener
    implements GameOrientationController {
  SystemGameOrientationController();

  bool? _wasFullScreen;
  Completer<void>? _fullscreenCompleter;
  bool _listening = false;

  bool get _supportsOrientationLock {
    return isMobileAppPlatform;
  }

  bool get _supportsDesktopFullscreen {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  @override
  Future<void> enter(GameOrientation orientation) async {
    if (_supportsDesktopFullscreen) {
      final wasFullScreen = await windowManager.isFullScreen();
      _wasFullScreen ??= wasFullScreen;
      if (!wasFullScreen) {
        await windowManager.setFullScreen(true);
      }
      if (!await _waitForDesktopFullscreen()) {
        throw StateError('桌面窗口未能进入全屏');
      }
      return;
    }

    _wasFullScreen ??= FullScreen.isFullScreen;
    if (!FullScreen.isFullScreen && !FullScreen.isFullScreenForced) {
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
    }

    if (_supportsOrientationLock) await _setPreferredOrientation(orientation);
  }

  Future<void> _setPreferredOrientation(GameOrientation orientation) =>
      SystemChrome.setPreferredOrientations(switch (orientation) {
        GameOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        GameOrientation.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      });

  Future<bool> _waitForDesktopFullscreen() async {
    for (var attempt = 0; attempt < 10; attempt += 1) {
      if (await windowManager.isFullScreen()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  @override
  Future<void> exitFullscreen() =>
      const AppDeviceService().setFullscreen(false);

  @override
  Future<void> restore() async {
    if (_supportsOrientationLock) {
      await SystemChrome.setPreferredOrientations(const []);
    }

    final wasFullScreen = _wasFullScreen;
    _wasFullScreen = null;
    if (_supportsDesktopFullscreen) {
      if (wasFullScreen != null) {
        await windowManager.setFullScreen(wasFullScreen);
      }
      return;
    }
    if (wasFullScreen != null) {
      FullScreen.setFullScreen(wasFullScreen);
    }
    if (_listening) {
      FullScreen.removeListener(this);
      _listening = false;
    }
    _fullscreenCompleter = null;
  }

  @override
  void onWindowEnterFullScreen(SystemUiMode? systemUiMode) {
    final completer = _fullscreenCompleter;
    _fullscreenCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}
