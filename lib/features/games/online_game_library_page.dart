import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/catalog/game_catalog_models.dart';
import '../../core/catalog/online_game_catalog.dart';
import '../../ui/playmesh_ui.dart';

class OnlineGameLibraryPage extends StatefulWidget {
  const OnlineGameLibraryPage({super.key, required this.controller});

  static const routeName = '/games/online';

  final GameCatalogController controller;

  @override
  State<OnlineGameLibraryPage> createState() => _OnlineGameLibraryPageState();
}

class _OnlineGameLibraryPageState extends State<OnlineGameLibraryPage> {
  final _nameController = TextEditingController();
  final _tagController = TextEditingController();
  final _descriptionController = TextEditingController();
  final Set<String> _selected = {};
  List<OnlineCatalogGame> _games = const [];
  Map<String, String> _errors = const {};
  bool _loading = true;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _tagController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('在线游戏库'),
        actions: [
          IconButton(
            tooltip: '下载队列',
            onPressed: _showDownloads,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: '管理游戏源',
            onPressed: _openSources,
            icon: const Icon(Icons.hub_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PlaymeshBackground(
        child: ListView(
          children: [
            ResponsivePage(
              maxWidth: 980,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SearchCard(
                    nameController: _nameController,
                    tagController: _tagController,
                    descriptionController: _descriptionController,
                    loading: _loading,
                    onSearch: () {
                      _page = 1;
                      unawaited(_search());
                    },
                  ),
                  if (_errors.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text('${_errors.length} 个游戏源暂时不可用，已展示其他源的结果。'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _resultHeader(),
                  const SizedBox(height: 8),
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  else if (widget.controller.sources
                      .where((source) => source.enabled)
                      .isEmpty)
                    _emptyCard('尚未启用游戏源', '请先添加或启用至少一个在线游戏源。')
                  else if (_games.isEmpty)
                    _emptyCard('没有找到游戏', '请调整名称、标签或描述搜索条件。')
                  else
                    for (final game in _games) ...[
                      _OnlineGameCard(
                        game: game,
                        selected: _selected.contains(game.manifest.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _selected.add(game.manifest.id);
                          } else {
                            _selected.remove(game.manifest.id);
                          }
                        }),
                      ),
                      const SizedBox(height: 10),
                    ],
                  if (!_loading && _games.isNotEmpty) _pagination(),
                  const SizedBox(height: 92),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _enqueueSelected,
              icon: const Icon(Icons.download),
              label: Text('下载 ${_selected.length} 个游戏'),
            ),
    );
  }

  Widget _resultHeader() {
    final allSelected =
        _games.isNotEmpty &&
        _games.every((game) => _selected.contains(game.manifest.id));
    return Row(
      children: [
        Checkbox(
          value: allSelected,
          onChanged: _games.isEmpty
              ? null
              : (value) => setState(() {
                  if (value == true) {
                    _selected.addAll(_games.map((game) => game.manifest.id));
                  } else {
                    _selected.removeAll(_games.map((game) => game.manifest.id));
                  }
                }),
        ),
        Expanded(
          child: Text(
            '第 $_page 页 · ${_games.length} 个去重结果 · '
            '每个源最多 ${widget.controller.defaultPageSize} 个',
          ),
        ),
      ],
    );
  }

  Widget _pagination() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      OutlinedButton.icon(
        onPressed: _page <= 1 || _loading
            ? null
            : () {
                _page -= 1;
                unawaited(_search());
              },
        icon: const Icon(Icons.chevron_left),
        label: const Text('上一页'),
      ),
      const SizedBox(width: 12),
      OutlinedButton.icon(
        onPressed: _loading
            ? null
            : () {
                _page += 1;
                unawaited(_search());
              },
        icon: const Icon(Icons.chevron_right),
        label: const Text('下一页'),
      ),
    ],
  );

  Widget _emptyCard(String title, String message) => Card(
    child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        children: [
          const GradientIcon(icon: Icons.cloud_off_outlined),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );

  Future<void> _search() async {
    setState(() => _loading = true);
    try {
      final result = await widget.controller.search(
        page: _page,
        name: _nameController.text,
        tag: _tagController.text,
        description: _descriptionController.text,
      );
      if (!mounted) return;
      setState(() {
        _games = result.games;
        _errors = result.errors;
        _selected.removeWhere(
          (id) => !_games.any((game) => game.manifest.id == id),
        );
      });
    } on Object catch (error) {
      if (mounted) _message('在线游戏库加载失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _enqueueSelected() {
    widget.controller.downloads.enqueue(
      _games.where((game) => _selected.contains(game.manifest.id)),
    );
    setState(_selected.clear);
    _showDownloads();
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CatalogSourcesPage(controller: widget.controller),
      ),
    );
    if (mounted) unawaited(_search());
  }

  void _showDownloads() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DownloadQueueSheet(queue: widget.controller.downloads),
    );
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.nameController,
    required this.tagController,
    required this.descriptionController,
    required this.loading,
    required this.onSearch,
  });

  final TextEditingController nameController;
  final TextEditingController tagController;
  final TextEditingController descriptionController;
  final bool loading;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fields = [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: '名称',
                prefixIcon: Icon(Icons.search),
              ),
              onSubmitted: (_) => onSearch(),
            ),
            TextField(
              controller: tagController,
              decoration: const InputDecoration(labelText: '标签'),
              onSubmitted: (_) => onSearch(),
            ),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(labelText: '描述'),
              onSubmitted: (_) => onSearch(),
            ),
          ];
          if (constraints.maxWidth < 650) {
            return Column(
              children: [
                for (final field in fields) ...[
                  field,
                  const SizedBox(height: 10),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: loading ? null : onSearch,
                    icon: const Icon(Icons.search),
                    label: const Text('搜索所有启用源'),
                  ),
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
                label: const Text('搜索'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _OnlineGameCard extends StatelessWidget {
  const _OnlineGameCard({
    required this.game,
    required this.selected,
    required this.onSelected,
  });

  final OnlineCatalogGame game;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final manifest = game.manifest;
    return Card(
      child: CheckboxListTile(
        value: selected,
        onChanged: (value) => onSelected(value == true),
        secondary: const GradientIcon(icon: Icons.cloud_download_outlined),
        title: Text(
          manifest.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${manifest.remarks}\n'
            'v${manifest.version} · ${manifest.players.min}-${manifest.players.max} 人 · '
            '${game.source.name}${manifest.tags.isEmpty ? '' : ' · ${manifest.tags.join(' / ')}'}',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        isThreeLine: true,
        controlAffinity: ListTileControlAffinity.trailing,
      ),
    );
  }
}

class CatalogSourcesPage extends StatelessWidget {
  const CatalogSourcesPage({super.key, required this.controller});

  final GameCatalogController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('在线游戏源'),
      actions: [
        IconButton(
          tooltip: '扫码添加游戏源',
          onPressed: () => _scan(context),
          icon: const Icon(Icons.qr_code_scanner),
        ),
        IconButton(
          tooltip: '手动添加游戏源',
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: PlaymeshBackground(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ListView(
          children: [
            ResponsivePage(
              maxWidth: 820,
              child: Column(
                children: [
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.filter_list),
                      title: const Text('每个源默认获取数量'),
                      subtitle: const Text('多个源会并发请求，再按游戏 ID 去重。'),
                      trailing: DropdownButton<int>(
                        value: controller.defaultPageSize,
                        items: const [5, 10, 20, 50]
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text('$value'),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(controller.setDefaultPageSize(value));
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (controller.sources.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: Text('还没有在线游戏源，可扫码或手动添加。'),
                      ),
                    )
                  else
                    for (final source in controller.sources) ...[
                      Card(
                        child: ListTile(
                          leading: Switch(
                            value: source.enabled,
                            onChanged: (value) => unawaited(
                              controller.setSourceEnabled(source.id, value),
                            ),
                          ),
                          title: Text(source.name),
                          subtitle: SelectableText(source.host.toString()),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              switch (value) {
                                case 'share':
                                  _share(context, source);
                                case 'edit':
                                  _edit(context, source);
                                case 'delete':
                                  unawaited(controller.removeSource(source.id));
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'share', child: Text('分享')),
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _scan(BuildContext context) async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _CatalogSourceScannerPage()),
    );
    if (raw == null || !context.mounted) return;
    try {
      await controller.upsertSource(OnlineGameSource.fromConfigurationUri(raw));
    } on Object catch (error) {
      if (context.mounted) _message(context, '添加游戏源失败：$error');
    }
  }

  Future<void> _edit(BuildContext context, [OnlineGameSource? source]) async {
    final name = TextEditingController(text: source?.name ?? '局域网游戏源');
    final host = TextEditingController(text: source?.host.toString() ?? '');
    final token = TextEditingController(text: source?.token ?? '');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source == null ? '添加游戏源' : '编辑游戏源'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: host,
                decoration: const InputDecoration(
                  labelText: 'Host',
                  hintText: 'http://192.168.1.20:16668',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: token,
                decoration: const InputDecoration(labelText: 'Token（可留空）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (accepted != true) {
      name.dispose();
      host.dispose();
      token.dispose();
      return;
    }
    try {
      await controller.upsertSource(
        OnlineGameSource(
          id: source?.id ?? 'source-${DateTime.now().microsecondsSinceEpoch}',
          name: name.text.trim().isEmpty ? '在线游戏源' : name.text.trim(),
          host: normalizeCatalogHost(host.text),
          token: token.text.trim(),
          enabled: source?.enabled ?? true,
        ),
      );
    } on Object catch (error) {
      if (context.mounted) _message(context, '保存游戏源失败：$error');
    } finally {
      name.dispose();
      host.dispose();
      token.dispose();
    }
  }

  void _share(BuildContext context, OnlineGameSource source) {
    final value = source.configurationUri.toString();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('分享 ${source.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(10),
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
              _message(context, '游戏源配置已复制');
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _message(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DownloadQueueSheet extends StatelessWidget {
  const _DownloadQueueSheet({required this.queue});

  final GameDownloadQueue queue;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: AnimatedBuilder(
        animation: queue,
        builder: (context, _) => Column(
          children: [
            Text(
              '下载队列',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Divider(),
            Expanded(
              child: queue.tasks.isEmpty
                  ? const Center(child: Text('下载队列为空'))
                  : ListView(
                      children: [
                        for (final task in queue.tasks)
                          ListTile(
                            leading: _downloadIcon(task.status),
                            title: Text(task.game.manifest.name),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_downloadLabel(task)),
                                if (task.status ==
                                    GameDownloadStatus.downloading)
                                  LinearProgressIndicator(value: task.progress),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (task.status == GameDownloadStatus.queued ||
                                    task.status ==
                                        GameDownloadStatus.downloading)
                                  IconButton(
                                    tooltip: '停止下载',
                                    onPressed: () => queue.stop(task.id),
                                    icon: const Icon(
                                      Icons.stop_circle_outlined,
                                    ),
                                  ),
                                IconButton(
                                  tooltip: '删除任务',
                                  onPressed: () => queue.delete(task.id),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    ),
  );

  static Widget _downloadIcon(GameDownloadStatus status) =>
      Icon(switch (status) {
        GameDownloadStatus.queued => Icons.schedule,
        GameDownloadStatus.downloading => Icons.downloading,
        GameDownloadStatus.completed => Icons.check_circle_outline,
        GameDownloadStatus.stopped => Icons.stop_circle_outlined,
        GameDownloadStatus.failed => Icons.error_outline,
      });

  static String _downloadLabel(GameDownloadTask task) => switch (task.status) {
    GameDownloadStatus.queued => '等待下载',
    GameDownloadStatus.downloading =>
      task.progress == null
          ? '正在下载'
          : '正在下载 ${(task.progress! * 100).round()}%',
    GameDownloadStatus.completed => '已安装',
    GameDownloadStatus.stopped => '已停止',
    GameDownloadStatus.failed => '失败：${task.error}',
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('扫描游戏源'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
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
                _handled = true;
                Navigator.of(context).pop(value);
                return;
              }
            }
          },
        ),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
      ],
    ),
  );
}
