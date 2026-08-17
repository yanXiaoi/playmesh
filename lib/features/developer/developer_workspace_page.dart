import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/platform/app_platform.dart';
import '../../core/platform/app_device_service.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/developer/developer_external_navigation.dart';
import '../../core/developer/developer_fullscreen_bridge.dart';
import '../../core/developer/developer_native_file_save.dart';
import '../../core/developer/developer_native_file_save_service.dart';
import '../../core/developer/webview_console_capture.dart';
import '../game/windows_local_game_web_view.dart';

class DeveloperWorkspacePage extends StatefulWidget {
  const DeveloperWorkspacePage({
    super.key,
    required this.workspaceUri,
    this.workspaceTitle,
    this.nativeFileSaveService,
    this.deviceService = const AppDeviceService(),
    this.isGDevelopWorkspace = false,
  });

  final Uri workspaceUri;
  final String? workspaceTitle;
  final DeveloperNativeFileSaveService? nativeFileSaveService;
  final AppDeviceService deviceService;
  final bool isGDevelopWorkspace;

  @override
  State<DeveloperWorkspacePage> createState() => _DeveloperWorkspacePageState();
}

class _DeveloperWorkspacePageState extends State<DeveloperWorkspacePage> {
  WebViewController? _controller;
  Object? _error;
  int _windowsReloadKey = 0;
  late final DeveloperNativeFileSaveService _nativeFileSaveService =
      widget.nativeFileSaveService ?? createDeveloperNativeFileSaveService();
  Future<void> _nativeFileSaveTail = Future<void>.value();
  Future<void> _fullscreenTail = Future<void>.value();
  Future<void> Function(String)? _runWindowsJavaScript;
  bool _fullscreen = false;

  bool get _usesFlutterWebView => supportsPlatformWebView;

  @override
  void initState() {
    super.initState();
    if (_usesFlutterWebView) unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      late final WebViewController controller;
      controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          playmeshExternalNavigationChannel,
          onMessageReceived: (message) {
            final uri = parsePlaymeshExternalNavigationMessage(message.message);
            if (uri != null) unawaited(_openExternalUri(uri));
          },
        )
        ..addJavaScriptChannel(
          playmeshNativeFileSaveChannel,
          onMessageReceived: (message) {
            _handleNativeFileSaveWebMessage(message.message);
          },
        )
        ..addJavaScriptChannel(
          playmeshDeveloperFullscreenChannel,
          onMessageReceived: (message) {
            _handleDeveloperFullscreenWebMessage(message.message);
          },
        )
        ..setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) async {
              final uri = Uri.tryParse(request.url);
              if (uri == null ||
                  !shouldOpenDeveloperNavigationExternally(
                    workspaceUri: widget.workspaceUri,
                    requestedUri: uri,
                  )) {
                return NavigationDecision.navigate;
              }
              await _openExternalUri(uri);
              return NavigationDecision.prevent;
            },
            onPageFinished: (_) async {
              await controller.runJavaScript(playmeshExternalNavigationScript);
              await controller.runJavaScript(playmeshNativeFileSaveScript);
              await controller.runJavaScript(playmeshDeveloperFullscreenScript);
              await _synchronizeDeveloperFullscreenState(
                controller.runJavaScript,
              );
            },
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
      child: PopScope(
        canPop: !_fullscreen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _fullscreen) {
            _enqueueDeveloperFullscreen(false);
          }
        },
        child: Scaffold(
          appBar: _fullscreen
              ? null
              : AppBar(
                  title: Text(
                    widget.workspaceTitle ?? context.tr('home.developer'),
                  ),
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
        title: widget.workspaceTitle ?? context.tr('home.developer'),
        onOpenExternalUri: _openExternalUri,
        additionalDocumentCreatedScripts: const [
          playmeshNativeFileSaveScript,
          playmeshDeveloperFullscreenScript,
        ],
        onWebMessage: (message) =>
            _handleDeveloperFullscreenWebMessage(message) ||
            _handleNativeFileSaveWebMessage(message),
        onRunJavaScriptReady: (executor) {
          _runWindowsJavaScript = executor;
          unawaited(_synchronizeDeveloperFullscreenState(executor));
        },
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

  Future<void> _openExternalUri(Uri uri) async {
    await openDeveloperExternalUri(uri);
  }

  bool _handleDeveloperFullscreenWebMessage(Object? rawMessage) {
    if (!isPlaymeshDeveloperFullscreenToggleMessage(rawMessage)) return false;
    _fullscreenTail = _fullscreenTail.then((_) async {
      final active = await widget.deviceService.isFullscreen();
      await _setDeveloperFullscreen(!active);
    });
    return true;
  }

  void _enqueueDeveloperFullscreen(bool enabled) {
    _fullscreenTail = _fullscreenTail.then(
      (_) => _setDeveloperFullscreen(enabled),
    );
  }

  Future<void> _setDeveloperFullscreen(bool enabled) async {
    try {
      await widget.deviceService.setFullscreen(enabled);
      if (mounted) setState(() => _fullscreen = enabled);
      await _sendDeveloperFullscreenState(enabled);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              enabled
                  ? 'game.fullscreen_enter_failed'
                  : 'game.fullscreen_exit_failed',
              arguments: {'error': error},
            ),
          ),
        ),
      );
    }
  }

  Future<void> _synchronizeDeveloperFullscreenState(
    Future<void> Function(String) runJavaScript,
  ) async {
    try {
      final active = await widget.deviceService.isFullscreen();
      if (mounted && _fullscreen != active) {
        setState(() => _fullscreen = active);
      }
      await runJavaScript(playmeshDeveloperFullscreenStateScript(active));
    } on Object catch (error) {
      debugPrint('Unable to synchronize developer fullscreen state: $error');
    }
  }

  Future<void> _sendDeveloperFullscreenState(bool active) async {
    final script = playmeshDeveloperFullscreenStateScript(active);
    final windowsExecutor = _runWindowsJavaScript;
    if (windowsExecutor != null) {
      await windowsExecutor(script);
      return;
    }
    await _controller?.runJavaScript(script);
  }

  bool _handleNativeFileSaveWebMessage(Object? rawMessage) {
    final message = DeveloperNativeFileSaveMessage.tryParse(rawMessage);
    if (message == null) return false;
    _nativeFileSaveTail = _nativeFileSaveTail
        .then((_) => _handleNativeFileSave(message))
        .onError((error, stackTrace) {
          _reportNativeFileSaveError(error);
        });
    return true;
  }

  Future<void> _handleNativeFileSave(
    DeveloperNativeFileSaveMessage message,
  ) async {
    if (message.kind == DeveloperNativeFileSaveMessageKind.error) {
      _reportNativeFileSaveError(
        StateError(message.errorMessage ?? 'WebView Blob 暂存失败'),
        code: message.errorCode,
      );
      return;
    }
    final renderObject = context.findRenderObject();
    final sharePositionOrigin =
        renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    final result = await _nativeFileSaveService.save(
      message: message,
      workspaceUri: widget.workspaceUri,
      sharePositionOrigin: sharePositionOrigin,
    );
    if (!mounted ||
        result.outcome == DeveloperNativeFileSaveOutcome.cancelled) {
      return;
    }
    final text = result.outcome == DeveloperNativeFileSaveOutcome.shared
        ? context.tr('game.export_share_ready')
        : context.tr(
            'game.exported_to',
            arguments: {'path': result.path ?? message.filename ?? ''},
          );
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _reportNativeFileSaveError(Object? error, {String? code}) {
    recordLocalWebViewConsole(
      level: 'error',
      message:
          'Native file save failed: code=${code ?? 'native_file_save_failed'} '
          'error=$error',
      source: 'developer-workspace-webview',
      href: widget.workspaceUri.replace(query: null, fragment: null).toString(),
      eventType: 'native.file_save.error',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr('game.export_failed', arguments: {'error': error}),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (widget.isGDevelopWorkspace) {
      const releaseScript =
          'void globalThis.__playmeshReleaseGDevelopEditorInstance?.();';
      final windowsExecutor = _runWindowsJavaScript;
      if (windowsExecutor != null) {
        unawaited(windowsExecutor(releaseScript).catchError((Object _) {}));
      } else {
        unawaited(
          _controller?.runJavaScript(releaseScript).catchError((Object _) {}) ??
              Future<void>.value(),
        );
      }
    }
    _runWindowsJavaScript = null;
    if (_fullscreen) {
      unawaited(widget.deviceService.setFullscreen(false));
    }
    super.dispose();
  }
}
