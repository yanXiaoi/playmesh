import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/app_platform.dart';
import '../../core/localization/playmesh_localization.dart';
import '../game/windows_local_game_web_view.dart';

class DeveloperWorkspacePage extends StatefulWidget {
  const DeveloperWorkspacePage({super.key, required this.workspaceUri});

  final Uri workspaceUri;

  @override
  State<DeveloperWorkspacePage> createState() => _DeveloperWorkspacePageState();
}

class _DeveloperWorkspacePageState extends State<DeveloperWorkspacePage> {
  WebViewController? _controller;
  Object? _error;
  int _windowsReloadKey = 0;

  bool get _usesFlutterWebView => supportsPlatformWebView;

  @override
  void initState() {
    super.initState();
    if (_usesFlutterWebView) unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onWebResourceError: (error) {
              if (error.isForMainFrame == true && mounted) {
                setState(() => _error = error.description);
              }
            },
          ),
        );
      await controller.loadRequest(widget.workspaceUri);
      if (mounted) setState(() => _controller = controller);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      key: const Key('developer-workspace-focus-exclusion'),
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.tr('home.developer')),
          actions: [
            IconButton(
              tooltip: context.tr('developer.reload_workspace'),
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            context.tr(
              'developer.workspace_failed',
              arguments: {'error': error},
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return WindowsLocalGameWebView(
        key: ValueKey('developer-workspace-$_windowsReloadKey'),
        assetPath: 'developer-workspace',
        entryUri: widget.workspaceUri,
        title: context.tr('home.developer'),
      );
    }
    final controller = _controller;
    if (controller != null) return WebViewWidget(controller: controller);
    if (_usesFlutterWebView) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: SelectableText(
        widget.workspaceUri.toString(),
        textAlign: TextAlign.center,
      ),
    );
  }

  void _reload() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
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
}
