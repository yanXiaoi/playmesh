import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/relay/relay_tunnel.dart';
import 'package:playmesh/features/game/remote_game_page.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('远程游戏页复用预检 Relay 会话并由 WebView 邀请入口建立 Cookie', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final relaySession = _FakeRelayClientSession();
    try {
      await tester.pumpWidget(
        localizedTestApp(
          home: RemoteGamePage(
            entryUri: Uri.parse(
              'https://relay.example/j/room_123#inviteToken=relay-token',
            ),
            userId: 'local-user',
            nickname: '本机玩家',
            preparedRelayClientSession: relaySession,
            resolvedEntryPath: '/controller/index.html',
            gameId: 'com.example.game',
            gameName: '示例游戏',
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text(
          'http://127.0.0.1:45001/playmesh/join'
          '#inviteToken=authority-token',
        ),
        findsOneWidget,
        reason: 'Dart 预检 Cookie 不能交给 WebView，WebView 必须在复用会话内自行换票',
      );
      expect(relaySession.closeCount, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(relaySession.closeCount, 1);
    } finally {
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });

  testWidgets('局域网预检后仍由 WebView 邀请入口建立 Cookie', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(
        localizedTestApp(
          home: RemoteGamePage(
            entryUri: Uri.parse(
              'http://192.0.2.1:34567/playmesh/join'
              '#inviteToken=lan-token',
            ),
            userId: 'local-user',
            nickname: '本机玩家',
            resolvedEntryPath: '/controller/index.html',
            gameId: 'com.example.game',
            gameName: '示例游戏',
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('/playmesh/join#inviteToken=lan-token'),
        findsOneWidget,
        reason: 'LAN 预检 Cookie 同样不能跨入 WebView，不能直接打开受控 entry',
      );
      expect(find.textContaining('/controller/index.html'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = previousPlatform;
    }
  });
}

final class _FakeRelayClientSession implements RelayClientSession {
  _FakeRelayClientSession()
    : webGateway = _FakeRelayClientGateway(
        localBaseUri: Uri.parse('http://127.0.0.1:45001/'),
        localEntryUri: Uri.parse(
          'http://127.0.0.1:45001/playmesh/join'
          '#inviteToken=authority-token',
        ),
      ),
      coreGateway = _FakeRelayClientGateway(
        localBaseUri: Uri.parse('http://127.0.0.1:45002/'),
        localEntryUri: Uri.parse('http://127.0.0.1:45002/'),
      );

  @override
  final RelayClientGateway webGateway;

  @override
  final RelayClientGateway coreGateway;

  int closeCount = 0;

  @override
  String get connectionMode => 'relay';

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _FakeRelayClientGateway implements RelayClientGateway {
  const _FakeRelayClientGateway({
    required this.localBaseUri,
    required this.localEntryUri,
  });

  @override
  final Uri localBaseUri;

  @override
  final Uri localEntryUri;

  @override
  Future<void> close() async {}
}
