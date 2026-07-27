import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:window_manager/window_manager.dart';

import 'app_platform.dart';
import '../../models/game_summary.dart';

class AppDeviceService {
  const AppDeviceService();

  String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  bool get hapticsAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> setFullscreen(
    bool enabled, {
    GameOrientation? orientation,
  }) async {
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (desktop) {
      await windowManager.setFullScreen(enabled);
    } else {
      FullScreen.setFullScreen(enabled);
    }
    if (!isMobileAppPlatform) return;
    if (!enabled) {
      await SystemChrome.setPreferredOrientations(const []);
      return;
    }
    if (orientation != null) {
      await SystemChrome.setPreferredOrientations(switch (orientation) {
        GameOrientation.landscape => const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        GameOrientation.portrait => const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      });
    }
  }

  Future<void> haptic(String style) async {
    switch (style) {
      case 'selection':
        await HapticFeedback.selectionClick();
        return;
      case 'light':
        await HapticFeedback.lightImpact();
        return;
      case 'medium':
        await HapticFeedback.mediumImpact();
        return;
      case 'heavy':
        await HapticFeedback.heavyImpact();
        return;
      case 'vibrate':
        await HapticFeedback.vibrate();
        return;
      default:
        throw FormatException('不支持的触觉反馈类型：$style');
    }
  }
}
