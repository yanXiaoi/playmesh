import 'package:flutter/services.dart';

/// API-compatible listener used by Playmesh's cross-platform orientation code.
abstract mixin class FullScreenListener {
  void onWindowEnterFullScreen(SystemUiMode? systemUiMode) {}

  void onWindowLeaveFullScreen(SystemUiMode? systemUiMode) {}

  void onFullScreenChanged(bool enabled, SystemUiMode? systemUiMode) {}

  void onFullScreenForcedChanged(bool forced) {}
}

/// HarmonyOS uses playmesh/harmony_capabilities for the actual native call.
/// This class only preserves flutter_fullscreen's Dart API for shared code.
class FullScreen {
  static final Set<FullScreenListener> _listeners = <FullScreenListener>{};

  static bool isFullScreen = false;
  static bool get isFullScreenForced => false;
  static SystemUiMode? systemUiMode;

  static Future<void> ensureInitialized() async {}

  static void addListener(FullScreenListener listener) {
    _listeners.add(listener);
  }

  static void removeListener(FullScreenListener listener) {
    _listeners.remove(listener);
  }

  static void setFullScreen(
    bool enabled, {
    SystemUiMode? systemUiMode,
    List<SystemUiOverlay>? systemUiOverlays,
  }) {
    final changed = isFullScreen != enabled || FullScreen.systemUiMode != systemUiMode;
    isFullScreen = enabled;
    FullScreen.systemUiMode = systemUiMode;
    if (!changed) return;
    for (final listener in List<FullScreenListener>.of(_listeners)) {
      listener.onFullScreenChanged(enabled, systemUiMode);
      if (enabled) {
        listener.onWindowEnterFullScreen(systemUiMode);
      } else {
        listener.onWindowLeaveFullScreen(systemUiMode);
      }
    }
  }
}
