import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';
import 'package:window_manager/window_manager.dart';

class AppDeviceService {
  const AppDeviceService();

  String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  List<String> get capabilities => const ['fullscreen', 'haptics'];

  Future<void> setFullscreen(bool enabled) async {
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (desktop) {
      await windowManager.setFullScreen(enabled);
      return;
    }
    FullScreen.setFullScreen(enabled);
  }

  Future<void> haptic(String style) async {
    switch (style) {
      case 'selection':
        await HapticFeedback.selectionClick();
      case 'light':
        await HapticFeedback.lightImpact();
      case 'medium':
        await HapticFeedback.mediumImpact();
      case 'heavy':
        await HapticFeedback.heavyImpact();
      case 'vibrate':
        await HapticFeedback.vibrate();
      default:
        throw FormatException('不支持的触觉反馈类型：$style');
    }
  }
}
