import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' hide XFile;

import '../../models/game_summary.dart';
import '../../core/platform/app_platform.dart';
import '../../core/storage/game_storage_service.dart';
import '../../ui/playmesh_ui.dart';
import '../game/game_page.dart';

typedef GameDelete = Future<void> Function(GameSummary game);
typedef GamePackageExport =
    Future<void> Function(GameSummary game, String destinationPath);

String gamePackageExportFileName(GameSummary game) {
  var safeName = game.name
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (safeName.isEmpty) safeName = 'game';
  if (safeName.runes.length > 50) {
    safeName = String.fromCharCodes(safeName.runes.take(50));
  }
  return '$safeName-v${game.version}.zip';
}

class GameDetailPage extends StatelessWidget {
  const GameDetailPage({
    super.key,
    required this.game,
    required this.onDelete,
    this.onExport,
  });

  static const routeName = '/game-details';

  final GameSummary game;
  final GameDelete onDelete;
  final GamePackageExport? onExport;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('游戏详情')),
      body: PlaymeshBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  EntranceAnimation(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _GameHeader(game: game),
                            const SizedBox(height: 24),
                            Text(
                              '游戏简介',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(game.description),
                            const SizedBox(height: 24),
                            _DetailRow(
                              icon: Icons.people_outline,
                              label: '游玩人数',
                              value: game.playerRangeLabel,
                            ),
                            _DetailRow(
                              icon: Icons.devices_outlined,
                              label: '显示模式',
                              value: game.displayModeLabel,
                            ),
                            _DetailRow(
                              icon: Icons.screen_rotation_outlined,
                              label: '屏幕方向',
                              value: game.orientation.label,
                            ),
                            _DetailRow(
                              icon: Icons.hub_outlined,
                              label: '游戏模式',
                              value: game.modeLabel,
                            ),
                            _DetailRow(
                              icon: Icons.web_asset_outlined,
                              label: '运行入口',
                              value: game.entry.statusLabel,
                            ),
                            const SizedBox(height: 12),
                            if (onExport != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => _exportGame(context),
                                  icon: const Icon(Icons.download_outlined),
                                  label: const Text('导出游戏包'),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => _clearGameData(context),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('清除游戏数据'),
                              ),
                            ),
                            const Divider(height: 32),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  foregroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                                onPressed: () => _deleteGame(context),
                                icon: const Icon(Icons.delete_forever_outlined),
                                label: const Text('删除游戏'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: FilledButton.icon(
          onPressed: () => Navigator.of(
            context,
          ).pushNamed(GamePage.routeName, arguments: game),
          icon: const Icon(Icons.play_arrow),
          label: const Text('开始游戏'),
        ),
      ),
    );
  }

  Future<void> _deleteGame(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除游戏'),
        content: Text(
          '将永久删除“${game.name}”的游戏文件、存档、缓存和本地历史。'
          '该操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await onDelete(game);
      if (context.mounted) Navigator.of(context).pop(game.id);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $error')));
      }
    }
  }

  Future<void> _exportGame(BuildContext context) async {
    final suggestedName = gamePackageExportFileName(game);
    if (Platform.isAndroid || isHarmonyOS) {
      try {
        final temporaryDirectory = await getTemporaryDirectory();
        final destination = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}$suggestedName',
        );
        await onExport!(game, destination.path);
        // The OHOS share_plus fork currently exposes this compatibility API.
        // ignore: deprecated_member_use
        await Share.shareXFiles(
          [XFile(destination.path, mimeType: 'application/zip')],
          subject: '导出 ${game.name}',
          text: 'Playmesh 游戏包：${game.name} ${game.version}',
          fileNameOverrides: [suggestedName],
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('游戏包已生成，请在系统面板中选择保存或分享位置')),
          );
        }
      } on Object catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
        }
      }
      return;
    }
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Playmesh 游戏包', extensions: ['zip']),
      ],
    );
    if (location == null || !context.mounted) return;
    try {
      await onExport!(game, location.path);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('游戏包已导出到 ${location.path}')));
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
      }
    }
  }

  Future<void> _clearGameData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除游戏数据'),
        content: const Text('这会删除该游戏通过 Playmesh SDK 保存的全部数据，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await GameStorageService.clearGameData(gameId: game.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('游戏数据已清除')));
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('清除失败: $error')));
      }
    }
  }
}

class _GameHeader extends StatelessWidget {
  const _GameHeader({required this.game});

  final GameSummary game;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GradientIcon(
          icon: Icons.sports_esports_outlined,
          size: 64,
          iconSize: 32,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                game.name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text('版本 ${game.version}'),
              const SizedBox(height: 2),
              Tooltip(
                message: '点击复制游戏 ID',
                child: TextButton.icon(
                  key: const ValueKey('copy-game-id'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 36),
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () async {
                    try {
                      await Clipboard.setData(ClipboardData(text: game.id));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('游戏 ID 已复制')),
                        );
                      }
                    } on Object catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('复制失败：$error')));
                      }
                    }
                  },
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: Text(
                    game.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(label),
      subtitle: MediaQuery.sizeOf(context).width < 420 ? Text(value) : null,
      trailing: MediaQuery.sizeOf(context).width < 420 ? null : Text(value),
    );
  }
}
