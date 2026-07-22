/// Desktop window APIs are unreachable on HarmonyOS. This object preserves
/// the small API surface referenced by shared Playmesh code during AOT build.
class WindowManager {
  bool _fullScreen = false;

  Future<void> ensureInitialized() async {}

  Future<bool> isFullScreen() async => _fullScreen;

  Future<void> setFullScreen(bool enabled) async {
    _fullScreen = enabled;
  }
}

final WindowManager windowManager = WindowManager();
