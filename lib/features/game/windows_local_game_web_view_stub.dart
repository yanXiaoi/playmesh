import 'package:flutter/widgets.dart';

import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';

class WindowsLocalGameWebView extends StatelessWidget {
  const WindowsLocalGameWebView({
    super.key,
    required this.assetPath,
    required this.entryUri,
    required this.title,
    this.bridge,
    this.appBridge,
    this.onRunJavaScriptReady,
  });

  final String assetPath;
  final Uri entryUri;
  final String title;
  final GameSdkBridge? bridge;
  final AppWebViewBridge? appBridge;
  final ValueChanged<Future<void> Function(String)>? onRunJavaScriptReady;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
