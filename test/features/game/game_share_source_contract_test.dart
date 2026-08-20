import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('分享页只呈现用户配置的本地游戏源名称', () {
    final source = File('lib/features/game/game_page.dart').readAsStringSync();

    expect(source, isNot(contains('share.source.official_name')));
    expect(source, isNot(contains('declaration.displayNameFor')));
    expect(source, isNot(contains('declaration.author')));
    expect(source, contains('probe.source.name'));
    expect(source, contains('source.source.name'));
  });

  test('App 分享覆盖层幂等聚焦、关闭节流并恢复游戏 DOM 焦点', () {
    final pageSource = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final appUiSource = File(
      'lib/core/game_sdk/features/app/app_ui_feature.dart',
    ).readAsStringSync();
    final runtimeSource = File(
      'lib/core/game_sdk/features/game/game_runtime_feature.dart',
    ).readAsStringSync();

    expect(pageSource, contains("Key('game-share-close')"));
    expect(pageSource, contains('SingleActivator(LogicalKeyboardKey.escape)'));
    expect(pageSource, contains('requestCloseFocus()'));
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
    expect(
      createCoordinator,
      contains('hostNickname: _currentNickname'),
    );
    expect(
      createCoordinator,
      contains('hostNicknameProvider: () =>'),
    );
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
    final lanPanel = _sourceSection(
      source,
      'Widget _buildLan(double panelWidth)',
      'Widget _buildServer(double panelWidth)',
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

    expect(pageBuild, contains('_shareState?.snapshot.lanLinks'));
    expect(
      pageBuild,
      contains("context.tr('game.nearby_discovery_unavailable')"),
    );
    expect(lanPanel, contains('final addresses = _ShareAddressList('));
    expect(lanPanel, contains('links: widget.links'));
    expect(lanPanel, contains('if (widget.publicationError != null)'));
    expect(lanPanel, contains('addresses,'));

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
      'enum _SharePanelTab',
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
    final qrCard = _sourceSection(
      source,
      'Widget _qrCard(GameShareLink? link, double size)',
      'String _relayStatusLabel(',
    );

    expect(pageBuild, contains('_shareState?.snapshot.lanLinks'));
    expect(pageBuild, contains('_shareState?.snapshot.wanLink'));
    expect(qrCard, contains('Image.memory('));
    expect(qrCard, contains('Uint8List.fromList(link.pngBytes)'));
    expect(qrCard, isNot(contains('QrImageView')));
    expect(qrCard, isNot(contains('QrCode')));
  });

  test('无 LAN 最终态不显示二维码加载动画', () {
    final source = _gamePageSource();
    final lanPanel = _sourceSection(
      source,
      'Widget _buildLan(double panelWidth)',
      'Widget _buildServer(double panelWidth)',
    );
    final emptyLanBranch = _sourceSection(
      lanPanel,
      'if (widget.links.isEmpty)',
      'final compact =',
    );

    expect(emptyLanBranch, contains('return Padding('));
    expect(emptyLanBranch, contains('_ShareAddressList('));
    expect(
      emptyLanBranch,
      isNot(contains('CircularProgressIndicator')),
      reason: '通道启动完成但无 LAN 地址是终态，不能呈现永久加载动画',
    );
    expect(
      lanPanel.indexOf('if (widget.links.isEmpty)'),
      lessThan(lanPanel.indexOf('final qr = _qrCard(')),
      reason: '空地址分支必须在二维码分支之前返回',
    );
  });

  test('无 LAN 发布失败提示不声称链接已可用', () {
    final source = _gamePageSource();
    final pageBuild = _sourceSection(
      source,
      'Widget build(BuildContext context)',
      'void _handleSystemBack()',
    );
    final publicationErrorProjection = _sourceSection(
      pageBuild,
      'publicationError:',
      'players:',
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

    final distinguishesEmptyLan = publicationErrorProjection.contains(
      'lanLinks',
    );
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
      isNot(contains('if (!_appSdkInputTakenOver) {\n      content = Focus(')),
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
