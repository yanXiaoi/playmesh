import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../models/game_summary.dart';
import '../../core/game_package/game_library_repository.dart';
import '../../ui/playmesh_ui.dart';
import 'game_detail_page.dart';

typedef GameLibraryRefresh = Future<List<GameSummary>> Function();
typedef GamePackageImport = Future<GameSummary> Function(String path);

class GameLibraryPage extends StatefulWidget {
  const GameLibraryPage({
    super.key,
    required this.games,
    required this.onRefresh,
    this.onImport,
    this.onOpenOnline,
  });

  static const routeName = '/games';

  final List<GameSummary> games;
  final GameLibraryRefresh onRefresh;
  final GamePackageImport? onImport;
  final VoidCallback? onOpenOnline;

  @override
  State<GameLibraryPage> createState() => _GameLibraryPageState();
}

class _GameLibraryPageState extends State<GameLibraryPage> {
  late List<GameSummary> _games = widget.games.toList();
  bool _refreshing = false;

  @override
  void didUpdateWidget(GameLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.games != widget.games && !_refreshing) {
      _games = widget.games.toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('游戏库'),
        actions: [
          if (widget.onOpenOnline != null)
            IconButton(
              tooltip: '在线游戏库',
              onPressed: widget.onOpenOnline,
              icon: const Icon(Icons.cloud_download_outlined),
            ),
          if (widget.onImport != null)
            IconButton(
              tooltip: '导入 Playmesh 游戏包',
              onPressed: _refreshing ? null : _importPackage,
              icon: const Icon(Icons.upload_file_outlined),
            ),
          IconButton(
            tooltip: '重新扫描游戏库',
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
        child: _games.isEmpty
            ? Center(
                child: ResponsivePage(
                  maxWidth: 560,
                  child: EntranceAnimation(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const GradientIcon(
                              icon: Icons.videogame_asset_off_outlined,
                              size: 64,
                              iconSize: 31,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '游戏库为空',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 7),
                            const Text(
                              '导入根目录包含 main.json 的 Playmesh 游戏包即可开始。',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : ListView(
                children: [
                  ResponsivePage(
                    maxWidth: 940,
                    child: Column(
                      children: [
                        for (var index = 0; index < _games.length; index++) ...[
                          EntranceAnimation(
                            delay: Duration(
                              milliseconds: (index.clamp(0, 5)) * 55,
                            ),
                            child: _GameTile(
                              game: _games[index],
                              onDeleted: _removeDeletedGame,
                            ),
                          ),
                          if (index < _games.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final games = await widget.onRefresh();
      if (!mounted) return;
      setState(() => _games = games.toList());
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已发现 ${games.length} 个游戏。')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('游戏库扫描失败：$error')));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _importPackage() async {
    final source = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Playmesh 游戏包', extensions: ['zip', 'playmesh']),
      ],
    );
    if (source == null || !mounted) return;
    setState(() => _refreshing = true);
    try {
      final game = await widget.onImport!(source.path);
      if (!mounted) return;
      setState(() {
        _games.removeWhere((item) => item.id == game.id);
        _games.add(game);
        _games.sort(compareGameLibraryOrder);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${game.name} ${game.version}。')),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('游戏包导入失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _removeDeletedGame(String gameId) {
    if (!mounted) return;
    setState(() => _games.removeWhere((game) => game.id == gameId));
  }
}

class _GameTile extends StatelessWidget {
  const _GameTile({required this.game, required this.onDeleted});

  final GameSummary game;
  final ValueChanged<String> onDeleted;

  @override
  Widget build(BuildContext context) {
    final details = _GameDetails(game: game);
    final detailButton = FilledButton.icon(
      onPressed: () => _openDetails(context),
      icon: const Icon(Icons.info_outline),
      label: const Text('查看详情'),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [details, const SizedBox(height: 16), detailButton],
              );
            }

            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: 20),
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
  const _GameDetails({required this.game});

  final GameSummary game;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GradientIcon(icon: Icons.sports_esports_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                game.name,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                game.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                'v${game.version} · ${game.playerRangeLabel} · '
                '${game.modeLabel} · ${game.orientation.label}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
