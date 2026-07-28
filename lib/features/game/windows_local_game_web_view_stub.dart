import 'package:flutter/widgets.dart';

import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/app_webview_bridge.dart';
import '../../core/developer/developer_run_controller.dart';

class WindowsLocalGameWebView extends StatelessWidget {
  const WindowsLocalGameWebView({
    super.key,
    required this.assetPath,
    required this.entryUri,
    required this.title,
    this.bridge,
    this.appBridge,
    this.appSdkInputTakenOver = true,
    this.declaredCapabilities = const [],
    this.onNavigationStarted,
    this.onRunJavaScriptReady,
    this.onEvaluateJavaScriptReady,
  });

  final String assetPath;
  final Uri entryUri;
  final String title;
  final GameSdkBridge? bridge;
  final AppWebViewBridge? appBridge;
  final bool appSdkInputTakenOver;
  final List<String> declaredCapabilities;
  final VoidCallback? onNavigationStarted;
  final ValueChanged<Future<void> Function(String)>? onRunJavaScriptReady;
  final ValueChanged<DeveloperWebViewJavaScriptExecutor?>?
  onEvaluateJavaScriptReady;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
