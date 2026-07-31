import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('加入端 Flutter WebView 把请求统一交给 App Bridge', () {
    final remoteSource = File(
      'lib/features/game/remote_game_page.dart',
    ).readAsStringSync();
    final localSource = File(
      'lib/features/game/local_game_web_view.dart',
    ).readAsStringSync();

    expect(remoteSource, contains('onPermissionRequest: (request)'));
    expect(remoteSource, contains('_handleWebPermissionRequest(request)'));
    expect(remoteSource, contains('_appBridge!.authorizeWebPermissions('));
    expect(
      remoteSource,
      contains('webPermissionRole: AppWebPermissionRole.joiner'),
    );
    expect(remoteSource, contains('await request.grant()'));
    expect(remoteSource, contains('await request.deny()'));
    expect(remoteSource, contains('setOnShowFileSelector'));
    expect(
      remoteSource,
      contains('onNavigationStarted: _handleNavigationStarted'),
    );
    expect(localSource, contains('_appBridge.authorizeWebPermissions('));
  });

  test('加入端平台上下文只由 App SDK Bridge 返回而不写入 URL', () {
    final remoteSource = File(
      'lib/features/game/remote_game_page.dart',
    ).readAsStringSync();
    final gatewaySource = File(
      'lib/core/game_web/game_web_gateway_io.dart',
    ).readAsStringSync();

    expect(remoteSource, contains("'PlaymeshAppBridge'"));
    expect(remoteSource, contains('AppWebViewBridge('));
    expect(remoteSource, isNot(contains('local_app_sdk_server')));
    expect(remoteSource, isNot(contains("'playmeshApp'")));
    expect(remoteSource, isNot(contains("'playmeshAppSdkUrl'")));
    expect(remoteSource, isNot(contains("'playmeshNickname'")));
    expect(
      gatewaySource,
      contains('<script src="/playmesh/sdk/v1/playmesh-app.js"></script>'),
    );
    expect(gatewaySource, isNot(contains("queryParameters['playmeshApp']")));
    expect(
      gatewaySource,
      isNot(contains("queryParameters['playmeshAppSdkUrl']")),
    );
    expect(
      gatewaySource,
      isNot(contains("queryParameters['playmeshNickname']")),
    );
    expect(gatewaySource, isNot(contains("'channelId'")));
    expect(gatewaySource, contains('..httpOnly = true'));
    expect(gatewaySource, contains('..sameSite = SameSite.strict'));
    expect(gatewaySource, contains('location.replace(result.entry)'));
  });

  test('Windows WebView 不识别具体能力并统一交给 App Bridge', () {
    final source = File(
      'lib/features/game/windows_local_game_web_view_io.dart',
    ).readAsStringSync();

    expect(source, contains('widget.appBridge?.authorizeWebPermissions('));
    expect(source, contains('[kind.name],'));
    expect(source, contains('sourceUri: Uri.tryParse(url)'));
    expect(source, contains('isUserInitiated: isUserInitiated'));
    expect(source, isNot(contains('CameraCapabilityPlugin')));
    expect(source, isNot(contains('AudioCapabilityPlugin')));
    expect(source, isNot(contains('WebviewPermissionKind.camera =>')));
    expect(source, contains('WebviewPermissionDecision.allow'));
    expect(source, contains('WebviewPermissionDecision.deny'));
  });
}
