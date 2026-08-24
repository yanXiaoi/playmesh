import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/game_summary.dart';
import '../../core/game_package/game_package_icon.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/storage/game_storage_service.dart';
import '../../ui/playmesh_ui.dart';
import '../game/game_page.dart';
import 'game_detail_widgets.dart';

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
                  GameDetailContentCard(
                    header: GameDetailHeader(
                      icon: _GameDetailIcon(game: game),
                      name: game.name,
                      version: game.version,
                      gameId: game.id,
                    ),
                    tags: game.tags,
                    description: description,
                    facts: _ManifestFacts(game: game),
                    trailing: [
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
    final facts = <GameDetailFactData>[
      GameDetailFactData(
        icon: Icons.person_outline,
        label: context.tr('common.publisher'),
        value: game.author.isEmpty
            ? context.tr('common.publisher_unknown')
            : game.author,
      ),
      GameDetailFactData(
        icon: Icons.schedule_outlined,
        label: context.tr('game.last_uploaded'),
        value: optionalTimestamp(game.lastModifiedAt),
        shrinkToFit: true,
      ),
      GameDetailFactData(
        icon: Icons.history_outlined,
        label: context.tr('game.last_opened'),
        value: optionalTimestamp(game.lastOpenedAt),
        shrinkToFit: true,
      ),
      GameDetailFactData(
        icon: Icons.bar_chart_rounded,
        label: context.tr('game.launch_count'),
        value: context.tr(
          'game.launch_count_value',
          arguments: {'count': game.launchCount},
        ),
      ),
      if (game.manifestError != null)
        GameDetailFactData(
          icon: Icons.warning_amber_rounded,
          label: context.tr('game.manifest_status'),
          value: context.tr('game.needs_repair'),
        ),
      GameDetailFactData(
        icon: Icons.sell_outlined,
        label: context.tr('common.version'),
        value: game.version,
      ),
      GameDetailFactData(
        icon: Icons.people_outline,
        label: context.tr('game.players'),
        value: playerRange,
      ),
      GameDetailFactData(
        icon: Icons.devices_outlined,
        label: context.tr('game.display_mode'),
        value: displayMode,
      ),
      GameDetailFactData(
        icon: Icons.screen_rotation_outlined,
        label: context.tr('game.main_screen'),
        value: orientationLabel(game.orientation),
      ),
      if (game.controllerOrientation case final controllerOrientation?)
        GameDetailFactData(
          icon: Icons.smartphone_outlined,
          label: context.tr('game.controller'),
          value: orientationLabel(controllerOrientation),
        ),
      GameDetailFactData(
        icon: Icons.hub_outlined,
        label: context.tr('game.game_mode'),
        value: game.supportsMultiplayer
            ? context.tr('library.multiplayer')
            : context.tr('library.solo'),
      ),
      if (game.appSdkVersion.isNotEmpty)
        GameDetailFactData(
          icon: Icons.integration_instructions_outlined,
          label: 'App SDK',
          value: game.appSdkVersion,
        ),
    ];
    return GameDetailFactGrid(facts: facts);
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
