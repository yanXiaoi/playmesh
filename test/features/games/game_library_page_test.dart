import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/features/games/game_library_page.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

import '../../support/localized_test_app.dart';

const _alpha = GameSummary(
  id: 'com.playmesh.alpha',
  name: 'Alpha',
  version: '1.0.0',
  author: 'North Studio',
  description: 'A local puzzle game',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '单屏',
  displayMode: 'single_screen_multiplayer',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);

const _beta = GameSummary(
  id: 'com.playmesh.beta',
  name: 'Beta',
  version: '2.1.0',
  author: 'South Studio',
  description: 'A local party game',
  minPlayers: 2,
  maxPlayers: 4,
  supportsMultiplayer: true,
  displayModeLabel: '多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.portrait,
  tags: ['party'],
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);

GameSummary _numberedGame(int number) => GameSummary(
  id: 'com.playmesh.local.$number',
  name: 'Local $number',
  version: '1.0.0',
  author: 'Local Studio',
  description: 'Local game $number',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: 'Single',
  displayMode: 'single_screen_multiplayer',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(gameEntryPath: 'index.html', statusLabel: 'Ready'),
);

GameLibraryQueryResult _queryResult(
  List<GameSummary> games, {
  int revision = 0,
  int offset = 0,
  int limit = 10,
}) => GameLibraryQueryResult(
  games: games.sublist(
    offset.clamp(0, games.length),
    (offset + limit).clamp(0, games.length),
  ),
  total: games.length,
  offset: offset.clamp(0, games.length),
  revision: revision,
  refreshedAt: null,
);

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('本地游戏库内提供唯一的在线游戏库入口', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [],
          onRefresh: () async => const [],
          onQuery: (_, {required offset, required limit}) =>
              _queryResult(const [], offset: offset, limit: limit),
          onOpenOnline: () => opened = true,
        ),
      ),
    );

    expect(find.byTooltip('浏览在线游戏'), findsOneWidget);
    await tester.tap(find.byTooltip('浏览在线游戏'));
    expect(opened, isTrue);
  });

  testWidgets('搜索只查询注入的内存索引并保持返回顺序', (tester) async {
    var refreshCalls = 0;
    final queries = <String>[];
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [_alpha, _beta],
          onRefresh: () async {
            refreshCalls += 1;
            return const [_alpha, _beta];
          },
          onQuery: (query, {required offset, required limit}) {
            queries.add(query);
            return _queryResult(
              query.trim().isEmpty ? const [_beta, _alpha] : const [_beta],
              revision: 7,
              offset: offset,
              limit: limit,
            );
          },
        ),
      ),
    );

    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Beta')).dy,
      lessThan(tester.getTopLeft(find.text('Alpha')).dy),
    );
    expect(find.text('A local puzzle game'), findsOneWidget);
    expect(find.text('A local party game'), findsOneWidget);
    expect(find.text('发布者：North Studio'), findsOneWidget);
    expect(find.text('发布者：South Studio'), findsOneWidget);
    expect(find.text('v1.0.0 · 单机 · 单屏多人 · 横屏'), findsOneWidget);
    expect(find.text('v2.1.0 · 多人 · 多屏多人 · 竖屏'), findsOneWidget);
    expect(find.text('party'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'party');
    await tester.pump(const Duration(milliseconds: 201));

    expect(queries.last, 'party');
    expect(refreshCalls, 0);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('匹配 1 / 1 个本地游戏'), findsOneWidget);
  });

  testWidgets('Ctrl+F 聚焦唯一搜索框', (tester) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [_alpha],
          onRefresh: () async => const [_alpha],
          onQuery: (_, {required offset, required limit}) =>
              _queryResult(const [_alpha], offset: offset, limit: limit),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode?.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(field.focusNode?.hasFocus, isTrue);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('异步重排按 gameId 恢复焦点，删除后回退到最近游戏', (tester) async {
    final games = ValueNotifier<List<GameSummary>>(const [_alpha, _beta]);
    addTearDown(games.dispose);

    await tester.pumpWidget(
      localizedTestApp(
        home: ValueListenableBuilder<List<GameSummary>>(
          valueListenable: games,
          builder: (context, value, _) => GameLibraryPage(
            games: value,
            onRefresh: () async => value,
            onQuery: (_, {required offset, required limit}) =>
                _queryResult(value, offset: offset, limit: limit),
          ),
        ),
      ),
    );

    final betaButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.beta')),
    );
    betaButton.focusNode!.requestFocus();
    await tester.pump();
    expect(betaButton.focusNode!.hasFocus, isTrue);

    games.value = const [_beta, _alpha];
    await tester.pump();
    await tester.pump();
    final reorderedBetaButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.beta')),
    );
    expect(reorderedBetaButton.focusNode!.hasFocus, isTrue);

    games.value = const [_alpha];
    await tester.pump();
    await tester.pump();
    final alphaButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.alpha')),
    );
    expect(alphaButton.focusNode!.hasFocus, isTrue);
  });

  testWidgets('本地游戏库按页查询且方向键可在游戏间移动焦点', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final games = List.generate(25, (index) => _numberedGame(index + 1));
    final offsets = <int>[];

    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: games,
          onRefresh: () async => games,
          onQuery: (_, {required offset, required limit}) {
            offsets.add(offset);
            return _queryResult(games, offset: offset, limit: limit);
          },
        ),
      ),
    );
    await tester.pump();

    expect(offsets, [0]);
    expect(find.text('Local 1'), findsOneWidget);
    expect(find.text('Local 11'), findsNothing);
    final first = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.local.1')),
    );
    expect(first.focusNode!.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final second = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.local.2')),
    );
    expect(second.focusNode!.hasFocus, isTrue);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('game-library-next-page')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('game-library-next-page')));
    await tester.pumpAndSettle();

    expect(offsets.last, 10);
    expect(find.text('Local 1'), findsNothing);
    expect(find.text('Local 11'), findsOneWidget);
    final eleventh = tester.widget<FilledButton>(
      find.byKey(const ValueKey('game-tile-action-com.playmesh.local.11')),
    );
    expect(eleventh.focusNode!.hasFocus, isTrue);
  });

  testWidgets(
    'background update check keeps local library usable and queues post-install recheck',
    (tester) async {
      final firstCheck = Completer<GameUpdateCheckResult>();
      final checkedIds = <List<String>>[];
      final games = ValueNotifier<List<GameSummary>>(const [_alpha]);
      addTearDown(games.dispose);

      await tester.pumpWidget(
        localizedTestApp(
          home: ValueListenableBuilder<List<GameSummary>>(
            valueListenable: games,
            builder: (context, value, _) => GameLibraryPage(
              games: value,
              onRefresh: () async => value,
              onQuery: (_, {required offset, required limit}) =>
                  _queryResult(value, offset: offset, limit: limit),
              onCheckUpdates: (installed) {
                checkedIds.add(
                  installed.map((game) => game.id).toList(growable: false),
                );
                return checkedIds.length == 1
                    ? firstCheck.future
                    : Future.value(_updateCheckResult());
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(checkedIds, [
        [_alpha.id],
      ]);
      expect(find.text(_alpha.name), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isNot(false),
      );

      games.value = const [_alpha, _beta];
      await tester.pump();
      expect(find.text(_beta.name), findsOneWidget);
      expect(checkedIds, hasLength(1));

      firstCheck.complete(_updateCheckResult());
      await tester.pumpAndSettle();

      expect(checkedIds, [
        [_alpha.id],
        [_alpha.id, _beta.id],
      ]);
    },
  );

  testWidgets('removing the last game invalidates an in-flight update check', (
    tester,
  ) async {
    final pending = Completer<GameUpdateCheckResult>();
    final games = ValueNotifier<List<GameSummary>>(const [_alpha]);
    addTearDown(games.dispose);
    final offer = _updateOffer(
      sourceId: 'stale',
      sourceName: 'Stale source / 原样',
      version: '2.0.0',
    );
    final staleUpdate = GameUpdateCandidate(
      gameId: _alpha.id,
      publisher: _alpha.author,
      installedVersion: _alpha.version,
      versions: [
        GameUpdateVersion(
          targetVersion: '2.0.0',
          sources: [_updateSource(offer)],
        ),
      ],
    );

    await tester.pumpWidget(
      localizedTestApp(
        home: ValueListenableBuilder<List<GameSummary>>(
          valueListenable: games,
          builder: (context, value, _) => GameLibraryPage(
            games: value,
            onRefresh: () async => value,
            onQuery: (_, {required offset, required limit}) =>
                _queryResult(value, offset: offset, limit: limit),
            onCheckUpdates: (_) => pending.future,
          ),
        ),
      ),
    );
    await tester.pump();

    games.value = const [];
    await tester.pump();
    pending.complete(_updateCheckResult(candidates: [staleUpdate]));
    await tester.pumpAndSettle();

    expect(find.byTooltip('可更新 1 项'), findsNothing);
    expect(
      find.byKey(const ValueKey('library-update-check-current')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-update-check-partial')),
      findsNothing,
    );
  });

  testWidgets('user selects the exact update version and source', (
    tester,
  ) async {
    final preferredOffer = _updateOffer(
      sourceId: 'preferred',
      sourceName: '用户自定义源 β / 原样',
      version: '2.0.0',
    );
    final update = GameUpdateCandidate(
      gameId: _alpha.id,
      publisher: _alpha.author,
      installedVersion: _alpha.version,
      versions: [
        GameUpdateVersion(
          targetVersion: '3.0.0',
          sources: [
            _updateSource(
              _updateOffer(
                sourceId: 'latest',
                sourceName: 'API Source Latest / 原样',
                version: '3.0.0',
              ),
            ),
          ],
        ),
        GameUpdateVersion(
          targetVersion: '2.0.0',
          sources: [
            _updateSource(
              _updateOffer(
                sourceId: 'alternate',
                sourceName: 'API Source Alternate / 原样',
                version: '2.0.0',
              ),
            ),
            _updateSource(preferredOffer),
          ],
        ),
      ],
    );
    OnlineCatalogGame? selected;

    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [_alpha],
          onRefresh: () async => const [_alpha],
          onQuery: (_, {required offset, required limit}) =>
              _queryResult(const [_alpha], offset: offset, limit: limit),
          onCheckUpdates: (_) async => _updateCheckResult(candidates: [update]),
          onDownloadUpdate: (offer) async {
            selected = offer;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextButton), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(find.text('API Source Latest / 原样'), findsOneWidget);
    expect(find.text('API Source Alternate / 原样'), findsOneWidget);
    expect(find.text('用户自定义源 β / 原样'), findsOneWidget);
    final preferredTile = find.ancestor(
      of: find.text('用户自定义源 β / 原样'),
      matching: find.byType(ListTile),
    );
    expect(preferredTile, findsOneWidget);
    await tester.tap(
      find.descendant(of: preferredTile, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();

    expect(selected, same(preferredOffer));
    expect(selected?.manifest.version, '2.0.0');
    expect(selected?.source.name, '用户自定义源 β / 原样');
  });

  testWidgets('no updates stays silent without a fixed success notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [_alpha],
          onRefresh: () async => const [_alpha],
          onQuery: (_, {required offset, required limit}) =>
              _queryResult(const [_alpha], offset: offset, limit: limit),
          onCheckUpdates: (_) async => _updateCheckResult(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-update-check-current')),
      findsNothing,
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('partial update summary keeps source names and logs raw', (
    tester,
  ) async {
    const sourceName = '用户自定义源 β / 原样';
    const diagnostic = 'SocketException: raw-source-diagnostic-Ω';
    await tester.pumpWidget(
      localizedTestApp(
        home: GameLibraryPage(
          games: const [_alpha],
          onRefresh: () async => const [_alpha],
          onQuery: (_, {required offset, required limit}) =>
              _queryResult(const [_alpha], offset: offset, limit: limit),
          onCheckUpdates: (_) async => _updateCheckResult(
            sourceErrors: const [
              GameUpdateSourceError(
                sourceId: 'raw-source',
                localSourceName: sourceName,
                message: diagnostic,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-update-check-partial')),
      findsOneWidget,
    );
    expect(find.textContaining(sourceName), findsOneWidget);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-update-source-errors-dialog')),
      findsOneWidget,
    );
    expect(find.text(sourceName), findsOneWidget);
    expect(find.text(diagnostic), findsOneWidget);
  });
}

GameUpdateCheckResult _updateCheckResult({
  List<GameUpdateCandidate> candidates = const [],
  List<GameUpdateSourceError> sourceErrors = const [],
}) => GameUpdateCheckResult(
  candidates: candidates,
  sourceErrors: sourceErrors,
  checkedAt: DateTime.utc(2026, 7, 26, 8, 30),
);

OnlineCatalogGame _updateOffer({
  required String sourceId,
  required String sourceName,
  required String version,
}) {
  final source = OnlineGameSource(
    id: sourceId,
    name: sourceName,
    host: Uri.parse('https://$sourceId.example.test'),
  );
  return OnlineCatalogGame(
    source: source,
    manifest: GameManifest(
      id: _alpha.id,
      name: 'API Game Name / 原样',
      author: _alpha.author,
      lastModifiedAt: DateTime.utc(2026, 7, 26),
      remarks: 'API description / 原样',
      version: version,
      sdkVersion: '4.0.0',
      appSdkVersion: '3.2.0',
      orientation: GameOrientation.landscape,
      modes: const {GameMode.solo},
      displayModes: const {GameDisplayMode.singleScreenMultiplayer},
      players: const GamePlayerLimits(min: 1, max: 1),
      tags: const ['API tag / 原样'],
      entries: const GameEntriesManifest(game: 'index.html'),
    ),
  );
}

GameUpdateSource _updateSource(OnlineCatalogGame offer) => GameUpdateSource(
  sourceId: offer.source.id,
  localSourceName: offer.source.name,
  host: offer.source.host,
  offer: offer,
);
