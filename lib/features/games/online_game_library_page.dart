import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/catalog/game_catalog_models.dart';
import '../../core/catalog/online_game_catalog.dart';
import '../../core/game_package/game_library_local_metadata.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/version/semantic_version.dart';
import '../../ui/focus/playmesh_shortcuts.dart';
import '../../ui/game_tags.dart';
import '../../ui/playmesh_ui.dart';

class OnlineGameLibraryPage extends StatefulWidget {
  const OnlineGameLibraryPage({
    super.key,
    required this.controller,
    this.usage = const {},
  });

  static const routeName = '/games/online';

  final GameCatalogController controller;
  final Map<String, GameLibraryUsageStats> usage;

  @override
  State<OnlineGameLibraryPage> createState() => _OnlineGameLibraryPageState();
}

class _OnlineGameLibraryPageState extends State<OnlineGameLibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _nameController = TextEditingController();
  final _tagController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'online-catalog-search');
  final _searchFocusRestoration = PlaymeshFocusRestorationController();
  final Map<String, FocusNode> _searchResultFocusNodes = {};

  Map<String, Future<SourceSectionResult>> _homeRequests = const {};
  Map<String, SourceSectionResult> _searchSections = const {};
  List<AggregatedGameResult> _searchResults = const [];
  Map<String, String> _searchErrors = const {};
  Set<String> _searchLoadingSources = const {};
  Object? _initializationError;
  Object? _searchError;
  bool _initializing = true;
  bool _searching = false;
  bool _searchStarted = false;
  bool _addingSource = false;
  int _searchGeneration = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_tabChanged);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_tabChanged)
      ..dispose();
    _nameController.dispose();
    _tagController.dispose();
    _descriptionController.dispose();
    _searchFocusNode.dispose();
    _searchFocusRestoration.dispose();
    for (final node in _searchResultFocusNodes.values) {
      node.dispose();
    }
    _searchResultFocusNodes.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(OnlineGameLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_searchStarted ||
        oldWidget.usage == widget.usage ||
        _searchSections.isEmpty) {
      return;
    }
    final focusCapture = _captureSearchFocus();
    final results = aggregateCatalogOffers(
      _searchSections.values.expand((section) => section.offers),
      usage: widget.usage,
      sourceOrder: widget.controller.sources
          .map((source) => source.id)
          .toList(growable: false),
    );
    setState(() => _searchResults = results);
    _restoreSearchFocus(focusCapture);
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _FocusOnlineSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _FocusOnlineSearchIntent(),
      },
      child: Actions(
        actions: {
          _FocusOnlineSearchIntent: CallbackAction<_FocusOnlineSearchIntent>(
            onInvoke: (_) {
              _tabs.animateTo(1);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _searchFocusNode.requestFocus(),
              );
              return null;
            },
          ),
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('online.title')),
            actions: [
              IconButton(
                tooltip: context.tr('online.sources.scan'),
                onPressed: _addingSource ? null : _scanSource,
                icon: _addingSource
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.qr_code_scanner_rounded),
              ),
              IconButton(
                tooltip: context.tr('online.sources.manage'),
                onPressed: _openSources,
                icon: const Icon(Icons.hub_outlined),
              ),
              const SizedBox(width: 8),
            ],
            bottom: TabBar(
              controller: _tabs,
              tabs: [
                Tab(
                  icon: const Icon(Icons.home_outlined),
                  text: context.tr('online.tab.home'),
                ),
                Tab(
                  icon: const Icon(Icons.search),
                  text: context.tr('online.tab.search'),
                ),
              ],
            ),
          ),
          body: PlaymeshBackground(
            child: _initializing
                ? const Center(child: CircularProgressIndicator())
                : _initializationError != null
                ? _InitializationFailure(
                    error: _initializationError!,
                    onRetry: _initialize,
                  )
                : TabBarView(
                    controller: _tabs,
                    children: [_buildHome(), _buildSearch()],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildHome() {
    final sources = widget.controller.sources
        .where((source) => source.enabled && source.showOnHome)
        .toList(growable: false);
    if (sources.isEmpty) {
      return _CatalogEmptyState(
        icon: Icons.hub_outlined,
        title: context.tr('online.home.no_sources'),
        message: context.tr('online.home.no_sources_hint'),
        actionLabel: context.tr('online.sources.manage'),
        onAction: _openSources,
      );
    }
    return RefreshIndicator(
      onRefresh: () async => _resetHome(),
      child: ListView.builder(
        key: const PageStorageKey('online-catalog-home'),
        padding: const EdgeInsets.only(bottom: 32),
        itemCount: sources.length,
        itemBuilder: (context, index) {
          final source = sources[index];
          final request =
              _homeRequests[source.id] ??
              widget.controller.loadHomeSource(source.id);
          return ResponsivePage(
            maxWidth: 1080,
            top: index == 0 ? 18 : 4,
            bottom: 14,
            child: _SourceHomeSection(
              key: ValueKey('catalog-home-${source.id}'),
              source: source,
              autofocus: index == 0,
              request: request,
              loadIcon: widget.controller.loadOfferIcon,
              onRetry: () => _retryHomeSource(source.id),
              onLoadMore: () => _loadMoreHomeSource(source.id),
              onDownload: _downloadOffer,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearch() {
    return ListView(
      key: const PageStorageKey('online-catalog-search'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 34),
      children: [
        ResponsivePage(
          maxWidth: 1000,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CatalogSearchForm(
                nameController: _nameController,
                tagController: _tagController,
                descriptionController: _descriptionController,
                searchFocusNode: _searchFocusNode,
                loading: _searching,
                onSearch: () => unawaited(_search()),
              ),
              if (_searchErrors.isNotEmpty) ...[
                const SizedBox(height: 12),
                _CatalogStatusNotice(
                  icon: Icons.cloud_off_outlined,
                  text: context.tr(
                    'online.search.partial_failure',
                    arguments: {'count': _searchErrors.length},
                  ),
                ),
              ],
              if (_searchError != null) ...[
                const SizedBox(height: 12),
                _CatalogStatusNotice(
                  icon: Icons.error_outline,
                  text: context.tr(
                    'online.search.failed',
                    arguments: {'error': _searchError},
                  ),
                  actionLabel: context.tr('common.retry'),
                  onAction: _search,
                ),
              ],
              const SizedBox(height: 14),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (!_searchStarted)
                _CatalogEmptyState(
                  icon: Icons.travel_explore_outlined,
                  title: context.tr('online.search.ready'),
                  message: context.tr('online.search.ready_hint'),
                  actionLabel: context.tr('online.search.all'),
                  onAction: _search,
                )
              else if (widget.controller.sources
                  .where((source) => source.enabled)
                  .isEmpty)
                _CatalogEmptyState(
                  icon: Icons.hub_outlined,
                  title: context.tr('online.search.no_sources'),
                  message: context.tr('online.search.no_sources_hint'),
                  actionLabel: context.tr('online.sources.manage'),
                  onAction: _openSources,
                )
              else if (_searchResults.isEmpty)
                _CatalogEmptyState(
                  icon: Icons.search_off_outlined,
                  title: context.tr('online.search.empty'),
                  message: context.tr('online.search.empty_hint'),
                )
              else ...[
                _SearchResultHeader(
                  count: _searchResults.length,
                  sourceCount: _searchSections.length,
                ),
                const SizedBox(height: 9),
                for (final result in _searchResults) ...[
                  _AggregatedGameTile(
                    key: ValueKey('catalog-search-${result.groupKey}'),
                    result: result,
                    focusNode: _searchFocusNodeFor(
                      _searchResultId(result.groupKey),
                    ),
                    loadIcon: widget.controller.loadOfferIcon,
                    onOpen: () => _openVersionPicker(result),
                  ),
                  const SizedBox(height: 10),
                ],
                _SearchSourcePagination(
                  sections: _searchSections.values.toList(growable: false),
                  loadingSourceIds: _searchLoadingSources,
                  focusNodeForSource: (sourceId) =>
                      _searchFocusNodeFor(_searchLoadMoreId(sourceId)),
                  onLoadMore: (sourceId) =>
                      unawaited(_loadMoreSearchSource(sourceId)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        _initializing = true;
        _initializationError = null;
      });
    }
    try {
      await widget.controller.initialize();
      if (!mounted) return;
      _resetHome(notify: false);
    } on Object catch (error) {
      if (mounted) _initializationError = error;
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  void _resetHome({bool notify = true}) {
    final requests = {
      for (final source in widget.controller.sources)
        if (source.enabled && source.showOnHome)
          source.id: widget.controller.loadHomeSource(source.id),
    };
    if (notify && mounted) {
      setState(() => _homeRequests = requests);
    } else {
      _homeRequests = requests;
    }
  }

  void _retryHomeSource(String sourceId) {
    setState(() {
      _homeRequests = {
        ..._homeRequests,
        sourceId: widget.controller.loadHomeSource(sourceId),
      };
    });
  }

  void _loadMoreHomeSource(String sourceId) {
    final currentRequest = _homeRequests[sourceId];
    if (currentRequest == null) return;
    final request = currentRequest.then((current) async {
      if (current.error != null || !current.hasMore) return current;
      final next = await widget.controller.loadHomeSource(
        sourceId,
        page: current.page + 1,
        cursor: current.nextCursor,
      );
      if (next.error case final error?) {
        throw FormatException(error);
      }
      if (current.nextCursor != null && next.nextCursor == current.nextCursor) {
        throw const FormatException('游戏源重复返回 cursor，无法继续读取');
      }
      final offers = [...current.offers, ...next.offers]
        ..sort(compareOnlineCatalogOffersNewestFirst);
      return SourceSectionResult(
        source: current.source,
        offers: List.unmodifiable(offers),
        total: next.total,
        page: next.page,
        nextCursor: next.nextCursor,
        exhausted: next.offers.isEmpty && next.nextCursor == null,
      );
    });
    setState(() {
      _homeRequests = {..._homeRequests, sourceId: request};
    });
  }

  String _searchResultId(String groupKey) => 'result:$groupKey';

  String _searchLoadMoreId(String sourceId) => 'load-more:$sourceId';

  FocusNode _searchFocusNodeFor(String stableId) {
    return _searchResultFocusNodes.putIfAbsent(stableId, () {
      final node = FocusNode(debugLabel: 'online-search:$stableId');
      _searchFocusRestoration.register(stableId, node);
      return node;
    });
  }

  List<String> _searchFocusIds() => [
    for (final result in _searchResults) _searchResultId(result.groupKey),
    for (final section in _searchSections.values)
      if (section.hasMore) _searchLoadMoreId(section.source.id),
  ];

  ({String? focusedId, List<String> previousIds}) _captureSearchFocus() {
    final focusedId = _searchFocusRestoration.lastFocusedId;
    return (
      focusedId:
          focusedId != null && _searchFocusRestoration.hasFocus(focusedId)
          ? focusedId
          : null,
      previousIds: _searchFocusIds(),
    );
  }

  void _restoreSearchFocus(
    ({String? focusedId, List<String> previousIds}) capture,
  ) {
    final nextIds = _searchFocusIds();
    final activeIds = nextIds.toSet();
    final removedIds = _searchResultFocusNodes.keys
        .where((id) => !activeIds.contains(id))
        .toList(growable: false);
    for (final id in removedIds) {
      final node = _searchResultFocusNodes.remove(id)!;
      _searchFocusRestoration.unregister(id, node);
      node.dispose();
    }
    final focusedId = capture.focusedId;
    if (focusedId == null) return;
    final fallbackIds = _nearestFocusFallbackIds(
      focusedId: focusedId,
      previousIds: capture.previousIds,
      nextIds: nextIds,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusRestoration.restore(
        preferredId: focusedId,
        fallbackIds: fallbackIds,
        fallback: _searchFocusNode,
      );
    });
  }

  Future<void> _search() async {
    final focusCapture = _captureSearchFocus();
    final generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _searchError = null;
      _searchStarted = true;
      _searchLoadingSources = const {};
    });
    try {
      final raw = await widget.controller.search(
        name: _nameController.text,
        tag: _tagController.text,
        description: _descriptionController.text,
      );
      final aggregated = aggregateCatalogOffers(
        raw.games,
        usage: widget.usage,
        sourceOrder: widget.controller.sources
            .map((source) => source.id)
            .toList(growable: false),
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchResults = aggregated;
        _searchErrors = raw.errors;
        _searchSections = {
          for (final section in raw.sections) section.source.id: section,
        };
        _searchLoadingSources = const {};
      });
    } on Object catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchResults = const [];
        _searchErrors = const {};
        _searchSections = const {};
        _searchLoadingSources = const {};
        _searchError = error;
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
        _restoreSearchFocus(focusCapture);
      }
    }
  }

  Future<void> _loadMoreSearchSource(String sourceId) async {
    final current = _searchSections[sourceId];
    if (current == null ||
        !current.hasMore ||
        _searchLoadingSources.contains(sourceId)) {
      return;
    }
    final focusCapture = _captureSearchFocus();
    final generation = _searchGeneration;
    setState(() {
      _searchLoadingSources = {..._searchLoadingSources, sourceId};
      _searchErrors = Map.unmodifiable(
        Map<String, String>.from(_searchErrors)..remove(sourceId),
      );
    });
    try {
      final next = await widget.controller.searchSource(
        sourceId,
        page: current.page + 1,
        cursor: current.nextCursor,
        name: _nameController.text,
        tag: _tagController.text,
        description: _descriptionController.text,
      );
      if (next.error case final error?) {
        if (next.offers.isEmpty) throw FormatException(error);
      }
      final mergedOffers = List<OnlineCatalogGame>.from(current.offers);
      final indexesByGameId = <String, int>{
        for (var index = 0; index < mergedOffers.length; index += 1)
          mergedOffers[index].manifest.id: index,
      };
      final duplicateGameIds = <String>{};
      for (final offer in next.offers) {
        final id = offer.manifest.id;
        final existingIndex = indexesByGameId[id];
        if (existingIndex == null) {
          indexesByGameId[id] = mergedOffers.length;
          mergedOffers.add(offer);
          continue;
        }
        duplicateGameIds.add(id);
        final existing = mergedOffers[existingIndex];
        if (SemanticVersion.parse(
              offer.manifest.version,
            ).compareTo(SemanticVersion.parse(existing.manifest.version)) >
            0) {
          mergedOffers[existingIndex] = offer;
        }
      }
      mergedOffers.sort(compareOnlineCatalogOffersNewestFirst);
      final cursorStalled =
          current.nextCursor != null && current.nextCursor == next.nextCursor;
      final pageStalled =
          next.nextCursor == null &&
          (next.offers.isEmpty || mergedOffers.length == current.offers.length);
      final protocolMessages = <String>[
        ?next.error,
        if (duplicateGameIds.isNotEmpty)
          '游戏源在不同分页重复返回 gameId：'
              '${duplicateGameIds.join(', ')}；仅保留最高语义版本',
        if (cursorStalled) '游戏源重复返回 cursor，已停止继续读取',
      ];
      final protocolError = protocolMessages.isEmpty
          ? null
          : protocolMessages.join(' | ');
      final merged = SourceSectionResult(
        source: current.source,
        offers: List.unmodifiable(mergedOffers),
        total: next.total,
        page: next.page,
        nextCursor: cursorStalled ? null : next.nextCursor,
        error: protocolError,
        exhausted: cursorStalled || pageStalled || next.exhausted,
      );
      if (!mounted || generation != _searchGeneration) return;
      final sections = {..._searchSections, sourceId: merged};
      final results = aggregateCatalogOffers(
        sections.values.expand((section) => section.offers),
        usage: widget.usage,
        sourceOrder: widget.controller.sources
            .map((source) => source.id)
            .toList(growable: false),
      );
      setState(() {
        _searchSections = Map.unmodifiable(sections);
        _searchResults = results;
        if (protocolError != null) {
          _searchErrors = Map.unmodifiable({
            ..._searchErrors,
            sourceId: protocolError,
          });
        }
      });
    } on Object catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchErrors = Map.unmodifiable({
          ..._searchErrors,
          sourceId: error.toString(),
        });
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _searchLoadingSources = Set.unmodifiable(
            _searchLoadingSources.where((id) => id != sourceId),
          );
        });
        _restoreSearchFocus(focusCapture);
      }
    }
  }

  void _tabChanged() {
    if (_tabs.index == 1 && !_tabs.indexIsChanging && !_searchStarted) {
      unawaited(_search());
    }
  }

  Future<void> _downloadOffer(OnlineCatalogGame offer) async {
    final installed = widget.controller.installedGame(offer.manifest.id);
    if (installed != null &&
        installed.author.trim() != offer.publisher.trim()) {
      final localPublisher = installed.author.trim().isEmpty
          ? context.tr('common.publisher_unknown')
          : installed.author.trim();
      final onlinePublisher = offer.publisher.trim().isEmpty
          ? context.tr('common.publisher_unknown')
          : offer.publisher.trim();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const ValueKey('catalog-publisher-warning'),
          icon: Icon(
            Icons.warning_amber_rounded,
            color: Theme.of(dialogContext).colorScheme.error,
          ),
          title: Text(dialogContext.tr('online.download.publisher_warning')),
          content: Text(
            dialogContext.tr(
              'online.download.publisher_warning_message',
              arguments: {
                'name': offer.manifest.name,
                'localPublisher': localPublisher,
                'onlinePublisher': onlinePublisher,
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(dialogContext.tr('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                dialogContext.tr('online.download.publisher_warning_continue'),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await showGameDownloadProgressDialog(
      context,
      controller: widget.controller,
      offer: offer,
    );
  }

  Future<void> _openVersionPicker(AggregatedGameResult result) async {
    final offer = await showDialog<OnlineCatalogGame>(
      context: context,
      builder: (_) => _VersionPickerDialog(result: result),
    );
    if (offer != null && mounted) await _downloadOffer(offer);
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CatalogSourcesPage(controller: widget.controller),
      ),
    );
    if (!mounted) return;
    _resetHome();
    if (_searchStarted) unawaited(_search());
  }

  Future<void> _scanSource() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _CatalogSourceScannerPage()),
    );
    if (raw == null || !mounted) return;
    setState(() => _addingSource = true);
    try {
      final source = await widget.controller.verifyAndUpsertSource(raw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'online.sources.added',
              arguments: {'name': source.name},
            ),
          ),
        ),
      );
      _resetHome();
      if (_searchStarted) unawaited(_search());
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'online.sources.add_failed',
              arguments: {'error': error},
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _addingSource = false);
    }
  }
}

Future<GameDownloadStatus?> showGameDownloadProgressDialog(
  BuildContext context, {
  required GameCatalogController controller,
  required OnlineCatalogGame offer,
}) async {
  late final GameDownloadTask task;
  try {
    task = controller.startDownload(offer);
  } on StateError {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('online.download.busy'))));
    return null;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SingleDownloadDialog(controller: controller, task: task),
  );
  return task.status;
}

class _SourceHomeSection extends StatefulWidget {
  const _SourceHomeSection({
    super.key,
    required this.source,
    required this.autofocus,
    required this.request,
    required this.loadIcon,
    required this.onRetry,
    required this.onLoadMore,
    required this.onDownload,
  });

  final OnlineGameSource source;
  final bool autofocus;
  final Future<SourceSectionResult> request;
  final Future<List<int>?> Function(OnlineCatalogGame offer) loadIcon;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;
  final ValueChanged<OnlineCatalogGame> onDownload;

  @override
  State<_SourceHomeSection> createState() => _SourceHomeSectionState();
}

class _SourceHomeSectionState extends State<_SourceHomeSection> {
  final _focusRestoration = PlaymeshFocusRestorationController();
  final Map<String, FocusNode> _focusNodes = {};
  List<String> _focusIds = const [];
  String? _pendingFocusedId;
  List<String> _previousFocusIds = const [];

  OnlineGameSource get source => widget.source;
  Future<SourceSectionResult> get request => widget.request;
  Future<List<int>?> Function(OnlineCatalogGame offer) get loadIcon =>
      widget.loadIcon;
  VoidCallback get onRetry => widget.onRetry;
  VoidCallback get onLoadMore => widget.onLoadMore;
  ValueChanged<OnlineCatalogGame> get onDownload => widget.onDownload;

  @override
  void didUpdateWidget(_SourceHomeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.request, widget.request)) return;
    final focusedId = _focusRestoration.lastFocusedId;
    if (focusedId != null && _focusRestoration.hasFocus(focusedId)) {
      _pendingFocusedId = focusedId;
      _previousFocusIds = List.unmodifiable(_focusIds);
    }
  }

  @override
  void dispose() {
    _focusRestoration.dispose();
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    super.dispose();
  }

  String _offerFocusId(OnlineCatalogGame offer) => 'offer:${offer.downloadKey}';

  static const _loadMoreFocusId = 'load-more';

  FocusNode _focusNodeFor(String stableId) {
    return _focusNodes.putIfAbsent(stableId, () {
      final node = FocusNode(
        debugLabel: 'online-home:${widget.source.id}:$stableId',
      );
      _focusRestoration.register(stableId, node);
      return node;
    });
  }

  void _syncFocusIds(List<String> nextIds) {
    final previousIds = _focusIds;
    _focusIds = List.unmodifiable(nextIds);
    final focusedId = _pendingFocusedId;
    final capturedIds = _previousFocusIds.isEmpty
        ? previousIds
        : _previousFocusIds;
    _pendingFocusedId = null;
    _previousFocusIds = const [];
    final activeIds = nextIds.toSet();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final removedIds = _focusNodes.keys
          .where((id) => !activeIds.contains(id))
          .toList(growable: false);
      for (final id in removedIds) {
        final node = _focusNodes.remove(id)!;
        _focusRestoration.unregister(id, node);
        node.dispose();
      }
      if (focusedId == null) return;
      _focusRestoration.restore(
        preferredId: focusedId,
        fallbackIds: _nearestFocusFallbackIds(
          focusedId: focusedId,
          previousIds: capturedIds,
          nextIds: nextIds,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 24,
              color: Theme.of(context).colorScheme.secondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    source.host.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FutureBuilder<SourceSectionResult>(
          future: request,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _SectionLoading();
            }
            if (snapshot.hasError) {
              if (_focusIds.isNotEmpty || _pendingFocusedId != null) {
                _syncFocusIds(const []);
              }
              return _SectionFailure(
                message: snapshot.error.toString(),
                onRetry: onRetry,
              );
            }
            final section = snapshot.data!;
            if (section.error != null) {
              if (_focusIds.isNotEmpty || _pendingFocusedId != null) {
                _syncFocusIds(const []);
              }
              return _SectionFailure(message: section.error!, onRetry: onRetry);
            }
            if (section.offers.isEmpty) {
              if (_focusIds.isNotEmpty || _pendingFocusedId != null) {
                _syncFocusIds(const []);
              }
              return _SectionEmpty(
                text: context.tr('online.home.source_empty'),
              );
            }
            final focusIds = [
              for (final offer in section.offers) _offerFocusId(offer),
              if (section.hasMore) _loadMoreFocusId,
            ];
            if (!_sameStringList(_focusIds, focusIds) ||
                _pendingFocusedId != null) {
              _syncFocusIds(focusIds);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, offer) in section.offers.indexed) ...[
                  _OfferTile(
                    key: ValueKey('catalog-home-offer-${offer.downloadKey}'),
                    offer: offer,
                    autofocus: widget.autofocus && index == 0,
                    focusNode: _focusNodeFor(_offerFocusId(offer)),
                    loadIcon: loadIcon,
                    onDownload: () => onDownload(offer),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Text(
                        context.tr(
                          'online.home.source_progress',
                          arguments: {
                            'page': section.page,
                            'loaded': section.offers.length,
                            'total': section.total,
                          },
                        ),
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (section.hasMore) ...[
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        key: ValueKey('catalog-home-load-more-${source.id}'),
                        focusNode: _focusNodeFor(_loadMoreFocusId),
                        onPressed: onLoadMore,
                        icon: const Icon(Icons.expand_more),
                        label: Text(context.tr('common.load_more')),
                      ),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _OfferTile extends StatelessWidget {
  const _OfferTile({
    super.key,
    required this.offer,
    required this.autofocus,
    required this.focusNode,
    required this.loadIcon,
    required this.onDownload,
  });

  final OnlineCatalogGame offer;
  final bool autofocus;
  final FocusNode focusNode;
  final Future<List<int>?> Function(OnlineCatalogGame offer) loadIcon;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final manifest = offer.manifest;
    final publisher = offer.publisher.isEmpty
        ? context.tr('common.publisher_unknown')
        : offer.publisher;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _OnlineGameIcon(offer: offer, loadIcon: loadIcon, size: 54),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    manifest.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${context.tr('common.publisher')}：'
                    '$publisher · v${manifest.version}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (manifest.remarks.trim().isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      manifest.remarks,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (manifest.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    GameTagList(tags: manifest.tags, compact: true),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              key: ValueKey('catalog-home-offer-action-${offer.downloadKey}'),
              focusNode: focusNode,
              autofocus: autofocus,
              tooltip: context.tr(
                'online.download_from_source',
                arguments: {'source': offer.source.name},
              ),
              onPressed: onDownload,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _AggregatedGameTile extends StatelessWidget {
  const _AggregatedGameTile({
    super.key,
    required this.result,
    required this.focusNode,
    required this.loadIcon,
    required this.onOpen,
  });

  final AggregatedGameResult result;
  final FocusNode focusNode;
  final Future<List<int>?> Function(OnlineCatalogGame offer) loadIcon;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final offer = result.representative;
    final publisher = result.publisher.isEmpty
        ? context.tr('common.publisher_unknown')
        : result.publisher;
    return Card(
      child: InkWell(
        key: ValueKey('catalog-search-action-${result.groupKey}'),
        focusNode: focusNode,
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OnlineGameIcon(offer: offer, loadIcon: loadIcon, size: 58),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      offer.manifest.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${context.tr('common.publisher')}：'
                      '$publisher',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (offer.manifest.remarks.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        offer.manifest.remarks,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (offer.manifest.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      GameTagList(tags: offer.manifest.tags, compact: true),
                    ],
                    const SizedBox(height: 7),
                    Text(
                      context.tr(
                        'online.search.summary',
                        arguments: {
                          'versions': result.versions.length,
                          'sources': result.versions.fold<int>(
                            0,
                            (sum, version) => sum + version.offers.length,
                          ),
                          'heat': result.heat,
                        },
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnlineGameIcon extends StatefulWidget {
  const _OnlineGameIcon({
    required this.offer,
    required this.loadIcon,
    required this.size,
  });

  final OnlineCatalogGame offer;
  final Future<List<int>?> Function(OnlineCatalogGame offer) loadIcon;
  final double size;

  @override
  State<_OnlineGameIcon> createState() => _OnlineGameIconState();
}

class _OnlineGameIconState extends State<_OnlineGameIcon> {
  late Future<List<int>?> _request;

  @override
  void initState() {
    super.initState();
    _request = widget.loadIcon(widget.offer);
  }

  @override
  void didUpdateWidget(_OnlineGameIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.offer.downloadKey != widget.offer.downloadKey ||
        oldWidget.offer.icon != widget.offer.icon) {
      _request = widget.loadIcon(widget.offer);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = GradientIcon(
      icon: Icons.sports_esports_outlined,
      size: widget.size,
      iconSize: widget.size * 0.48,
    );
    if (widget.offer.icon == null) return fallback;
    return FutureBuilder<List<int>?>(
      future: _request,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            Uint8List.fromList(bytes),
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          ),
        );
      },
    );
  }
}

class _VersionPickerDialog extends StatelessWidget {
  const _VersionPickerDialog({required this.result});

  final AggregatedGameResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(result.representative.manifest.name),
      content: SizedBox(
        width: 560,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '${context.tr('common.publisher')}：'
              '${result.publisher.isEmpty ? context.tr('common.publisher_unknown') : result.publisher}',
            ),
            if (result.representative.manifest.tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              GameTagList(
                tags: result.representative.manifest.tags,
                showHeading: true,
              ),
            ],
            const SizedBox(height: 14),
            for (final version in result.versions) ...[
              Text(
                key: ValueKey(
                  'catalog-version-${result.groupKey}-${version.version}',
                ),
                'v${version.version}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              for (final offer in version.offers)
                ListTile(
                  key: ValueKey('catalog-version-offer-${offer.downloadKey}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: Text(offer.source.name),
                  subtitle: Text(offer.source.host.toString()),
                  trailing: FilledButton(
                    key: ValueKey(
                      'catalog-version-offer-action-${offer.downloadKey}',
                    ),
                    onPressed: () => Navigator.pop(context, offer),
                    child: Text(context.tr('common.download')),
                  ),
                ),
              const Divider(height: 22),
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

class _CatalogSearchForm extends StatelessWidget {
  const _CatalogSearchForm({
    required this.nameController,
    required this.tagController,
    required this.descriptionController,
    required this.searchFocusNode,
    required this.loading,
    required this.onSearch,
  });

  final TextEditingController nameController;
  final TextEditingController tagController;
  final TextEditingController descriptionController;
  final FocusNode searchFocusNode;
  final bool loading;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final fields = [
      TextField(
        controller: nameController,
        focusNode: searchFocusNode,
        decoration: InputDecoration(
          labelText: context.tr('online.search.name'),
          prefixIcon: const Icon(Icons.search),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSearch(),
      ),
      TextField(
        controller: tagController,
        decoration: InputDecoration(labelText: context.tr('online.search.tag')),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSearch(),
      ),
      TextField(
        controller: descriptionController,
        decoration: InputDecoration(
          labelText: context.tr('online.search.description'),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSearch(),
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 700) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final field in fields) ...[
                    field,
                    const SizedBox(height: 10),
                  ],
                  FilledButton.icon(
                    onPressed: loading ? null : onSearch,
                    icon: const Icon(Icons.search),
                    label: Text(context.tr('online.search.all_sources')),
                  ),
                ],
              );
            }
            return Row(
              children: [
                for (final field in fields) ...[
                  Expanded(child: field),
                  const SizedBox(width: 10),
                ],
                FilledButton.icon(
                  onPressed: loading ? null : onSearch,
                  icon: const Icon(Icons.search),
                  label: Text(context.tr('common.search')),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class CatalogSourcesPage extends StatefulWidget {
  const CatalogSourcesPage({super.key, required this.controller});

  final GameCatalogController controller;

  @override
  State<CatalogSourcesPage> createState() => _CatalogSourcesPageState();
}

class _CatalogSourcesPageState extends State<CatalogSourcesPage> {
  bool _importing = false;
  final _sourceFocusRestoration = PlaymeshFocusRestorationController();
  final Map<String, FocusNode> _sourceFocusNodes = {};
  late List<String> _sourceIds;

  @override
  void initState() {
    super.initState();
    _sourceIds = _currentSourceIds();
    widget.controller.addListener(_sourcesChanged);
  }

  @override
  void didUpdateWidget(CatalogSourcesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_sourcesChanged);
    _disposeSourceFocusNodes();
    _sourceIds = _currentSourceIds();
    widget.controller.addListener(_sourcesChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sourcesChanged);
    _disposeSourceFocusNodes();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('online.sources.title')),
        actions: [
          IconButton(
            tooltip: context.tr('online.sources.scan'),
            onPressed: _importing ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
          ),
          IconButton(
            tooltip: context.tr('online.sources.add'),
            onPressed: _importing ? null : _add,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PlaymeshBackground(
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final sources = widget.controller.sources;
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                ResponsivePage(
                  maxWidth: 900,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_importing)
                        const LinearProgressIndicator()
                      else if (sources.isEmpty)
                        _CatalogEmptyState(
                          icon: Icons.hub_outlined,
                          title: context.tr('online.sources.empty'),
                          message: context.tr('online.sources.empty_hint'),
                          actionLabel: context.tr('online.sources.add'),
                          onAction: _add,
                        )
                      else
                        for (final source in sources) ...[
                          _SourceListTile(
                            key: ValueKey('catalog-source-${source.id}'),
                            source: source,
                            focusNode: _focusNodeForSource(source.id),
                            onEnabled: (value) => unawaited(
                              widget.controller.setSourceEnabled(
                                source.id,
                                value,
                              ),
                            ),
                            onOpen: () => _openDetails(source),
                            onShare: () => _share(source),
                            onEdit: () => _edit(source),
                            onDelete: () => _delete(source),
                          ),
                          const SizedBox(height: 10),
                        ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<String> _currentSourceIds() => widget.controller.sources
      .map((source) => source.id)
      .toList(growable: false);

  FocusNode _focusNodeForSource(String sourceId) {
    return _sourceFocusNodes.putIfAbsent(sourceId, () {
      final node = FocusNode(debugLabel: 'catalog-source:$sourceId');
      _sourceFocusRestoration.register(sourceId, node);
      return node;
    });
  }

  void _sourcesChanged() {
    final previousIds = _sourceIds;
    final nextIds = _currentSourceIds();
    final focusedId = _sourceFocusRestoration.lastFocusedId;
    final restoreSourceFocus =
        focusedId != null && _sourceFocusRestoration.hasFocus(focusedId);
    _sourceIds = nextIds;

    final activeIds = nextIds.toSet();
    final removedIds = _sourceFocusNodes.keys
        .where((id) => !activeIds.contains(id))
        .toList(growable: false);
    for (final id in removedIds) {
      final node = _sourceFocusNodes.remove(id)!;
      _sourceFocusRestoration.unregister(id, node);
      node.dispose();
    }
    if (!restoreSourceFocus) return;

    final oldIndex = previousIds.indexOf(focusedId);
    final fallbackIds = <String>[];
    if (oldIndex >= 0) {
      for (var distance = 1; distance < previousIds.length; distance++) {
        final nextIndex = oldIndex + distance;
        if (nextIndex < previousIds.length &&
            activeIds.contains(previousIds[nextIndex])) {
          fallbackIds.add(previousIds[nextIndex]);
        }
        final previousIndex = oldIndex - distance;
        if (previousIndex >= 0 &&
            activeIds.contains(previousIds[previousIndex])) {
          fallbackIds.add(previousIds[previousIndex]);
        }
      }
    }
    fallbackIds.addAll(nextIds.where((id) => !fallbackIds.contains(id)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sourceFocusRestoration.restore(
        preferredId: focusedId,
        fallbackIds: fallbackIds,
      );
    });
  }

  void _disposeSourceFocusNodes() {
    _sourceFocusRestoration.dispose();
    for (final node in _sourceFocusNodes.values) {
      node.dispose();
    }
    _sourceFocusNodes.clear();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _CatalogSourceScannerPage()),
    );
    if (raw != null && mounted) await _importPublicUrl(raw);
  }

  Future<void> _add() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _PublicUrlDialog(),
    );
    if (raw != null && mounted) await _importPublicUrl(raw);
  }

  Future<void> _importPublicUrl(String raw) async {
    setState(() => _importing = true);
    try {
      final source = await widget.controller.verifyAndUpsertSource(raw);
      if (!mounted) return;
      _message(
        context.tr('online.sources.added', arguments: {'name': source.name}),
      );
    } on Object catch (error) {
      if (mounted) {
        _message(
          context.tr('online.sources.add_failed', arguments: {'error': error}),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _openDetails(OnlineGameSource source) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CatalogSourceDetailPage(
          controller: widget.controller,
          sourceId: source.id,
        ),
      ),
    );
  }

  Future<void> _edit(OnlineGameSource source) async {
    final updated = await showDialog<OnlineGameSource>(
      context: context,
      builder: (_) => _SourceEditDialog(source: source),
    );
    if (updated == null) return;
    try {
      await widget.controller.upsertSource(updated);
    } on Object catch (error) {
      if (mounted) {
        _message(
          context.tr('online.sources.save_failed', arguments: {'error': error}),
        );
      }
    }
  }

  Future<void> _delete(OnlineGameSource source) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('online.sources.delete')),
        content: Text(
          context.tr(
            'online.sources.delete_confirm',
            arguments: {'name': source.name},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('common.delete')),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.controller.removeSource(source.id);
    }
  }

  void _share(OnlineGameSource source) {
    final value = source.publicUrl.toString();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.tr(
            'online.sources.share_title',
            arguments: {'name': source.name},
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: value, size: 210),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(value),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: value)));
              _message(context.tr('online.sources.link_copied'));
            },
            icon: const Icon(Icons.copy),
            label: Text(context.tr('common.copy')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('common.close')),
          ),
        ],
      ),
    );
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SourceListTile extends StatelessWidget {
  const _SourceListTile({
    super.key,
    required this.source,
    required this.focusNode,
    required this.onEnabled,
    required this.onOpen,
    required this.onShare,
    required this.onEdit,
    required this.onDelete,
  });

  final OnlineGameSource source;
  final FocusNode focusNode;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final validation = source.lastError == null && source.declaration != null
        ? context.tr('online.sources.verified')
        : source.lastError != null
        ? context.tr('online.sources.invalid')
        : context.tr('online.sources.not_verified');
    final flags = [
      source.showOnHome
          ? context.tr('online.sources.on_home')
          : context.tr('online.sources.off_home'),
      source.uploadKey.trim().isNotEmpty
          ? context.tr('online.sources.upload_key_set')
          : context.tr('online.sources.upload_key_unset'),
      validation,
    ].join(' · ');
    return Card(
      child: ListTile(
        key: ValueKey('catalog-source-action-${source.id}'),
        focusNode: focusNode,
        onTap: onOpen,
        leading: Switch(value: source.enabled, onChanged: onEnabled),
        title: Text(source.name),
        subtitle: Text(
          '${source.host}\n$flags',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: context.tr('common.more'),
          onSelected: (value) {
            switch (value) {
              case 'share':
                onShare();
              case 'edit':
                onEdit();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'share',
              child: Text(context.tr('common.share')),
            ),
            PopupMenuItem(
              value: 'edit',
              child: Text(context.tr('common.edit')),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Text(context.tr('common.delete')),
            ),
          ],
        ),
      ),
    );
  }
}

class CatalogSourceDetailPage extends StatefulWidget {
  const CatalogSourceDetailPage({
    super.key,
    required this.controller,
    required this.sourceId,
  });

  final GameCatalogController controller;
  final String sourceId;

  @override
  State<CatalogSourceDetailPage> createState() =>
      _CatalogSourceDetailPageState();
}

class _CatalogSourceDetailPageState extends State<CatalogSourceDetailPage> {
  bool _refreshing = false;

  OnlineGameSource? get _source {
    for (final source in widget.controller.sources) {
      if (source.id == widget.sourceId) return source;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Paint the persisted declaration first, then refresh it without blocking
    // the first frame or replacing cached details with a loading screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _source != null) {
        unawaited(_refreshDeclaration(showFeedback: false));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final source = _source;
        return Scaffold(
          appBar: AppBar(
            title: Text(source?.name ?? context.tr('online.sources.details')),
            actions: [
              IconButton(
                tooltip: context.tr('online.sources.refresh_declaration'),
                onPressed: source == null || _refreshing
                    ? null
                    : () => _refreshDeclaration(),
                icon: _refreshing
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: context.tr('common.edit'),
                onPressed: source == null ? null : () => _edit(source),
                icon: const Icon(Icons.edit_outlined),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: PlaymeshBackground(
            child: source == null
                ? _CatalogEmptyState(
                    icon: Icons.link_off,
                    title: context.tr('online.sources.removed'),
                    message: '',
                  )
                : ListView(
                    children: [
                      ResponsivePage(
                        maxWidth: 820,
                        child: _SourceDetails(source: source),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Future<void> _refreshDeclaration({bool showFeedback = true}) async {
    setState(() => _refreshing = true);
    try {
      final result = await widget.controller.refreshSourceDeclaration(
        widget.sourceId,
      );
      if (!mounted || !showFeedback) return;
      final text = result.error == null
          ? context.tr('online.sources.refresh_success')
          : context.tr(
              'online.sources.refresh_failed',
              arguments: {'error': result.error},
            );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _edit(OnlineGameSource source) async {
    final updated = await showDialog<OnlineGameSource>(
      context: context,
      builder: (_) => _SourceEditDialog(source: source),
    );
    if (updated != null) await widget.controller.upsertSource(updated);
  }
}

class _SourceDetails extends StatelessWidget {
  const _SourceDetails({required this.source});

  final OnlineGameSource source;

  @override
  Widget build(BuildContext context) {
    final declaration = source.declaration;
    final upload = declaration?.userUpload;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DetailRow(
              label: context.tr('online.sources.local_name'),
              value: source.name,
            ),
            _DetailRow(label: 'Host', value: source.host.toString()),
            _DetailRow(
              label: context.tr('online.sources.official_name'),
              value: declaration?.name ?? '—',
            ),
            _DetailRow(
              label: context.tr('online.sources.builder'),
              value: declaration?.author ?? '—',
            ),
            _DetailRow(
              label: context.tr('online.sources.homepage'),
              value: declaration?.homepage?.toString() ?? '—',
            ),
            _DetailRow(
              label: context.tr('online.sources.catalog_version'),
              value: declaration?.catalogApiVersion ?? '—',
            ),
            _DetailRow(
              label: context.tr('online.sources.public_relay'),
              value: declaration?.supportsGameRelay == true
                  ? context.tr('common.supported')
                  : context.tr('common.not_supported'),
            ),
            _DetailRow(
              label: context.tr('online.sources.relay'),
              value: declaration?.relay == null
                  ? '—'
                  : '${declaration!.relay!.protocolVersion} · '
                        '${declaration.relay!.publicBaseUrl}',
            ),
            _DetailRow(
              label: context.tr('online.sources.user_upload'),
              value: upload?.supported == true
                  ? context.tr('common.supported')
                  : context.tr('common.not_supported'),
            ),
            _DetailRow(
              label: context.tr('online.sources.upload_contract'),
              value: upload?.supported == true
                  ? '${upload!.protocolVersion} · ${upload.path} · '
                        '${_formatBytes(upload.maxUploadBytes!)}'
                  : '—',
            ),
            _DetailRow(
              label: context.tr('online.sources.last_validated'),
              value: source.lastValidatedAt == null
                  ? '—'
                  : _formatLocalDateTime(context, source.lastValidatedAt!),
            ),
            _DetailRow(
              label: context.tr('online.sources.last_error'),
              value: source.lastError ?? '—',
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceEditDialog extends StatefulWidget {
  const _SourceEditDialog({required this.source});

  final OnlineGameSource source;

  @override
  State<_SourceEditDialog> createState() => _SourceEditDialogState();
}

class _SourceEditDialogState extends State<_SourceEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _token;
  late final TextEditingController _uploadKey;
  late bool _enabled;
  late bool _showOnHome;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.source.name);
    _token = TextEditingController(text: widget.source.token);
    _uploadKey = TextEditingController(text: widget.source.uploadKey);
    _enabled = widget.source.enabled;
    _showOnHome = widget.source.showOnHome;
  }

  @override
  void dispose() {
    _name.dispose();
    _token.dispose();
    _uploadKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('online.sources.edit')),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: context.tr('online.sources.local_name'),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                initialValue: widget.source.host.toString(),
                readOnly: true,
                decoration: InputDecoration(
                  labelText: context.tr('online.sources.host'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _token,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.tr('online.sources.read_token'),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _uploadKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: context.tr('online.sources.upload_key'),
                  helperText: context.tr('online.sources.upload_key_hint'),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
                title: Text(context.tr('online.sources.enabled')),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _showOnHome,
                onChanged: (value) => setState(() => _showOnHome = value),
                title: Text(context.tr('online.sources.show_on_home')),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('common.cancel')),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              widget.source.copyWith(
                name: name,
                token: _token.text.trim(),
                uploadKey: _uploadKey.text.trim(),
                enabled: _enabled,
                showOnHome: _showOnHome,
              ),
            );
          },
          child: Text(context.tr('common.save')),
        ),
      ],
    );
  }
}

class _PublicUrlDialog extends StatefulWidget {
  const _PublicUrlDialog();

  @override
  State<_PublicUrlDialog> createState() => _PublicUrlDialogState();
}

class _PublicUrlDialogState extends State<_PublicUrlDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.tr('online.sources.add')),
      content: SizedBox(
        width: 500,
        child: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: context.tr('online.sources.link'),
            hintText: 'http://192.168.1.20:16668?token=…',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('common.cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.tr('online.sources.verify_add')),
        ),
      ],
    );
  }

  void _submit() {
    final raw = _controller.text.trim();
    try {
      parseCatalogPublicUrl(raw);
      Navigator.pop(context, raw);
    } on Object {
      setState(() {
        _error = context.tr('online.sources.public_url_invalid');
      });
    }
  }
}

class _SingleDownloadDialog extends StatelessWidget {
  const _SingleDownloadDialog({required this.controller, required this.task});

  final GameCatalogController controller;
  final GameDownloadTask task;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.downloadChanges,
      builder: (context, _) {
        final active =
            task.status == GameDownloadStatus.queued ||
            task.status == GameDownloadStatus.downloading;
        return PopScope(
          canPop: !active,
          child: AlertDialog(
            key: const ValueKey('catalog-download-progress-dialog'),
            icon: Icon(_downloadIcon(task.status)),
            title: Text(context.tr('online.download.progress_title')),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    task.game.manifest.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${task.game.source.name} · v${task.game.manifest.version}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 18),
                  LinearProgressIndicator(
                    value: task.status == GameDownloadStatus.downloading
                        ? task.progress
                        : task.status == GameDownloadStatus.completed
                        ? 1
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _downloadLabel(context, task),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            actions: [
              if (active)
                TextButton.icon(
                  onPressed: task.cancelled
                      ? null
                      : () => controller.cancelDownload(task.id),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(
                    task.cancelled
                        ? context.tr('online.download.cancelling')
                        : context.tr('common.cancel'),
                  ),
                )
              else
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.tr('common.close')),
                ),
            ],
          ),
        );
      },
    );
  }

  static IconData _downloadIcon(GameDownloadStatus status) => switch (status) {
    GameDownloadStatus.queued => Icons.schedule,
    GameDownloadStatus.downloading => Icons.downloading,
    GameDownloadStatus.completed => Icons.check_circle_outline,
    GameDownloadStatus.stopped => Icons.stop_circle_outlined,
    GameDownloadStatus.failed => Icons.error_outline,
  };

  static String _downloadLabel(BuildContext context, GameDownloadTask task) =>
      switch (task.status) {
        GameDownloadStatus.queued => context.tr('online.downloads.waiting'),
        GameDownloadStatus.downloading =>
          task.progress == null
              ? context.tr('online.downloads.downloading')
              : context.tr(
                  'online.downloads.progress',
                  arguments: {'progress': (task.progress! * 100).round()},
                ),
        GameDownloadStatus.completed => context.tr(
          'online.downloads.installed',
        ),
        GameDownloadStatus.stopped => context.tr('online.downloads.stopped'),
        GameDownloadStatus.failed => context.tr(
          'online.downloads.failed',
          arguments: {'error': task.error},
        ),
      };
}

class _CatalogSourceScannerPage extends StatefulWidget {
  const _CatalogSourceScannerPage();

  @override
  State<_CatalogSourceScannerPage> createState() =>
      _CatalogSourceScannerPageState();
}

class _CatalogSourceScannerPageState extends State<_CatalogSourceScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('online.sources.scan'))),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: MobileScannerController(
              formats: const [BarcodeFormat.qrCode],
              detectionSpeed: DetectionSpeed.noDuplicates,
            ),
            onDetect: (capture) {
              if (_handled) return;
              for (final barcode in capture.barcodes) {
                final value = barcode.rawValue;
                if (value != null && value.isNotEmpty) {
                  try {
                    parseCatalogPublicUrl(value);
                  } on Object {
                    continue;
                  }
                  _handled = true;
                  Navigator.of(context).pop(value);
                  return;
                }
              }
            },
          ),
          Center(
            child: IgnorePointer(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultHeader extends StatelessWidget {
  const _SearchResultHeader({required this.count, required this.sourceCount});

  final int count;
  final int sourceCount;

  @override
  Widget build(BuildContext context) {
    return Text(
      context.tr(
        'online.search.result_count_independent',
        arguments: {'count': count, 'sources': sourceCount},
      ),
      style: Theme.of(context).textTheme.titleSmall,
    );
  }
}

class _SearchSourcePagination extends StatelessWidget {
  const _SearchSourcePagination({
    required this.sections,
    required this.loadingSourceIds,
    required this.focusNodeForSource,
    required this.onLoadMore,
  });

  final List<SourceSectionResult> sections;
  final Set<String> loadingSourceIds;
  final FocusNode Function(String sourceId) focusNodeForSource;
  final ValueChanged<String> onLoadMore;

  @override
  Widget build(BuildContext context) {
    final pending = sections
        .where((section) => section.hasMore)
        .toList(growable: false);
    if (pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final section in pending)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width < 468
                    ? MediaQuery.sizeOf(context).width - 48
                    : 420,
              ),
              child: OutlinedButton.icon(
                key: ValueKey('catalog-search-load-more-${section.source.id}'),
                focusNode: focusNodeForSource(section.source.id),
                onPressed: loadingSourceIds.contains(section.source.id)
                    ? null
                    : () => onLoadMore(section.source.id),
                icon: loadingSourceIds.contains(section.source.id)
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: Text(
                  context.tr(
                    'online.search.load_more_source',
                    arguments: {
                      'source': section.source.name,
                      'loaded': section.offers.length,
                      'total': section.total,
                    },
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InitializationFailure extends StatelessWidget {
  const _InitializationFailure({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return _CatalogEmptyState(
      icon: Icons.error_outline,
      title: context.tr('online.initialization_failed'),
      message: error.toString(),
      actionLabel: context.tr('common.retry'),
      onAction: () => unawaited(onRetry()),
    );
  }
}

class _CatalogEmptyState extends StatelessWidget {
  const _CatalogEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ResponsivePage(
        maxWidth: 720,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GradientIcon(icon: icon, size: 58, iconSize: 29),
                const SizedBox(height: 14),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  Text(message, textAlign: TextAlign.center),
                ],
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 18),
                  FilledButton(onPressed: onAction, child: Text(actionLabel!)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CatalogStatusNotice extends StatelessWidget {
  const _CatalogStatusNotice({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
              if (actionLabel != null && onAction != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 116,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _SectionFailure extends StatelessWidget {
  const _SectionFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _CatalogStatusNotice(
      icon: Icons.cloud_off_outlined,
      text: context.tr(
        'online.home.source_failed',
        arguments: {'error': message},
      ),
      actionLabel: context.tr('common.retry'),
      onAction: onRetry,
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _FocusOnlineSearchIntent extends Intent {
  const _FocusOnlineSearchIntent();
}

bool _sameStringList(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<String> _nearestFocusFallbackIds({
  required String focusedId,
  required List<String> previousIds,
  required List<String> nextIds,
}) {
  final activeIds = nextIds.toSet();
  final ordered = <String>[];
  final oldIndex = previousIds.indexOf(focusedId);
  if (oldIndex >= 0) {
    for (var distance = 1; distance < previousIds.length; distance += 1) {
      final nextIndex = oldIndex + distance;
      if (nextIndex < previousIds.length) {
        final id = previousIds[nextIndex];
        if (activeIds.contains(id) && !ordered.contains(id)) ordered.add(id);
      }
      final previousIndex = oldIndex - distance;
      if (previousIndex >= 0) {
        final id = previousIds[previousIndex];
        if (activeIds.contains(id) && !ordered.contains(id)) ordered.add(id);
      }
    }
  }
  ordered.addAll(nextIds.where((id) => !ordered.contains(id)));
  return ordered;
}

String _formatBytes(int value) {
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  return '$value B';
}

String _formatLocalDateTime(BuildContext context, DateTime value) {
  final local = value.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}
