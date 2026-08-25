import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('主 App 适配器只把服务器名称与延迟交给共享分享面板', () {
    final source = File('lib/features/game/game_page.dart').readAsStringSync();
    final projection = _sourceSection(
      source,
      'PlaymeshSharePanelModel _buildSharePanelModel(BuildContext context)',
      'PlaymeshSharePanelStrings _buildSharePanelStrings(',
    );

    expect(source, isNot(contains('share.source.official_name')));
    expect(source, isNot(contains('declaration.displayNameFor')));
    expect(source, isNot(contains('declaration.author')));
    expect(projection, contains('name: probe.source.name'));
    expect(
      projection,
      contains('latencyMilliseconds: probe.elapsed.inMilliseconds'),
    );
    expect(projection, isNot(contains('probe.source.host')));
    expect(projection, isNot(contains('publicBaseUrl')));
    for (final technicalLabel in const <String>[
      'game.source_address',
      'game.relay_address',
      'game.relay_latency',
      'game.connection_status',
      'game.source_homepage',
    ]) {
      expect(source, isNot(contains(technicalLabel)));
    }
  });

  test('主 App 服务器目录仍保留按需加载、刷新、选择与断开行为', () {
    final source = _gamePageSource();
    final pageBuild = _sourceSection(
      source,
      'Widget build(BuildContext context)',
      'void _handleSystemBack()',
    );
    final loadServers = _sourceSection(
      source,
      'Future<void> _loadRelaySources()',
      'Future<void> _connectRelay(',
    );
    final selectServer = _sourceSection(
      source,
      'Future<void> _selectSharePanelServer(String id)',
      'int? _sharePanelLinkIndex(',
    );

    expect(pageBuild, contains('onInternetOpened: ()'));
    expect(pageBuild, contains('return _loadRelaySources()'));
    expect(pageBuild, contains('onServerSelected: _selectSharePanelServer'));
    expect(pageBuild, contains('onServerRefresh: _loadRelaySources'));
    expect(pageBuild, contains('onServerDisconnected: _disconnectRelay'));
    expect(
      loadServers,
      contains('sort((left, right) => left.elapsed.compareTo(right.elapsed))'),
    );
    expect(selectServer, contains('probe.source.id == id'));
    expect(selectServer, contains('await _connectRelay(probe)'));
  });

  test('Windows 复制完整链接，移动端调用系统分享且展示 ID 不含 URL 查询参数', () {
    final source = _gamePageSource();
    final pageBuild = _sourceSection(
      source,
      'Widget build(BuildContext context)',
      'void _handleSystemBack()',
    );
    final linkProjection = _sourceSection(
      source,
      'PlaymeshShareLink _toSharePanelLink(',
      'void _selectSharePanelLanLink(',
    );
    final action = _sourceSection(
      source,
      'Future<void> _actOnSharePanelLink(PlaymeshShareLink link)',
      'Future<void> _selectSharePanelServer(',
    );

    expect(pageBuild, contains('TargetPlatform.windows'));
    expect(pageBuild, contains('PlaymeshShareActionMode.copy'));
    expect(pageBuild, contains('PlaymeshShareActionMode.share'));
    expect(linkProjection, contains('id: id'));
    expect(linkProjection, isNot(contains('id: link.url')));
    expect(action, contains('Clipboard.setData'));
    expect(action, contains('SharePlus.instance.share'));
    expect(action, contains('ShareParams(text: link.url.toString())'));
  });

  test('App 分享覆盖层幂等聚焦、关闭节流并恢复游戏 DOM 焦点', () {
    final pageSource = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final sharePanelSource = File(
      'packages/playmesh_share_ui/lib/src/share_panel.dart',
    ).readAsStringSync();
    final appUiSource = File(
      'lib/core/game_sdk/features/app/app_ui_feature.dart',
    ).readAsStringSync();
    final runtimeSource = File(
      'lib/core/game_sdk/features/game/game_runtime_feature.dart',
    ).readAsStringSync();

    expect(
      pageSource,
      contains('GlobalKey<PlaymeshSharePanelState> _shareOverlayKey'),
    );
    expect(pageSource, contains('requestCloseFocus()'));
    expect(sharePanelSource, contains("Key('game-share-close')"));
    expect(
      sharePanelSource,
      contains('SingleActivator(LogicalKeyboardKey.escape)'),
    );
    expect(pageSource, contains('Duration(milliseconds: 800)'));
    expect(pageSource, contains("'rate_limited'"));
    expect(
      pageSource,
      contains(
        '_soloBridge != null || _bridge?.connection.isAuthority == true',
      ),
    );
    expect(
      pageSource,
      contains(
        'onOpenSharePanel: _canShareFromAppSdk ? _openShareFromAppSdk : null',
      ),
    );
    expect(
      pageSource,
      isNot(
        contains('Boolean(globalThis.navigator?.userActivation?.isActive)'),
      ),
    );
    expect(appUiSource, contains('global.navigator?.userActivation?.isActive'));
    expect(appUiSource, contains("command.payload['userActivation'] != true"));
    expect(pageSource, contains('bridge?.restoreGameContentFocus()'));
    expect(appUiSource, contains('captureAppUiReturnFocus();'));
    expect(appUiSource, contains('returnFocus.focus({ preventScroll: true })'));
    expect(appUiSource, contains('request("app.ui.openSharePanel"'));
    expect(appUiSource, contains('openAppUiShareFromFallback()'));
    expect(appUiSource, contains('button.classList?.toggle("pending"'));
    expect(
      pageSource,
      contains(
        'if (showOverlay) {\n'
        '      await WidgetsBinding.instance.endOfFrame;',
      ),
    );
    expect(pageSource, contains('_shareOpenOperation != null ||'));
    expect(
      pageSource,
      contains(
        '_shareOpenOperation = null;\n'
        '            if (mounted && !_disposing) {\n'
        '              setState(() {});',
      ),
    );
    expect(runtimeSource, contains('platform.ui.restoreGameFocus'));
    expect(
      runtimeSource,
      contains('appInternalRuntime.restoreGameContentFocus?.()'),
    );
  });

  test('GamePage 只持有分享协调器投影，不重新拥有网关、Relay 会话或邀请凭据', () {
    final source = _gamePageSource();
    final createCoordinator = _sourceSection(
      source,
      'GameShareCoordinator? _createShareCoordinator({',
      'void _attachShareCoordinator(',
    );

    expect(
      source,
      contains("import '../../core/game_web/game_share_coordinator.dart';"),
    );
    expect(source, contains('GameShareCoordinator? _shareCoordinator;'));
    expect(source, contains('GameShareCoordinatorState? _shareState;'));
    expect(createCoordinator, contains('return GameShareCoordinator('));
    expect(
      createCoordinator,
      contains('StandaloneGameShareAccessProvider(soloBridge!)'),
    );
    expect(createCoordinator, contains('MultiplayerGameShareAccessProvider('));
    expect(createCoordinator, contains('hostNickname: _currentNickname'));
    expect(createCoordinator, contains('hostNicknameProvider: () =>'));
    expect(
      createCoordinator,
      contains('bridge.connection.currentPlayer.nickname'),
      reason: 'LAN presence 必须随 Core 中的当前房主昵称更新',
    );

    expect(source, isNot(contains('GameWebGateway')));
    expect(source, isNot(contains('RelayHostSession')));
    expect(source, isNot(contains('QrImageView')));
    expect(source, isNot(contains('startGameWebGateway(')));
    expect(source, isNot(contains('startRelayHostSession(')));
    expect(source, isNot(contains('_newStandaloneShareToken')));
    expect(source, isNot(contains('Random.secure()')));
    expect(source, isNot(contains('shareToken:')));
    expect(source, isNot(contains('inviteToken:')));
  });

  test('分享面板与 App SDK 复用 coordinator.setPublished', () {
    final source = _gamePageSource();
    final openShare = _sourceSection(
      source,
      'Future<void> _openShare({bool throwOnError = false})',
      'Future<void> _openShareFromAppSdk()',
    );
    final ensureShare = _sourceSection(
      source,
      'Future<void> _ensureShare({',
      'Future<void> _hideShare()',
    );
    final sdkPublish = _sourceSection(
      source,
      'Future<void> _publishFromAppSdk()',
      'Future<GameShareLinkSnapshot> _readShareLinksFromAppSdk()',
    );

    expect(
      openShare,
      contains('_ensureShare(showOverlay: true, throwOnError: true)'),
    );
    expect(ensureShare, contains('final coordinator = _shareCoordinator;'));
    expect(ensureShare, contains('await coordinator.ensureChannel();'));
    expect(ensureShare, contains('await coordinator.setPublished();'));
    expect(
      ensureShare.indexOf('await coordinator.ensureChannel();'),
      lessThan(ensureShare.indexOf('await coordinator.setPublished();')),
    );
    expect(sdkPublish, contains('final coordinator = _shareCoordinator;'));
    expect(sdkPublish, contains('await coordinator.setPublished();'));
  });

  test('附近发布失败仍保留手工链接并显示本地化提示', () {
    final source = _gamePageSource();
    final ensureShare = _sourceSection(
      source,
      'Future<void> _ensureShare({',
      'Future<void> _hideShare()',
    );
    final pageBuild = _sourceSection(
      source,
      'Widget build(BuildContext context)',
      'void _handleSystemBack()',
    );
    final projection = _sourceSection(
      source,
      'PlaymeshSharePanelModel _buildSharePanelModel(BuildContext context)',
      'PlaymeshSharePanelStrings _buildSharePanelStrings(',
    );
    final sharedPanel = File(
      'packages/playmesh_share_ui/lib/src/share_panel.dart',
    ).readAsStringSync();
    final sharedLanPanel = _sourceSection(
      sharedPanel,
      'Widget _buildLan(BuildContext context)',
      'Widget _buildInternet(BuildContext context)',
    );

    expect(ensureShare, contains("if (error.code == 'discovery_unavailable')"));
    expect(
      ensureShare,
      contains('setState(() => _publicationErrorCode = error.code);'),
    );
    expect(ensureShare, isNot(contains('_shareState = null')));
    expect(ensureShare, isNot(contains('_selectedShareLink = null')));
    expect(ensureShare, isNot(contains('_stopShare()')));
    expect(ensureShare, isNot(contains('coordinator.close()')));

    expect(pageBuild, contains('_buildSharePanelModel(context)'));
    expect(
      projection,
      contains("context.tr('game.nearby_discovery_unavailable')"),
    );
    expect(projection, contains('lanLinks.isNotEmpty'));
    expect(projection, contains('lanError: lanError'));
    expect(sharedLanPanel, contains('if (widget.model.lanError != null)'));
    expect(sharedLanPanel, contains('if (widget.model.lanLinks.isNotEmpty)'));
    expect(sharedLanPanel, contains('_LinkPresentation('));

    for (final locale in const ['zh-CN', 'en-US']) {
      final messages =
          jsonDecode(
                File(
                  'assets/playmesh-localization/locales/$locale/app.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(
        messages['game.nearby_discovery_unavailable'],
        isA<String>().having((value) => value.trim(), 'text', isNotEmpty),
        reason: '$locale 必须提供附近发现失败的安全提示',
      );
    }
  });

  test('关闭面板和热重启保留分享，session 与页面退出统一关闭 coordinator', () {
    final source = _gamePageSource();
    final hideShare = _sourceSection(
      source,
      'Future<void> _hideShare()',
      'Future<void> _loadRelaySources()',
    );
    final restartGame = _sourceSection(
      source,
      'Future<void> _restartGame()',
      'Future<Object?> _executeDeveloperJavaScript(',
    );
    final closeSession = _sourceSection(
      source,
      'Future<void> _performCloseSession()',
      'GameShareCoordinator? _createShareCoordinator({',
    );
    final stopShare = _sourceSection(
      source,
      'Future<void> _stopShare()',
      'Future<void> _restartGame()',
    );
    final dispose = _sourceSection(
      source,
      'void dispose()',
      'Future<void> _restoreDisplayState()',
    );
    final exitGame = _sourceSection(
      source,
      'Future<void> _performExitGame({required bool toLibrary})',
      'class _FullscreenNotice',
    );

    expect(hideShare, isNot(contains('_stopShare')));
    expect(hideShare, isNot(contains('_closeSession')));
    expect(hideShare, isNot(contains('coordinator')));
    expect(restartGame, isNot(contains('_stopShare')));
    expect(restartGame, isNot(contains('_closeSession')));
    expect(restartGame, isNot(contains('coordinator')));

    expect(closeSession, contains('await _stopShare();'));
    expect(stopShare, contains('await coordinator?.close();'));
    expect(dispose, contains('unawaited(_closeSession());'));
    expect(exitGame, contains('final closeOperation = _closeSession();'));
  });

  test('GamePage 关闭或切换 session 时立即关闭 App LAN context', () {
    final source = _gamePageSource();
    final hostInitialization = _sourceSection(
      source,
      '_appLanHost = GameAppLanHostAdapter(',
      '_developerRunId = widget.developerRunId;',
    );

    expect(
      RegExp(
        r'isActive:\s*\(\)\s*=>\s*mounted\s*&&\s*!_disposing\s*&&\s*_sessionReady\s*&&\s*_closeSessionOperation\s*==\s*null',
        multiLine: true,
      ).hasMatch(hostInitialization),
      isTrue,
      reason: '旧 document 不能在 session close/widget update 窗口绑定到新 gameId',
    );
  });

  test('分享面板直接渲染 coordinator snapshot 提供的 PNG bytes', () {
    final source = _gamePageSource();
    final pageBuild = _sourceSection(
      source,
      'Widget build(BuildContext context)',
      'void _handleSystemBack()',
    );
    final projection = _sourceSection(
      source,
      'PlaymeshShareLink _toSharePanelLink(',
      'void _selectSharePanelLanLink(',
    );
    final sharedPanel = File(
      'packages/playmesh_share_ui/lib/src/share_panel.dart',
    ).readAsStringSync();
    final qrCard = _sourceSection(
      sharedPanel,
      'class _ShareQr extends StatelessWidget',
      'class _ShareLinkTile extends StatelessWidget',
    );

    expect(pageBuild, contains('_buildSharePanelModel(context)'));
    expect(
      projection,
      contains('qrPngBytes: Uint8List.fromList(link.pngBytes)'),
    );
    expect(qrCard, contains('Image.memory('));
    expect(qrCard, contains('final bytes = link.qrPngBytes'));
  });

  test('无 LAN 最终态不显示二维码加载动画', () {
    final source = File(
      'packages/playmesh_share_ui/lib/src/share_panel.dart',
    ).readAsStringSync();
    final lanPanel = _sourceSection(
      source,
      'Widget _buildLan(BuildContext context)',
      'Widget _buildInternet(BuildContext context)',
    );

    expect(lanPanel, contains('if (widget.model.lanLinks.isEmpty'));
    expect(
      lanPanel,
      contains('_SectionMessage(message: widget.strings.noLanLinks)'),
      reason: '通道启动完成但无 LAN 地址是终态，不能呈现永久加载动画',
    );
    expect(
      lanPanel.indexOf('if (widget.model.lanLinks.isEmpty'),
      lessThan(lanPanel.indexOf('if (widget.model.lanLinks.isNotEmpty)')),
      reason: '空地址和链接呈现必须是互斥终态',
    );
  });

  test('无 LAN 发布失败提示不声称链接已可用', () {
    final source = _gamePageSource();
    final projection = _sourceSection(
      source,
      'PlaymeshSharePanelModel _buildSharePanelModel(BuildContext context)',
      'PlaymeshSharePanelStrings _buildSharePanelStrings(',
    );

    final zhMessages =
        jsonDecode(
              File(
                'assets/playmesh-localization/locales/zh-CN/app.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final enMessages =
        jsonDecode(
              File(
                'assets/playmesh-localization/locales/en-US/app.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final zhMessage =
        zhMessages['game.nearby_discovery_unavailable']! as String;
    final enMessage =
        enMessages['game.nearby_discovery_unavailable']! as String;

    final distinguishesEmptyLan = projection.contains('lanLinks.isNotEmpty');
    final nearbyMessageIsNeutral =
        !zhMessage.contains('分享链接已可用') &&
        !enMessage.toLowerCase().contains('share links are ready');
    expect(
      distinguishesEmptyLan || nearbyMessageIsNeutral,
      isTrue,
      reason: '无 LAN 与“已有手工链接、仅组播公开失败”必须使用不同投影，或统一使用中性提示',
    );
  });

  test('Windows 游戏 WebView 挂载完成后主动取得原生键盘焦点', () {
    final source = File(
      'lib/features/game/windows_local_game_web_view_io.dart',
    ).readAsStringSync();

    expect(source, contains('FocusManager.instance.primaryFocus?.unfocus()'));
    expect(source, contains('await _controller.focus()'));
    expect(source, contains('LoadingState.navigationCompleted'));
    expect(source, contains("'platform.ui.restoreGameFocus'"));
    expect(source, contains('widget.appSdkInputTakenOver'));
    expect(source, contains('_navigationCompleted'));
    expect(source, contains('_controller.onFocusChanged.listen'));
    expect(source, contains('_controller.hasNativeFocus'));
    expect(source, contains('_scheduleInitialFocusRetry()'));
    expect(source, contains('WidgetsBinding.instance.scheduleFrame()'));
  });

  test('Android 游戏 WebView 在 App SDK 接管且页面完成后主动聚焦', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();

    expect(source, contains('_androidNavigationCompleted'));
    expect(source, contains('_scheduleAndroidWebViewFocus()'));
    expect(source, contains('_androidWebViewFocusScopeNode'));
    expect(source, contains('platformViewFocus.requestFocus()'));
    expect(source, contains("_runJavaScript('window.focus();')"));
    expect(source, contains("_evaluateJavaScript('document.hasFocus()')"));
    expect(source, contains('_scheduleAndroidWebViewFocusRetry()'));
    expect(source, contains('WidgetsBinding.instance.scheduleFrame()'));
    expect(source, contains('defaultTargetPlatform != TargetPlatform.android'));
  });

  test('App SDK input takeover keeps both platform WebViews mounted', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();

    expect(source, contains('canRequestFocus: !_appSdkInputTakenOver'));
    expect(source, contains('absorbing: !_appSdkInputTakenOver'));
    expect(
      source,
      matches(
        RegExp(
          r'content = Stack\(\s*'
          r'fit: StackFit\.expand,\s*'
          r'children: \[\s*'
          r'content,\s*'
          r'if \(!_appSdkInputTakenOver\) const PlaymeshLoadingView\(\),\s*'
          r'\],\s*'
          r'\);',
        ),
      ),
    );
    expect(
      source,
      isNot(
        matches(
          RegExp(
            r'if \(!_appSdkInputTakenOver\) \{\s*content = (?:Focus|Stack)\(',
          ),
        ),
      ),
    );
  });

  test('App SDK 接管前由平台默认响应，接管后才转交系统返回', () {
    final source = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();
    final gamePageSource = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final appSource = File(
      'lib/core/game_sdk/features/app/app_device_feature.dart',
    ).readAsStringSync();

    expect(source, contains('game-native-input-fallback'));
    expect(source, contains('_exitBeforeAppSdkTakeover()'));
    expect(source, contains('onInputTakeover: _takeOverAppSdkInput'));
    expect(source, contains('absorbing: !_appSdkInputTakenOver'));
    expect(source, contains('appSdkHandleNativeBackScript()'));
    expect(source, contains('canPop: !_appSdkInputTakenOver'));
    expect(source, contains('onSystemBackHandlerChanged'));
    expect(source, isNot(contains('key == LogicalKeyboardKey.contextMenu')));
    expect(gamePageSource, contains('onPopInvokedWithResult: (didPop, _)'));
    expect(gamePageSource, contains('_gameSystemBackHandler'));
    expect(
      gamePageSource,
      contains('onSystemBackHandlerChanged: _setGameSystemBackHandler'),
    );
    expect(appSource, contains('request("app.input.takeover")'));
    expect(appSource, contains('handleNativeBack()'));
  });
}

String _gamePageSource() =>
    File('lib/features/game/game_page.dart').readAsStringSync();

String _sourceSection(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  if (startIndex < 0) {
    throw StateError('找不到来源区段起点：$start');
  }
  final endIndex = source.indexOf(end, startIndex + start.length);
  if (endIndex < 0) {
    throw StateError('找不到来源区段终点：$end');
  }
  return source.substring(startIndex, endIndex);
}
