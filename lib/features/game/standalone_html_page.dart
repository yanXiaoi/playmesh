import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/developer/developer_event_hub.dart';
import '../../core/platform/app_device_service.dart';
import '../../core/platform/app_platform.dart';
import '../../core/developer/webview_console_capture.dart';
import 'windows_local_game_web_view.dart';

class StandaloneHtmlPage extends StatefulWidget {
  const StandaloneHtmlPage({super.key, required this.filePath});

  final String filePath;

  @override
  State<StandaloneHtmlPage> createState() => _StandaloneHtmlPageState();
}

class _StandaloneHtmlPageState extends State<StandaloneHtmlPage> {
  WebViewController? _controller;
  Object? _error;
  int _windowsReloadKey = 0;

  bool get _usesFlutterWebView => supportsPlatformWebView;

  Uri get _fileUri => Uri.file(widget.filePath, windows: _isWindows);

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    developerEventHub.beginRuntime();
    unawaited(
      const AppDeviceService().setFullscreen(true).catchError((Object _) {}),
    );
    if (_usesFlutterWebView) unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setOnConsoleMessage((message) {
          recordLocalWebViewConsole(
            level: message.level.name,
            message: message.message,
            source: 'standalone-html-webview',
          );
        })
        ..setNavigationDelegate(
          NavigationDelegate(
            onWebResourceError: (error) {
              recordLocalWebViewConsole(
                level: 'error',
                message:
                    'Resource load failed: ${error.url ?? error.description}',
                source: 'standalone-html-webview',
                href: error.url,
                eventType: 'resource.error',
              );
              if (error.isForMainFrame == true && mounted) {
                setState(() => _error = error.description);
              }
            },
          ),
        );
      await controller.loadFile(widget.filePath);
      if (mounted) setState(() => _controller = controller);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    unawaited(
      const AppDeviceService().setFullscreen(false).catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildWebView(),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 8,
            child: Material(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '返回',
                    color: Colors.white,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  IconButton(
                    tooltip: '重新加载',
                    color: Colors.white,
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '进入全屏',
                    color: Colors.white,
                    onPressed: () => _setFullscreen(true),
                    icon: const Icon(Icons.fullscreen),
                  ),
                  IconButton(
                    tooltip: '退出全屏',
                    color: Colors.white,
                    onPressed: () => _setFullscreen(false),
                    icon: const Icon(Icons.fullscreen_exit),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'HTML 文件打开失败\n$error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    if (_isWindows) {
      return WindowsLocalGameWebView(
        key: ValueKey('standalone-html-$_windowsReloadKey'),
        assetPath: widget.filePath,
        entryUri: _fileUri,
        title: 'HTML',
      );
    }
    final controller = _controller;
    if (controller != null) return WebViewWidget(controller: controller);
    if (_usesFlutterWebView) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Center(
      child: SelectableText(
        widget.filePath,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white),
      ),
    );
  }

  void _reload() {
    developerEventHub.beginRuntime();
    if (_isWindows) {
      setState(() {
        _error = null;
        _windowsReloadKey += 1;
      });
      return;
    }
    final controller = _controller;
    if (controller != null) {
      setState(() => _error = null);
      unawaited(controller.reload());
      return;
    }
    if (_usesFlutterWebView) {
      setState(() => _error = null);
      unawaited(_initialize());
    }
  }

  void _setFullscreen(bool enabled) {
    unawaited(
      const AppDeviceService().setFullscreen(enabled).catchError((
        Object error,
      ) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${enabled ? '进入' : '退出'}全屏失败：$error')),
        );
      }),
    );
  }
}
