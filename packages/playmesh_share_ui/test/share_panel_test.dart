import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh_share_ui/playmesh_share_ui.dart';

void main() {
  const strings = PlaymeshSharePanelStrings(
    closeTooltip: 'Close',
    lanTab: 'LAN',
    internetTab: 'Internet',
    roomTab: 'Room',
    lanHint: 'Share with players on this network.',
    internetHint: 'Share with players over the internet.',
    roomHint: 'Players who joined this room.',
    noLanLinks: 'No LAN link',
    noInternetLinks: 'No internet link',
    noPlayers: 'No players',
    serverSearchHint: 'Search servers',
    noServers: 'No servers',
    refreshServersTooltip: 'Refresh servers',
    disconnectServer: 'Disconnect',
    shareLinkTooltip: 'Share link',
    copyLinkTooltip: 'Copy link',
    qrSemantics: 'Join QR code',
    playerOnline: 'Online',
    playerOffline: 'Offline',
  );

  test('compact labels never expose a path, query, fragment, or scheme', () {
    expect(
      playmeshCompactShareLink(
        Uri.parse(
          'https://very-long.example.test:16668/private/invite/token-value'
          '?token=secret#fragment',
        ),
      ),
      'very-long.example.test:16668',
    );
    expect(
      playmeshCompactShareLink(
        Uri.parse('playmesh:///private/invite?token=secret'),
      ),
      'link',
    );
  });

  testWidgets(
    'narrow panel does not overflow or expose long invitation credentials',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();

      final invitation = Uri.parse(
        'https://very-long-host-name-for-a-phone.example.test:16668/'
        'private/invite/credential-in-path?token=query-secret#fragment-secret',
      );
      PlaymeshShareLink? actedOn;
      await tester.pumpWidget(
        _TestHost(
          child: PlaymeshSharePanel(
            model: PlaymeshSharePanelModel(
              title: 'Share this game',
              lanLinks: <PlaymeshShareLink>[
                PlaymeshShareLink(id: 'long', url: invitation),
              ],
              selectedLanLinkId: 'long',
            ),
            strings: strings,
            actionMode: PlaymeshShareActionMode.share,
            onClose: () {},
            onLinkAction: (link) => actedOn = link,
            onSelectLanLink: (_) {},
            maxHeight: 620,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('credential-in-path'), findsNothing);
      expect(find.textContaining('query-secret'), findsNothing);
      expect(find.textContaining('fragment-secret'), findsNothing);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('very-long-host-name'), findsOneWidget);

      final linkSemantics = tester.getSemantics(
        find.byKey(const ValueKey<String>('share-link-long')),
      );
      final actionSemantics = tester.getSemantics(
        find.byKey(const ValueKey<String>('share-link-action-long')),
      );
      final semanticsDump = '$linkSemantics\n$actionSemantics';
      expect(semanticsDump, isNot(contains('credential-in-path')));
      expect(semanticsDump, isNot(contains('query-secret')));
      expect(semanticsDump, isNot(contains('fragment-secret')));

      await tester.tap(
        find.byKey(const ValueKey<String>('share-link-action-long')),
      );
      await tester.pump();
      expect(actedOn?.url, invitation);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('fixed runtime internet link works without a server catalog', (
    tester,
  ) async {
    final invitation = Uri.parse('http://relay.example.test/join?token=secret');
    PlaymeshShareLink? actedOn;
    await tester.pumpWidget(
      _TestHost(
        child: PlaymeshSharePanel(
          model: PlaymeshSharePanelModel(
            title: 'Share',
            internetLinks: <PlaymeshShareLink>[
              PlaymeshShareLink(id: 'fixed-relay', url: invitation),
            ],
            selectedInternetLinkId: 'fixed-relay',
            initialSection: PlaymeshShareSection.internet,
          ),
          strings: strings,
          actionMode: PlaymeshShareActionMode.copy,
          onClose: () {},
          onLinkAction: (link) => actedOn = link,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(strings.internetHint), findsOneWidget);
    expect(find.byKey(const Key('share-server-search')), findsNothing);
    expect(find.textContaining('token='), findsNothing);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('share-link-action-fixed-relay')),
    );
    await tester.pump();
    expect(actedOn?.url, invitation);
  });

  testWidgets('server catalog searches by name and reports stable ids', (
    tester,
  ) async {
    String? selectedId;
    await tester.pumpWidget(
      _TestHost(
        child: PlaymeshSharePanel(
          model: const PlaymeshSharePanelModel(
            title: 'Share',
            initialSection: PlaymeshShareSection.internet,
            serverCatalog: PlaymeshShareServerCatalog(
              options: <PlaymeshShareServerOption>[
                PlaymeshShareServerOption(id: 'alpha-id', name: 'Alpha'),
                PlaymeshShareServerOption(
                  id: 'beta-id',
                  name: 'Beta',
                  latencyMilliseconds: 42,
                ),
              ],
            ),
          ),
          strings: strings,
          actionMode: PlaymeshShareActionMode.copy,
          onClose: () {},
          onLinkAction: (_) {},
          onServerSelected: (id) => selectedId = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('share-server-search')),
      'beta',
    );
    await tester.pump();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('42 ms'), findsOneWidget);
    expect(find.textContaining('http://'), findsNothing);
    expect(find.textContaining('token='), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('share-server-beta-id')),
    );
    await tester.pump();
    expect(selectedId, 'beta-id');
  });

  testWidgets('public state restores close focus and Escape closes', (
    tester,
  ) async {
    final panelKey = GlobalKey<PlaymeshSharePanelState>();
    var closeCount = 0;
    await tester.pumpWidget(
      _TestHost(
        child: PlaymeshSharePanel(
          key: panelKey,
          model: const PlaymeshSharePanelModel(title: 'Share'),
          strings: strings,
          actionMode: PlaymeshShareActionMode.copy,
          onClose: () => closeCount += 1,
          onLinkAction: (_) {},
        ),
      ),
    );
    await tester.pump();

    panelKey.currentState!.requestCloseFocus();
    await tester.pump();
    expect(
      tester.binding.focusManager.primaryFocus?.debugLabel,
      'playmesh-share-close',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closeCount, 1);
  });
}

class _TestHost extends StatelessWidget {
  const _TestHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: Scaffold(
        body: Center(
          child: Padding(padding: const EdgeInsets.all(8), child: child),
        ),
      ),
    );
  }
}
