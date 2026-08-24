import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/playmesh_localization.dart';
import '../../ui/game_tags.dart';
import '../../ui/playmesh_ui.dart';

class GameDetailContentCard extends StatelessWidget {
  const GameDetailContentCard({
    super.key,
    required this.header,
    required this.tags,
    required this.description,
    required this.facts,
    this.trailing = const [],
  });

  final Widget header;
  final List<String> tags;
  final String description;
  final Widget facts;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return EntranceAnimation(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 18),
                GameTagList(tags: tags, showHeading: true),
              ],
              const SizedBox(height: 24),
              Text(
                context.tr('game.description'),
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(description),
              const SizedBox(height: 18),
              facts,
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class GameDetailHeader extends StatelessWidget {
  const GameDetailHeader({
    super.key,
    required this.icon,
    required this.name,
    required this.version,
    required this.gameId,
  });

  final Widget icon;
  final String name;
  final String version;
  final String gameId;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        icon,
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.tr(
                  'game.version_value',
                  arguments: {'version': version},
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
                  onPressed: () => _copyGameId(context),
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: Text(
                    gameId,
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

  Future<void> _copyGameId(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: gameId));
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('game.id_copied'))));
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('common.copy_failed', arguments: {'error': error}),
            ),
          ),
        );
      }
    }
  }
}

class GameDetailFactData {
  const GameDetailFactData({
    required this.icon,
    required this.label,
    required this.value,
    this.shrinkToFit = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool shrinkToFit;
}

class GameDetailFactGrid extends StatelessWidget {
  const GameDetailFactGrid({super.key, required this.facts});

  final List<GameDetailFactData> facts;

  @override
  Widget build(BuildContext context) {
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
                child: _GameDetailFact(
                  icon: fact.icon,
                  label: fact.label,
                  value: fact.value,
                  shrinkToFit: fact.shrinkToFit,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GameDetailFact extends StatelessWidget {
  const _GameDetailFact({
    required this.icon,
    required this.label,
    required this.value,
    required this.shrinkToFit,
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
