import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:window_manager/window_manager.dart';

import 'app_platform.dart';
import '../../models/game_summary.dart';

class AppDeviceService {
  const AppDeviceService();

  String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

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
}
