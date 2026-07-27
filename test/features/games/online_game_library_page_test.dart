import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/catalog/game_catalog_models.dart';
import 'package:playmesh/core/catalog/online_game_catalog.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/core/game_package/game_package_transfer_service.dart';
import 'package:playmesh/features/games/online_game_library_page.dart';
import 'package:playmesh/models/game_manifest.dart';
import 'package:playmesh/models/game_summary.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets(
    'home source errors, retries, and pagination remain independent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('playmesh-online-widget-'),
      ))!;
      final first = _source(id: 'first', name: '用户源 First / 原样');
      final second = _source(id: 'second', name: 'API Source β');
      final calls = <String, List<int>>{first.id: <int>[], second.id: <int>[]};
      var secondAvailable = false;
      late OnlineCatalogGame firstPageOffer;
      final controller = _FakeCatalogController(
        root: root,
        sources: [first, second],
        loadHome: (sourceId, page, _) async {
          calls[sourceId]!.add(page);
          final source = sourceId == first.id ? first : second;
          if (sourceId == second.id && !secondAvailable) {
            return SourceSectionResult(
              source: source,
              offers: const [],
              total: 0,
              page: page,
              error: 'HTTP 503 from API Source β',
            );
          }
          final suffix = sourceId == first.id && page == 2 ? 'second' : 'first';
          final offer = _offer(
            source,
            id: 'com.example.$sourceId.$suffix',
            name: '$sourceId game $suffix / 原样',
          );
          if (sourceId == first.id && page == 1) firstPageOffer = offer;
          return SourceSectionResult(
            source: source,
            offers: [offer],
            total: sourceId == first.id ? 2 : 1,
            page: page,
          );
        },
      );
      addTearDown(
        () => tester.runAsync(() async {
          await controller.close();
          await root.delete(recursive: true);
        }),
      );

      await tester.pumpWidget(
        localizedTestApp(home: OnlineGameLibraryPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('扫码添加游戏源'), findsOneWidget);
      expect(find.text(first.name), findsOneWidget);
      expect(find.text(second.name), findsOneWidget);
      expect(find.text('first game first / 原样'), findsOneWidget);
      expect(find.textContaining('HTTP 503 from API Source β'), findsOneWidget);
      expect(calls[first.id], [1]);
      expect(calls[second.id], [1]);
      final firstOfferAction = tester.widget<IconButton>(
        find.byKey(
          ValueKey('catalog-home-offer-action-${firstPageOffer.downloadKey}'),
        ),
      );
      expect(firstOfferAction.focusNode!.hasFocus, isTrue);

      final firstSection = find.byKey(const ValueKey('catalog-home-first'));
      final loadMore = find.descendant(
        of: firstSection,
        matching: find.byType(OutlinedButton),
      );
      expect(loadMore, findsOneWidget);
      final loadMoreButton = tester.widget<OutlinedButton>(loadMore);
      loadMoreButton.focusNode!.requestFocus();
      await tester.pump();
      expect(loadMoreButton.focusNode!.hasFocus, isTrue);
      loadMoreButton.onPressed!();
      await tester.pumpAndSettle();

      expect(find.text('first game second / 原样'), findsOneWidget);
      expect(find.textContaining('HTTP 503 from API Source β'), findsOneWidget);
      expect(calls[first.id], [1, 2]);
      expect(calls[second.id], [1]);
      final fallbackAction = tester.widget<IconButton>(
        find.byKey(
          ValueKey('catalog-home-offer-action-${firstPageOffer.downloadKey}'),
        ),
      );
      expect(
        fallbackAction.focusNode!.hasFocus,
        isTrue,
        reason:
            'When pagination removes the focused load-more action, focus must '
            'return to the nearest surviving offer.',
      );

      secondAvailable = true;
      final secondSection = find.byKey(const ValueKey('catalog-home-second'));
      final retry = find.descendant(
        of: secondSection,
        matching: find.byType(TextButton),
      );
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();

      expect(find.text('second game first / 原样'), findsOneWidget);
      expect(find.text('first game second / 原样'), findsOneWidget);
      expect(calls[first.id], [1, 2]);
      expect(calls[second.id], [1, 1]);
    },
  );

  testWidgets(
    'source details paint cached declaration before background refresh',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('playmesh-source-detail-widget-'),
      ))!;
      final cached = _source(
        id: 'cached',
        name: '本地自定义源名 Ω',
        declarationName: 'Cached API Name / 原样',
        declarationAuthor: 'Cached Publisher',
      );
      final refreshed = _source(
        id: cached.id,
        name: cached.name,
        declarationName: 'Fresh API Name / 原样',
        declarationAuthor: 'Fresh Publisher',
      );
      final refreshGate = Completer<OnlineGameSource>();
      var refreshCalls = 0;
      final controller = _FakeCatalogController(
        root: root,
        sources: [cached],
        refreshDeclaration: (_) {
          refreshCalls += 1;
          return refreshGate.future;
        },
      );
      addTearDown(
        () => tester.runAsync(() async {
          await controller.close();
          await root.delete(recursive: true);
        }),
      );

      await tester.pumpWidget(
        localizedTestApp(
          home: CatalogSourceDetailPage(
            controller: controller,
            sourceId: cached.id,
          ),
        ),
      );

      expect(find.text(cached.name), findsWidgets);
      expect(find.text('Cached API Name / 原样'), findsOneWidget);
      expect(find.text('Cached Publisher'), findsOneWidget);
      expect(find.text('Fresh API Name / 原样'), findsNothing);
      expect(refreshCalls, 1);

      refreshGate.complete(refreshed);
      await tester.pumpAndSettle();

      expect(find.text(cached.name), findsWidgets);
      expect(find.text('Cached API Name / 原样'), findsNothing);
      expect(find.text('Fresh API Name / 原样'), findsOneWidget);
      expect(find.text('Fresh Publisher'), findsOneWidget);
      expect(refreshCalls, 1);
    },
  );

  testWidgets('游戏源管理不显示 publicURL 验证实现提示', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('playmesh-source-list-widget-'),
    ))!;
    final controller = _FakeCatalogController(root: root, sources: const []);
    addTearDown(
      () => tester.runAsync(() async {
        await controller.close();
        await root.delete(recursive: true);
      }),
    );

    await tester.pumpWidget(
      localizedTestApp(home: CatalogSourcesPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('扫码添加游戏源'), findsOneWidget);
    expect(find.textContaining('publicURL'), findsNothing);
    expect(find.textContaining('/apps/info'), findsNothing);
  });
}

typedef _HomeLoader =
    Future<SourceSectionResult> Function(
      String sourceId,
      int page,
      String? cursor,
    );
typedef _DeclarationRefresher =
    Future<OnlineGameSource> Function(String sourceId);

class _FakeCatalogController extends GameCatalogController {
  _FakeCatalogController({
    required Directory root,
    required List<OnlineGameSource> sources,
    this._loadHome,
    this._refreshDeclaration,
  }) : _sources = [...sources],
       super(
         library: GameLibraryRepository(
           () async => const <GameSummary>[],
           initialGames: const <GameSummary>[],
         ),
         transfer: GamePackageTransferService(libraryRoot: root),
         onImported: (_) async {},
         nicknameProvider: () => 'Tester',
       );

  final List<OnlineGameSource> _sources;
  final _HomeLoader? _loadHome;
  final _DeclarationRefresher? _refreshDeclaration;

  @override
  List<OnlineGameSource> get sources => List.unmodifiable(_sources);

  @override
  Future<void> initialize() async {}

  @override
  Future<SourceSectionResult> loadHomeSource(
    String sourceId, {
    int page = 1,
    String? cursor,
  }) {
    final loader = _loadHome;
    if (loader == null) {
      throw StateError('No home loader configured');
    }
    return loader(sourceId, page, cursor);
  }

  @override
  Future<List<int>?> loadOfferIcon(OnlineCatalogGame offer) async => null;

  @override
  Future<OnlineGameSourceProbe> refreshSourceDeclaration(String id) async {
    final refresher = _refreshDeclaration;
    if (refresher == null) {
      throw StateError('No declaration refresher configured');
    }
    final refreshed = await refresher(id);
    final index = _sources.indexWhere((source) => source.id == id);
    if (index < 0) throw StateError('Unknown source: $id');
    _sources[index] = refreshed;
    notifyListeners();
    return OnlineGameSourceProbe(
      source: refreshed,
      elapsed: Duration.zero,
      declaration: refreshed.declaration,
    );
  }
}

OnlineGameSource _source({
  required String id,
  required String name,
  String? declarationName,
  String? declarationAuthor,
}) {
  final declaration = declarationName == null
      ? null
      : GameCatalogDeclaration(
          catalogApiVersion: gameCatalogApiVersion,
          name: declarationName,
          author: declarationAuthor,
          supportsGameRelay: false,
        );
  return OnlineGameSource(
    id: id,
    name: name,
    host: Uri.parse('https://$id.example.test'),
    declaration: declaration,
    lastValidatedAt: declaration == null ? null : DateTime.utc(2026, 7, 26),
  );
}

OnlineCatalogGame _offer(
  OnlineGameSource source, {
  required String id,
  required String name,
}) {
  return OnlineCatalogGame(
    source: source,
    manifest: GameManifest(
      id: id,
      name: name,
      author: 'Publisher value / 原样',
      lastModifiedAt: DateTime.utc(2026, 7, 26),
      remarks: 'API remarks / 原样',
      version: '1.0.0',
      sdkVersion: '1.0.0',
      appSdkVersion: '1.0.0',
      orientation: GameOrientation.landscape,
      modes: const {GameMode.solo},
      displayModes: const {GameDisplayMode.multiScreen},
      players: const GamePlayerLimits(min: 1, max: 1),
      tags: const ['API tag / 原样'],
      entries: const GameEntriesManifest(
        game: 'app/index.html',
        controller: 'app/controller/index.html',
      ),
    ),
  );
}
