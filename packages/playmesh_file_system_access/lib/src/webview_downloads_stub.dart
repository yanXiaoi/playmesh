import '../webview_download_overlay.dart';

class PlaymeshWebViewDownloads {
  PlaymeshWebViewDownloads({
    required String? gameId,
    Future<Object?> Function(String, Map<String, Object?>)? fileOperation,
  }) : queue = gameId == null
           ? WebViewDownloadQueue()
           : WebViewDownloadQueue.forGame(gameId);
  final WebViewDownloadQueue queue;
  void attachWindows(Object controller) {}
  Future<void> attachAndroid(int identifier) async {}
  Future<void> installScript() async {}
  Future<void> resetDocument() async {}
  Future<void> dispose() async {}
}
