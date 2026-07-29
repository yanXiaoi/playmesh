import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/localization/playmesh_localization.dart';

/// Displays manifest tags as a semantic, theme-aware group.
///
/// Every tag remains in a single horizontal rail. Constrained list cards can
/// scroll the rail instead of hiding, wrapping, or summarizing manifest tags.
class GameTagList extends StatelessWidget {
  const GameTagList({
    super.key,
    required this.tags,
    this.showHeading = false,
    this.compact = false,
  });

  final Iterable<String> tags;
  final bool showHeading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final normalized = _normalizedTags(tags);
    if (normalized.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final rail = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.unknown,
        },
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (index, tag) in normalized.indexed) ...[
              if (index > 0) SizedBox(width: compact ? 5 : 7),
              _GameTagPill(tag: tag, compact: compact),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      container: true,
      label: '${context.tr('common.tags')}：${normalized.join(' · ')}',
      child: showHeading
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.sell_outlined, size: 17, color: colors.primary),
                const SizedBox(width: 7),
                Text(
                  context.tr('common.tags'),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: rail),
              ],
            )
          : rail,
    );
  }
}

class _GameTagPill extends StatelessWidget {
  const _GameTagPill({required this.tag, required this.compact});

  final String tag;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textStyle =
        (compact
                ? Theme.of(context).textTheme.labelSmall
                : Theme.of(context).textTheme.labelMedium)
            ?.copyWith(color: colors.onSecondaryContainer);
    return Tooltip(
      message: tag,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.secondaryContainer.withAlpha(166),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.secondary.withAlpha(72)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sell_outlined,
                size: compact ? 11 : 13,
                color: colors.secondary,
              ),
              SizedBox(width: compact ? 4 : 5),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 128 : 180),
                child: Text(
                  tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _normalizedTags(Iterable<String> tags) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final raw in tags) {
    final tag = raw.trim();
    if (tag.isEmpty || !seen.add(tag.toLowerCase())) continue;
    normalized.add(tag);
  }
  return normalized;
}
