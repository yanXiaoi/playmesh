import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/game_summary.dart';
import '../../core/game_package/game_package_icon.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/storage/game_storage_service.dart';
import '../../ui/game_tags.dart';
import '../../ui/playmesh_ui.dart';
import '../game/game_page.dart';

typedef GameDelete = Future<void> Function(GameSummary game);

class GameDetailPage extends StatelessWidget {
  const GameDetailPage({super.key, required this.game, required this.onDelete});

  static const routeName = '/game-details';

  final GameSummary game;
  final GameDelete onDelete;

  @override
  Widget build(BuildContext context) {
    final description =
        game.description.trim().isNotEmpty || game.manifestError == null
        ? game.description
        : context.tr('game.repair_description');
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('game.details'))),
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
                            if (game.tags.isNotEmpty) ...[
                              const SizedBox(height: 18),
                              GameTagList(tags: game.tags, showHeading: true),
                            ],
                            const SizedBox(height: 24),
                            Text(
                              context.tr('game.description'),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(description),
                            const SizedBox(height: 18),
                            _ManifestFacts(game: game),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => _clearGameData(context),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(context.tr('game.clear_data')),
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
                                label: Text(context.tr('game.delete')),
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
          key: const ValueKey('game-detail-start'),
          autofocus: true,
          onPressed: game.isRunnable
              ? () => Navigator.of(context).pushNamed(
                  GamePage.routeName,
                  arguments: GameLaunchArguments(
                    game: game,
                    enterFullscreenOnLaunch: true,
                  ),
                )
              : null,
          icon: Icon(game.isRunnable ? Icons.play_arrow : Icons.build_outlined),
          label: Text(
            game.isRunnable
                ? context.tr('game.start')
                : context.tr('game.fix_manifest'),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteGame(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('game.delete_forever')),
        content: Text(
          context.tr('game.delete_confirm', arguments: {'name': game.name}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('common.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('game.delete_forever')),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('game.delete_failed', arguments: {'error': error}),
            ),
          ),
        );
      }
    }
  }

  Future<void> _clearGameData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('game.clear_data')),
        content: Text(context.tr('game.clear_data_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('common.clear')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await GameStorageService.clearGameData(gameId: game.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('game.data_cleared'))),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('game.clear_failed', arguments: {'error': error}),
            ),
          ),
        );
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
        _GameDetailIcon(game: game),
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
              Text(
                context.tr(
                  'game.version_value',
                  arguments: {'version': game.version},
                ),
              ),
              const SizedBox(height: 2),
              Tooltip(
                message: context.tr('game.copy_id'),
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
                          SnackBar(content: Text(context.tr('game.id_copied'))),
                        );
                      }
                    } on Object catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.tr(
                                'common.copy_failed',
                                arguments: {'error': error},
                              ),
                            ),
                          ),
                        );
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

class _ManifestFacts extends StatelessWidget {
  const _ManifestFacts({required this.game});

  final GameSummary game;

  @override
  Widget build(BuildContext context) {
    String optionalTimestamp(DateTime? value) => value == null
        ? context.tr('common.none')
        : _formatLocalTimestamp(context, value);
    final playerRange = game.minPlayers == game.maxPlayers
        ? context.tr(
            'library.player_count',
            arguments: {'count': game.minPlayers},
          )
        : context.tr(
            'library.player_range',
            arguments: {'min': game.minPlayers, 'max': game.maxPlayers},
          );
    final displayMode = game.displayMode == 'single_screen_multiplayer'
        ? context.tr('game.display_single_screen')
        : context.tr('game.display_multi_screen');
    String orientationLabel(GameOrientation value) =>
        value == GameOrientation.landscape
        ? context.tr('library.landscape')
        : context.tr('library.portrait');
    final facts = <(IconData, String, String)>[
      (
        Icons.person_outline,
        context.tr('common.publisher'),
        game.author.isEmpty
            ? context.tr('common.publisher_unknown')
            : game.author,
      ),
      (
        Icons.schedule_outlined,
        context.tr('game.last_uploaded'),
        optionalTimestamp(game.lastModifiedAt),
      ),
      (
        Icons.history_outlined,
        context.tr('game.last_opened'),
        optionalTimestamp(game.lastOpenedAt),
      ),
      (
        Icons.bar_chart_rounded,
        context.tr('game.launch_count'),
        context.tr(
          'game.launch_count_value',
          arguments: {'count': game.launchCount},
        ),
      ),
      if (game.manifestError != null)
        (
          Icons.warning_amber_rounded,
          context.tr('game.manifest_status'),
          context.tr('game.needs_repair'),
        ),
      (Icons.sell_outlined, context.tr('common.version'), game.version),
      (Icons.people_outline, context.tr('game.players'), playerRange),
      (Icons.devices_outlined, context.tr('game.display_mode'), displayMode),
      (
        Icons.screen_rotation_outlined,
        context.tr('game.main_screen'),
        orientationLabel(game.orientation),
      ),
      if (game.controllerOrientation case final controllerOrientation?)
        (
          Icons.smartphone_outlined,
          context.tr('game.controller'),
          orientationLabel(controllerOrientation),
        ),
      (
        Icons.hub_outlined,
        context.tr('game.game_mode'),
        game.supportsMultiplayer
            ? context.tr('library.multiplayer')
            : context.tr('library.solo'),
      ),
      if (game.appSdkVersion.isNotEmpty)
        (
          Icons.integration_instructions_outlined,
          'App SDK',
          game.appSdkVersion,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 620 ? 3 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final fact in facts)
              SizedBox(
                width: width,
                child: _ManifestFact(
                  icon: fact.$1,
                  label: fact.$2,
                  value: fact.$3,
                  shrinkToFit:
                      fact.$1 == Icons.schedule_outlined ||
                      fact.$1 == Icons.history_outlined,
                ),
              ),
          ],
        );
      },
    );
  }

  String _formatLocalTimestamp(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  }
}

class _GameDetailIcon extends StatelessWidget {
  const _GameDetailIcon({required this.game});

  final GameSummary game;

  @override
  Widget build(BuildContext context) {
    const fallback = GradientIcon(
      icon: Icons.sports_esports_outlined,
      size: 64,
      iconSize: 32,
    );
    final path = game.localIconPath;
    if (path == null || path.trim().isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image(
        image: GamePackageIconImageProvider(File(path)),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

class _ManifestFact extends StatelessWidget {
  const _ManifestFact({
    required this.icon,
    required this.label,
    required this.value,
    this.shrinkToFit = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool shrinkToFit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withAlpha(143),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant.withAlpha(179)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 1),
                  if (shrinkToFit)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        maxLines: 1,
                        softWrap: false,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    Text(
                      value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
