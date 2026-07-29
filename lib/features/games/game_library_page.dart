import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/catalog/game_catalog_models.dart';
import '../../core/game_package/game_package_icon.dart';
import '../../core/game_package/game_library_repository.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../models/game_summary.dart';
import '../../ui/focus/playmesh_shortcuts.dart';
import '../../ui/game_tags.dart';
import '../../ui/playmesh_ui.dart';
import 'game_detail_page.dart';

typedef GameLibraryRefresh = Future<List<GameSummary>> Function();
typedef GamePackageImport = Future<GameSummary> Function(String path);
typedef GameLibraryQuery =
    GameLibraryQueryResult Function(
      String search, {
      required int offset,
      required int limit,
    });
typedef GameLibraryUpdateCheck =
    Future<GameUpdateCheckResult> Function(
      Iterable<GameSummary> installedGames,
    );
typedef GameLibraryUpdateDownload =
    Future<void> Function(OnlineCatalogGame offer);

class GameLibraryPage extends StatefulWidget {
  const GameLibraryPage({
    super.key,
    required this.games,
    required this.onRefresh,
    required this.onQuery,
    this.onImport,
    this.onOpenOnline,
    this.onCheckUpdates,
    this.onDownloadUpdate,
  });

  static const routeName = '/games';

  final List<GameSummary> games;
  final GameLibraryRefresh onRefresh;
  final GamePackageImport? onImport;
  final VoidCallback? onOpenOnline;

  /// Queries an existing in-memory index. Implementations must not scan disk or
  /// access the network.
  final GameLibraryQuery onQuery;
  final GameLibraryUpdateCheck? onCheckUpdates;
  final GameLibraryUpdateDownload? onDownloadUpdate;

  @override
  State<GameLibraryPage> createState() => _GameLibraryPageState();
}

class _GameLibraryPageState extends State<GameLibraryPage> {
  static const _pageSize = 10;

  late List<GameSummary> _games;
  List<GameSummary> _visibleGames = const [];
  int _totalMatches = 0;
  int _pageIndex = 0;
  int _libraryRevision = 0;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'game-library-search');
  final _previousPageFocusNode = FocusNode(
    debugLabel: 'game-library-previous-page',
  );
  final _nextPageFocusNode = FocusNode(debugLabel: 'game-library-next-page');
  final _scrollController = ScrollController();
  final _gameFocusRestoration = PlaymeshFocusRestorationController();
  final Map<String, FocusNode> _gameFocusNodes = {};
  Timer? _searchDebounce;
  double _fullListScrollOffset = 0;
  bool _searchActive = false;
  bool _refreshing = false;
  bool _checkingUpdates = false;
  bool _updateRecheckRequested = false;
  int _updateCheckGeneration = 0;
  String? _operationErrorText;
  VoidCallback? _operationRetry;
  Object? _queryError;
  Object? _updateError;
  List<GameUpdateCandidate> _updates = const [];
  List<GameUpdateSourceError> _updateSourceErrors = const [];
  DateTime? _lastUpdateCheckedAt;

  @override
  void initState() {
    super.initState();
    _replaceGames(widget.games);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstGame());
    unawaited(_checkUpdates());
  }

  @override
  void didUpdateWidget(GameLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    var shouldRecheckUpdates = false;
    if (oldWidget.games != widget.games && !_refreshing) {
      _replaceGames(widget.games);
      shouldRecheckUpdates = true;
    } else if (oldWidget.onQuery != widget.onQuery) {
      _applyQuery();
    }
    if (oldWidget.onCheckUpdates != widget.onCheckUpdates &&
        widget.onCheckUpdates != null) {
      shouldRecheckUpdates = true;
    }
    if (shouldRecheckUpdates) {
      unawaited(_checkUpdates());
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _previousPageFocusNode.dispose();
    _nextPageFocusNode.dispose();
    _scrollController.dispose();
    _gameFocusRestoration.dispose();
    for (final node in _gameFocusNodes.values) {
      node.dispose();
    }
    _gameFocusNodes.clear();
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _FocusSearchIntent(),
      },
      child: Actions(
        actions: {
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (_) {
              _searchFocusNode.requestFocus();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: Text(context.tr('library.title')),
              actions: [
                if (widget.onOpenOnline != null)
                  IconButton(
                    tooltip: context.tr('library.online'),
                    onPressed: widget.onOpenOnline,
                    icon: const Icon(Icons.cloud_download_outlined),
                  ),
                if (_updates.isNotEmpty)
                  IconButton(
                    tooltip: context.tr(
                      'library.view_updates_count',
                      arguments: {'count': _updates.length},
                    ),
                    onPressed: _showUpdates,
                    icon: Badge(
                      label: Text('${_updates.length}'),
                      child: const Icon(Icons.system_update_alt_rounded),
                    ),
                  ),
                if (widget.onImport != null)
                  IconButton(
                    tooltip: context.tr('library.import'),
                    onPressed: _refreshing ? null : _importPackage,
                    icon: const Icon(Icons.upload_file_outlined),
                  ),
                IconButton(
                  tooltip: context.tr('library.refresh'),
                  onPressed: _refreshing ? null : _refresh,
                  icon: _refreshing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: PlaymeshBackground(
              child: SafeArea(
                top: false,
                child: CustomScrollView(
                  controller: _scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(
                      child: ResponsivePage(
                        maxWidth: 1000,
                        bottom: 12,
                        child: _buildHeader(context),
                      ),
                    ),
                    ..._buildContentSlivers(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchField(
          controller: _searchController,
          focusNode: _searchFocusNode,
          onChanged: _scheduleQuery,
          onSubmitted: (_) => _runQueryNow(),
          onClear: _clearSearch,
        ),
        if (_searchController.text.trim().isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(
            context.tr(
              'library.match_count',
              arguments: {
                'visible': _visibleGames.length,
                'total': _totalMatches,
              },
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        if (_refreshing)
          _StatusNotice(
            icon: Icons.refresh_rounded,
            text: context.tr('library.loading'),
            progress: true,
          ),
        if (_refreshing &&
            (_checkingUpdates ||
                _updateError != null ||
                _updates.isNotEmpty ||
                _lastUpdateCheckedAt != null))
          const SizedBox(height: 12),
        if (_checkingUpdates)
          _StatusNotice(
            icon: Icons.sync_rounded,
            text: context.tr('library.checking_updates'),
            progress: true,
          )
        else if (_updateError != null)
          _StatusNotice(
            icon: Icons.cloud_off_outlined,
            text: context.tr('library.update_check_failed'),
            actionLabel: context.tr('common.retry'),
            onAction: _checkUpdates,
          )
        else ...[
          if (_updates.isNotEmpty)
            _UpdatesNotice(
              updates: _updates,
              onOpenUpdates: widget.onDownloadUpdate == null
                  ? widget.onOpenOnline
                  : _showUpdates,
            ),
          if (_updates.isNotEmpty && _updateSourceErrors.isNotEmpty)
            const SizedBox(height: 12),
          if (_updateSourceErrors.isNotEmpty)
            _StatusNotice(
              key: const ValueKey('library-update-check-partial'),
              icon: Icons.warning_amber_rounded,
              text: context.tr(
                'library.update_check_partial',
                arguments: {
                  'time': _formatUpdateCheckedAt(
                    context,
                    _lastUpdateCheckedAt!,
                  ),
                  'count': _updateSourceErrors.length,
                  'sources': _updateSourceErrors
                      .map((error) => error.localSourceName)
                      .join(' · '),
                },
              ),
              actionLabel: context.tr('common.details'),
              onAction: _showUpdateSourceErrors,
            ),
        ],
        if (_checkingUpdates ||
            _updateError != null ||
            _updates.isNotEmpty ||
            _updateSourceErrors.isNotEmpty)
          const SizedBox(height: 12),
        if (_operationErrorText != null)
          _StatusNotice(
            icon: Icons.error_outline_rounded,
            text: _operationErrorText!,
            actionLabel: context.tr('common.retry'),
            onAction: _refreshing ? null : _operationRetry,
          )
        else if (_queryError != null)
          _StatusNotice(
            icon: Icons.search_off_rounded,
            text: context.tr('library.search_failed'),
            actionLabel: context.tr('common.clear'),
            onAction: _clearSearch,
          ),
      ],
    );
  }

  List<Widget> _buildContentSlivers(BuildContext context) {
    if (_queryError != null) return const [];
    if (_games.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: ResponsivePage(
            maxWidth: 1000,
            top: 0,
            child: _EmptyState(
              icon: Icons.videogame_asset_off_outlined,
              title: context.tr('library.empty'),
              message: context.tr('library.empty_hint'),
              primaryLabel: widget.onImport == null
                  ? null
                  : context.tr('library.import'),
              onPrimary: widget.onImport == null ? null : _importPackage,
              secondaryLabel: widget.onOpenOnline == null
                  ? null
                  : context.tr('library.online'),
              onSecondary: widget.onOpenOnline,
            ),
          ),
        ),
      ];
    }
    if (_visibleGames.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: ResponsivePage(
            maxWidth: 1000,
            top: 0,
            child: _EmptyState(
              icon: Icons.search_off_rounded,
              title: context.tr('library.no_results'),
              message: context.tr(
                'library.no_results_hint',
                arguments: {'query': _searchController.text.trim()},
              ),
            ),
          ),
        ),
      ];
    }
    final updatesByGame = {
      for (final update in _updates) update.gameId: update,
    };
    final pageCount = _pageCount;
    return [
      SliverList(
        key: ValueKey('library-results-$_libraryRevision'),
        delegate: SliverChildBuilderDelegate((context, index) {
          final game = _visibleGames[index];
          return ResponsivePage(
            maxWidth: 1000,
            top: 0,
            bottom: index == _visibleGames.length - 1 && pageCount == 1
                ? 32
                : 10,
            child: EntranceAnimation(
              key: ValueKey('library-game-${game.id}'),
              delay: Duration(milliseconds: index.clamp(0, 4) * 35),
              child: _GameTile(
                game: game,
                update: updatesByGame[game.id],
                onDeleted: _removeDeletedGame,
                focusNode: _focusNodeForGame(game.id),
                autofocus: index == 0 && !_searchFocusNode.hasFocus,
              ),
            ),
          );
        }, childCount: _visibleGames.length),
      ),
      if (pageCount > 1)
        SliverToBoxAdapter(
          child: ResponsivePage(
            maxWidth: 1000,
            top: 2,
            bottom: 32,
            child: _PaginationBar(
              page: _pageIndex + 1,
              pageCount: pageCount,
              previousFocusNode: _previousPageFocusNode,
              nextFocusNode: _nextPageFocusNode,
              onPrevious: _pageIndex == 0
                  ? null
                  : () => _changePage(_pageIndex - 1),
              onNext: _pageIndex + 1 >= pageCount
                  ? null
                  : () => _changePage(_pageIndex + 1),
            ),
          ),
        ),
    ];
  }

  int get _pageCount =>
      _totalMatches == 0 ? 1 : (_totalMatches + _pageSize - 1) ~/ _pageSize;

  void _replaceGames(List<GameSummary> games) {
    final oldVisibleIds = _visibleGames.map((game) => game.id).toList();
    final focusedId = _gameFocusRestoration.lastFocusedId;
    final restoreGameFocus =
        focusedId != null && _gameFocusRestoration.hasFocus(focusedId);
    _games = games.toList(growable: true);
    final installedIds = _games.map((game) => game.id).toSet();
    _updates = _updates
        .where((update) => installedIds.contains(update.gameId))
        .toList(growable: false);
    _applyQuery(notify: false);
    _removeUnusedGameFocusNodes(installedIds);
    if (restoreGameFocus) {
      _restoreGameFocusAfterMutation(
        focusedId: focusedId,
        oldVisibleIds: oldVisibleIds,
      );
    }
  }

  FocusNode _focusNodeForGame(String gameId) {
    return _gameFocusNodes.putIfAbsent(gameId, () {
      final node = FocusNode(debugLabel: 'game-library:$gameId');
      _gameFocusRestoration.register(gameId, node);
      return node;
    });
  }

  void _removeUnusedGameFocusNodes(Set<String> installedIds) {
    final removedIds = _gameFocusNodes.keys
        .where((id) => !installedIds.contains(id))
        .toList(growable: false);
    for (final id in removedIds) {
      final node = _gameFocusNodes.remove(id)!;
      _gameFocusRestoration.unregister(id, node);
      node.dispose();
    }
  }

  void _restoreGameFocusAfterMutation({
    required String focusedId,
    required List<String> oldVisibleIds,
  }) {
    final oldIndex = oldVisibleIds.indexOf(focusedId);
    final visibleIds = _visibleGames.map((game) => game.id).toSet();
    final fallbackIds = <String>[];
    if (oldIndex >= 0) {
      for (var distance = 1; distance < oldVisibleIds.length; distance++) {
        final nextIndex = oldIndex + distance;
        if (nextIndex < oldVisibleIds.length &&
            visibleIds.contains(oldVisibleIds[nextIndex])) {
          fallbackIds.add(oldVisibleIds[nextIndex]);
        }
        final previousIndex = oldIndex - distance;
        if (previousIndex >= 0 &&
            visibleIds.contains(oldVisibleIds[previousIndex])) {
          fallbackIds.add(oldVisibleIds[previousIndex]);
        }
      }
    }
    fallbackIds.addAll(
      _visibleGames
          .map((game) => game.id)
          .where((id) => !fallbackIds.contains(id)),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _gameFocusRestoration.restore(
        preferredId: focusedId,
        fallbackIds: fallbackIds,
        fallback: _searchFocusNode,
      );
    });
  }

  void _applyQuery({bool notify = true, bool resetPage = false}) {
    try {
      final query = _searchController.text;
      if (resetPage) _pageIndex = 0;
      var requestedOffset = _pageIndex * _pageSize;
      var queried = widget.onQuery(
        query,
        offset: requestedOffset,
        limit: _pageSize,
      );
      if (queried.total > 0 &&
          queried.games.isEmpty &&
          requestedOffset >= queried.total) {
        _pageIndex = (queried.total - 1) ~/ _pageSize;
        requestedOffset = _pageIndex * _pageSize;
        queried = widget.onQuery(
          query,
          offset: requestedOffset,
          limit: _pageSize,
        );
      }
      if (queried.offset != requestedOffset ||
          queried.games.length > _pageSize ||
          queried.offset + queried.games.length > queried.total) {
        throw StateError(
          'GameLibraryPage requires a bounded revision-consistent page.',
        );
      }
      void update() {
        _visibleGames = queried.games.toList(growable: false);
        _totalMatches = queried.total;
        _pageIndex = queried.total == 0 ? 0 : queried.offset ~/ _pageSize;
        _libraryRevision = queried.revision;
        _queryError = null;
      }

      if (notify && mounted) {
        setState(update);
      } else {
        update();
      }
    } on Object catch (error) {
      void update() {
        _visibleGames = const [];
        _totalMatches = 0;
        _queryError = error;
      }

      if (notify && mounted) {
        setState(update);
      } else {
        update();
      }
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchActive = false;
    _applyQuery(resetPage: true);
    _searchFocusNode.requestFocus();
    _restoreFullListOffset();
  }

  void _restoreFullListOffset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(
        _fullListScrollOffset.clamp(
          0,
          _scrollController.position.maxScrollExtent,
        ),
      );
    });
  }

  void _scheduleQuery(String value) {
    final active = value.trim().isNotEmpty;
    if (!_searchActive && active && _scrollController.hasClients) {
      _fullListScrollOffset = _scrollController.offset;
    }
    final restore = _searchActive && !active;
    _searchActive = active;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      _searchDebounce = null;
      if (!mounted) return;
      _applyQuery(resetPage: true);
      if (restore) _restoreFullListOffset();
    });
  }

  void _runQueryNow() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _applyQuery(resetPage: true);
  }

  void _changePage(int pageIndex) {
    final target = pageIndex.clamp(0, _pageCount - 1);
    if (target == _pageIndex) return;
    _pageIndex = target;
    _applyQuery();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusFirstGame());
    });
  }

  void _focusFirstGame() {
    if (!mounted || _visibleGames.isEmpty) return;
    _gameFocusRestoration.restore(
      preferredId: _visibleGames.first.id,
      fallback: _searchFocusNode,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _operationErrorText = null;
      _operationRetry = null;
    });
    try {
      final games = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _replaceGames(games));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'library.found_count',
              arguments: {'count': games.length},
            ),
          ),
        ),
      );
      unawaited(_checkUpdates());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _operationErrorText = context.tr(
          'error.library_scan',
          arguments: {'error': error},
        );
        _operationRetry = _refresh;
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _importPackage() async {
    final importPackage = widget.onImport;
    if (importPackage == null) return;
    final source = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: context.tr('library.package_type'),
          extensions: const ['zip', 'playmesh'],
        ),
      ],
    );
    if (source == null || !mounted) return;
    setState(() {
      _refreshing = true;
      _operationErrorText = null;
      _operationRetry = null;
    });
    try {
      final game = await importPackage(source.path);
      if (!mounted) return;
      setState(() {
        _games.removeWhere((item) => item.id == game.id);
        _games.add(game);
        _games.sort(compareGameLibraryOrder);
        _applyQuery(notify: false);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'library.imported',
              arguments: {'name': game.name, 'version': game.version},
            ),
          ),
        ),
      );
      unawaited(_checkUpdates());
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _operationErrorText = context.tr(
            'library.import_failed',
            arguments: {'error': error},
          );
          _operationRetry = _importPackage;
        });
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _checkUpdates() async {
    final check = widget.onCheckUpdates;
    if (check == null || _games.isEmpty) {
      _updateCheckGeneration += 1;
      _updateRecheckRequested = false;
      if (mounted &&
          (_checkingUpdates ||
              _updateError != null ||
              _updates.isNotEmpty ||
              _updateSourceErrors.isNotEmpty ||
              _lastUpdateCheckedAt != null)) {
        setState(() {
          _checkingUpdates = false;
          _updateError = null;
          _updates = const [];
          _updateSourceErrors = const [];
          _lastUpdateCheckedAt = null;
        });
      }
      return;
    }
    if (_checkingUpdates) {
      _updateRecheckRequested = true;
      return;
    }
    final generation = ++_updateCheckGeneration;
    final installedGames = _games.map(_updateCheckInput).toSet();
    _updateRecheckRequested = false;
    setState(() {
      _checkingUpdates = true;
      _updateError = null;
    });
    try {
      final result = await check(List.unmodifiable(_games));
      if (!mounted ||
          generation != _updateCheckGeneration ||
          !_hasSameInstalledGames(installedGames)) {
        return;
      }
      setState(() {
        _updates = List.unmodifiable(result.candidates);
        _updateSourceErrors = List.unmodifiable(result.sourceErrors);
        _lastUpdateCheckedAt = result.checkedAt;
      });
    } on Object catch (error) {
      if (!mounted ||
          generation != _updateCheckGeneration ||
          !_hasSameInstalledGames(installedGames)) {
        return;
      }
      setState(() {
        _updates = const [];
        _updateSourceErrors = const [];
        _lastUpdateCheckedAt = null;
        _updateError = error;
      });
    } finally {
      if (mounted && generation == _updateCheckGeneration) {
        setState(() => _checkingUpdates = false);
        if (_updateRecheckRequested) {
          _updateRecheckRequested = false;
          unawaited(_checkUpdates());
        }
      }
    }
  }

  bool _hasSameInstalledGames(
    Set<({String id, String publisher, String version})> expected,
  ) =>
      expected.length == _games.length &&
      _games.every((game) => expected.contains(_updateCheckInput(game)));

  Future<void> _showUpdates() async {
    if (_updates.isEmpty) return;
    final offer = await showDialog<OnlineCatalogGame>(
      context: context,
      builder: (_) => _GameUpdatesDialog(updates: _updates),
    );
    if (offer == null || !mounted) return;
    final download = widget.onDownloadUpdate;
    if (download == null) {
      widget.onOpenOnline?.call();
      return;
    }
    await download(offer);
  }

  Future<void> _showUpdateSourceErrors() async {
    if (_updateSourceErrors.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('library-update-source-errors-dialog'),
        title: Text(context.tr('library.update_check_partial_title')),
        content: SizedBox(
          width: 560,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final error in _updateSourceErrors)
                ListTile(
                  key: ValueKey(
                    'library-update-source-error-${error.sourceId}',
                  ),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_off_outlined),
                  title: Text(error.localSourceName),
                  subtitle: SelectableText(error.message),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.tr('common.close')),
          ),
        ],
      ),
    );
  }

  void _removeDeletedGame(String gameId) {
    if (!mounted) return;
    final oldVisibleIds = _visibleGames.map((game) => game.id).toList();
    final focusedId = _gameFocusRestoration.lastFocusedId;
    final restoreGameFocus =
        focusedId != null && _gameFocusRestoration.hasFocus(focusedId);
    setState(() {
      _games.removeWhere((game) => game.id == gameId);
      _updates = _updates
          .where((update) => update.gameId != gameId)
          .toList(growable: false);
      _applyQuery(notify: false);
      _removeUnusedGameFocusNodes(_games.map((game) => game.id).toSet());
    });
    if (restoreGameFocus) {
      _restoreGameFocusAfterMutation(
        focusedId: focusedId,
        oldVisibleIds: oldVisibleIds,
      );
    }
    unawaited(_checkUpdates());
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textInputAction: TextInputAction.search,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: context.tr('common.search'),
            hintText: context.tr('library.search_scope_hint'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    tooltip: context.tr('library.search_clear'),
                    onPressed: onClear,
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
        child: Column(
          children: [
            GradientIcon(icon: icon, size: 60, iconSize: 29),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onPrimary != null || onSecondary != null) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  if (onPrimary case final onPrimary?)
                    FilledButton(
                      onPressed: onPrimary,
                      child: Text(primaryLabel!),
                    ),
                  if (onSecondary case final onSecondary?)
                    OutlinedButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaginationBar extends StatelessWidget {
  const _PaginationBar({
    required this.page,
    required this.pageCount,
    required this.previousFocusNode,
    required this.nextFocusNode,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int pageCount;
  final FocusNode previousFocusNode;
  final FocusNode nextFocusNode;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('game-library-previous-page'),
            focusNode: previousFocusNode,
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left_rounded),
            label: Text(context.tr('common.previous_page')),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              context.tr(
                'library.page_status',
                arguments: {'page': page, 'pages': pageCount},
              ),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('game-library-next-page'),
            focusNode: nextFocusNode,
            onPressed: onNext,
            iconAlignment: IconAlignment.end,
            icon: const Icon(Icons.chevron_right_rounded),
            label: Text(context.tr('common.next_page')),
          ),
        ],
      ),
    );
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({
    required this.game,
    required this.update,
    required this.onDeleted,
    required this.focusNode,
    required this.autofocus,
  });

  final GameSummary game;
  final GameUpdateCandidate? update;
  final ValueChanged<String> onDeleted;
  final FocusNode focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final details = _GameDetails(game: game, update: update);
    final detailButton = FilledButton.icon(
      key: ValueKey('game-tile-action-${game.id}'),
      focusNode: focusNode,
      autofocus: autofocus,
      onPressed: () => _openDetails(context),
      icon: const Icon(Icons.info_outline),
      label: Text(context.tr('library.open_details')),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [details, const SizedBox(height: 14), detailButton],
              );
            }
            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 18),
                detailButton,
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openDetails(BuildContext context) async {
    final deletedGameId = await Navigator.of(
      context,
    ).pushNamed<String>(GameDetailPage.routeName, arguments: game);
    if (deletedGameId != null) onDeleted(deletedGameId);
  }
}

class _GameDetails extends StatelessWidget {
  const _GameDetails({required this.game, required this.update});

  final GameSummary game;
  final GameUpdateCandidate? update;

  @override
  Widget build(BuildContext context) {
    final publisher = game.author.trim().isEmpty
        ? context.tr('library.publisher_unknown')
        : game.author;
    final description =
        game.description.trim().isNotEmpty || game.manifestError == null
        ? game.description
        : context.tr('game.repair_description');
    return LayoutBuilder(
      builder: (context, constraints) {
        final iconSize = constraints.maxWidth < 430 ? 84.0 : 104.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LocalGameIcon(game: game, size: iconSize),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          game.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (update != null) ...[
                        const SizedBox(width: 8),
                        _UpdateBadge(update: update!),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${context.tr('common.publisher')}：$publisher',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (description.trim().isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (game.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    GameTagList(tags: game.tags, compact: true),
                  ],
                  const SizedBox(height: 7),
                  Text(
                    gameLibraryMetadata(context, game),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (update case final update?) ...[
                    const SizedBox(height: 5),
                    Text(
                      _updateSummary(context, update),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UpdateBadge extends StatelessWidget {
  const _UpdateBadge({required this.update});

  final GameUpdateCandidate update;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: _updateSummary(context, update),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            context.tr('library.update_available'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdatesNotice extends StatelessWidget {
  const _UpdatesNotice({required this.updates, required this.onOpenUpdates});

  final List<GameUpdateCandidate> updates;
  final VoidCallback? onOpenUpdates;

  @override
  Widget build(BuildContext context) {
    final latest = updates.first;
    return _StatusNotice(
      icon: Icons.system_update_alt_rounded,
      text: context.tr(
        'library.updates_found',
        arguments: {
          'count': updates.length,
          'summary': _updateSummary(context, latest),
        },
      ),
      actionLabel: onOpenUpdates == null
          ? null
          : context.tr('library.view_updates'),
      onAction: onOpenUpdates,
    );
  }
}

class _GameUpdatesDialog extends StatelessWidget {
  const _GameUpdatesDialog({required this.updates});

  final List<GameUpdateCandidate> updates;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('library.updates_title')),
      content: SizedBox(
        width: 620,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final update in updates) ...[
              Text(
                key: ValueKey(
                  'library-update-${update.gameId}-${update.publisher}',
                ),
                update.gameId,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 3),
              Text(
                '${context.tr('common.publisher')}：'
                '${update.publisher} · '
                '${context.tr('library.current_version')} '
                'v${update.installedVersion}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 9),
              for (final version in update.versions) ...[
                Text(
                  key: ValueKey(
                    'library-update-version-${update.gameId}-'
                    '${version.targetVersion}',
                  ),
                  context.tr(
                    'library.target_version',
                    arguments: {'version': version.targetVersion},
                  ),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                for (final source in version.sources)
                  ListTile(
                    key: ValueKey(
                      'library-update-offer-${source.offer.downloadKey}',
                    ),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_download_outlined),
                    title: Text(source.localSourceName),
                    subtitle: Text(
                      '${source.host} · v${version.targetVersion}',
                    ),
                    trailing: FilledButton(
                      key: ValueKey(
                        'library-update-offer-action-'
                        '${source.offer.downloadKey}',
                      ),
                      onPressed: () => Navigator.pop(context, source.offer),
                      child: Text(context.tr('library.update_now')),
                    ),
                  ),
                const SizedBox(height: 5),
              ],
              const Divider(height: 24),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('common.close')),
        ),
      ],
    );
  }
}

class _StatusNotice extends StatelessWidget {
  const _StatusNotice({
    super.key,
    required this.icon,
    required this.text,
    this.progress = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final bool progress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              if (progress)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
              ),
              if (onAction != null && actionLabel != null) ...[
                const SizedBox(width: 8),
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalGameIcon extends StatelessWidget {
  const _LocalGameIcon({required this.game, required this.size});

  final GameSummary game;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = GradientIcon(
      icon: Icons.sports_esports_outlined,
      size: size,
      iconSize: size * 0.5,
    );
    final path = game.localIconPath;
    if (path == null || path.trim().isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image(
        image: ResizeImage.resizeIfNeeded(
          (size * MediaQuery.devicePixelRatioOf(context)).round(),
          null,
          GamePackageIconImageProvider(File(path)),
        ),
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

String gameLibraryMetadata(BuildContext context, GameSummary game) {
  final mode = game.supportsMultiplayer
      ? context.tr('library.multiplayer')
      : context.tr('library.solo');
  final displayMode = game.displayMode == 'single_screen_multiplayer'
      ? context.tr('library.single_screen_multiplayer')
      : context.tr('library.multi_screen_multiplayer');
  final orientation = game.orientation == GameOrientation.landscape
      ? context.tr('library.landscape')
      : context.tr('library.portrait');
  return 'v${game.version} · $mode · $displayMode · $orientation';
}

String _updateSummary(BuildContext context, GameUpdateCandidate update) {
  if (update.versions.isEmpty) {
    return context.tr('library.update_available');
  }
  final version = update.versions.first;
  final sourceNames = version.sources
      .map((source) => source.localSourceName.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .join(' / ');
  return context.tr(
    'library.update_summary',
    arguments: {
      'current': update.installedVersion,
      'target': version.targetVersion,
      'sources': sourceNames.isEmpty
          ? context.tr('library.source_unknown')
          : sourceNames,
    },
  );
}

String _formatUpdateCheckedAt(BuildContext context, DateTime checkedAt) {
  final local = checkedAt.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatCompactDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

({String id, String publisher, String version}) _updateCheckInput(
  GameSummary game,
) => (id: game.id, publisher: game.author.trim(), version: game.version);
