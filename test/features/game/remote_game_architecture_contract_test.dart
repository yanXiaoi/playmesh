import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('加入端不再通过 GamePage 运行本地游戏包', () {
    final dartSources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final gamePage = File(
      'lib/features/game/game_page.dart',
    ).readAsStringSync();
    final launcher = File(
      'lib/features/game/game_launcher.dart',
    ).readAsStringSync();

    expect(dartSources, isNot(contains('GameJoinRequest')));
    expect(dartSources, isNot(contains('joinRequest')));
    expect(gamePage, isNot(contains('client.join(')));
    expect(launcher, contains('entryPath: game.entry.gameEntryPath'));
    expect(launcher, isNot(contains('controllerEntryPath')));
  });

  test('所有加入入口只通过唯一 Router 构造 RemoteGamePage', () {
    final joinPage = File(
      'lib/features/game/join_game_page.dart',
    ).readAsStringSync();
    final scanner = File(
      'lib/features/game/game_invitation_scanner_page.dart',
    ).readAsStringSync();
    final appLanHost = File(
      'lib/features/game/game_app_lan_host.dart',
    ).readAsStringSync();
    final router = File(
      'lib/features/game/game_join_router.dart',
    ).readAsStringSync();

    for (final source in [joinPage, scanner, appLanHost]) {
      expect(RegExp(r'RemoteGamePage\s*\(').hasMatch(source), isFalse);
      expect(RegExp(r'\bGamePage\s*\(').hasMatch(source), isFalse);
      expect(RegExp(r'\bGameLaunchArguments\s*\(').hasMatch(source), isFalse);
    }
    expect(RegExp(r'RemoteGamePage\s*\(').allMatches(router), hasLength(1));
    expect(router, contains('entryUri: launch.entryUri'));
    expect(joinPage, contains('_joinCoordinator.prepareLink'));
    expect(joinPage, contains('_joinCoordinator.prepareDiscovered'));
    expect(appLanHost, contains('GameJoinCoordinator('));
  });

  test('加入端远程 Game runtime 与本机 App Bridge 边界固定', () {
    final remote = File(
      'lib/features/game/remote_game_page.dart',
    ).readAsStringSync();
    final authorityGateway = File(
      'lib/core/game_web/game_web_gateway_io.dart',
    ).readAsStringSync();
    final localTunnel = File(
      'lib/core/game_web/local_tunnel_gateway_io.dart',
    ).readAsStringSync();

    expect(remote, contains('startLocalTunnelGateway('));
    expect(remote, contains('startRelayClientGateway('));
    expect(remote, contains('controller.loadRequest(_launchUri)'));
    expect(remote, contains('AppWebViewBridge('));
    expect(remote, contains("'PlaymeshAppBridge'"));
    expect(remote, contains('webPermissionRole: AppWebPermissionRole.joiner'));
    expect(remote, contains('userId: widget.userId'));
    expect(remote, contains('nickname: _currentNickname'));
    expect(remote, contains('onNicknameChanged: _persistNickname'));
    expect(remote, isNot(contains("'PlaymeshBridge'")));

    // B 边界：无特权 client 由 Authority 的平台保留命名空间提供；
    // 本机回环 tunnel 不解析 HTTP，也不接受远端指定本地 SDK 文件。
    expect(authorityGateway, contains('_isPlaymeshRequestPath(path)'));
    expect(
      authorityGateway,
      contains('SdkFeatureRegistry.sdkFileForPublicPath'),
    );
    expect(
      authorityGateway,
      contains('<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'),
    );
    expect(localTunnel, isNot(contains('SdkFeatureRegistry')));
    expect(localTunnel, isNot(contains('playmesh-app.js')));
    expect(remote, isNot(contains('playmeshAppSdkUrl')));
    expect(remote, isNot(contains('local_app_sdk_server')));
  });

  test('本地 Flutter 与 Windows WebView 共用同一 document reset 边界', () {
    final local = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();
    final windows = File(
      'lib/features/game/windows_local_game_web_view_io.dart',
    ).readAsStringSync();

    expect(
      local,
      contains('void _resetAppSdkDocument()'),
      reason: 'document 切换必须由一个共享入口清理 App Bridge 与 LAN 短期状态',
    );
    expect(
      RegExp(
        r'onPageStarted:\s*\(_\)\s*\{[^}]*_resetAppSdkDocument\(\);[^}]*_messageQueue\.pause\(clearPending: true\);',
        multiLine: true,
      ).hasMatch(local),
      isTrue,
    );
    expect(local, contains('onNavigationStarted: _resetAppSdkDocument'));

    final handlerStart = local.indexOf('void _resetAppSdkDocument()');
    if (handlerStart >= 0) {
      final handlerEnd = local.indexOf('\n  }', handlerStart);
      final handler = local.substring(handlerStart, handlerEnd + 4);
      expect(handler, contains('_resetAppSdkInputOwnership();'));
      expect(handler, contains('_appBridge.resetCapabilities()'));
    }
    expect(
      RegExp(
        r'if \(state == LoadingState\.loading\) \{[^}]*_sdkMessages\.notifyNavigationLoading\(\);[^}]*widget\.onNavigationStarted\?\.call\(\);',
        multiLine: true,
      ).hasMatch(windows),
      isTrue,
      reason: 'Windows 必须先切换自身消息 generation，再调用同一 App document reset',
    );
  });
}
