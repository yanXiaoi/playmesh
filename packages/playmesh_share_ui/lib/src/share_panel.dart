import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'share_panel_models.dart';

typedef PlaymeshShareLinkAction =
    FutureOr<void> Function(PlaymeshShareLink link);

typedef PlaymeshShareVoidAction = FutureOr<void> Function();

typedef PlaymeshShareIdAction = FutureOr<void> Function(String id);

class PlaymeshSharePanel extends StatefulWidget {
  const PlaymeshSharePanel({
    super.key,
    required this.model,
    required this.strings,
    required this.actionMode,
    required this.onClose,
    required this.onLinkAction,
    this.onSelectLanLink,
    this.onInternetOpened,
    this.onServerSelected,
    this.onServerRefresh,
    this.onServerDisconnected,
    this.maxWidth = 720,
    this.maxHeight = 680,
  });

  final PlaymeshSharePanelModel model;
  final PlaymeshSharePanelStrings strings;
  final PlaymeshShareActionMode actionMode;
  final PlaymeshShareVoidAction onClose;
  final PlaymeshShareLinkAction onLinkAction;
  final PlaymeshShareIdAction? onSelectLanLink;
  final PlaymeshShareVoidAction? onInternetOpened;
  final PlaymeshShareIdAction? onServerSelected;
  final PlaymeshShareVoidAction? onServerRefresh;
  final PlaymeshShareVoidAction? onServerDisconnected;
  final double maxWidth;
  final double maxHeight;

  @override
  PlaymeshSharePanelState createState() => PlaymeshSharePanelState();
}

class PlaymeshSharePanelState extends State<PlaymeshSharePanel> {
  final FocusNode _closeFocusNode = FocusNode(
    debugLabel: 'playmesh-share-close',
  );
  final TextEditingController _searchController = TextEditingController();
  late PlaymeshShareSection _section;

  void requestCloseFocus() {
    if (_closeFocusNode.canRequestFocus) {
      _closeFocusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    _section = widget.model.initialSection;
    if (_section == PlaymeshShareSection.internet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _run(widget.onInternetOpened);
        }
      });
    }
  }

  @override
  void dispose() {
    _closeFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _run(widget.onClose),
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.maxWidth,
          maxHeight: widget.maxHeight,
        ),
        child: Material(
          color: colors.surface,
          surfaceTintColor: colors.surfaceTint,
          elevation: 12,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              _buildHeader(context),
              const Divider(height: 1),
              _buildTabs(context),
              const Divider(height: 1),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: KeyedSubtree(
                    key: ValueKey<PlaymeshShareSection>(_section),
                    child: switch (_section) {
                      PlaymeshShareSection.lan => _buildLan(context),
                      PlaymeshShareSection.internet => _buildInternet(context),
                      PlaymeshShareSection.room => _buildRoom(context),
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              widget.model.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            key: const Key('game-share-close'),
            focusNode: _closeFocusNode,
            autofocus: true,
            tooltip: widget.strings.closeTooltip,
            onPressed: () => _run(widget.onClose),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final connectedCount = widget.model.participants
        .where((participant) => participant.connected)
        .length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _ShareTab(
              key: const Key('share-tab-lan'),
              selected: _section == PlaymeshShareSection.lan,
              icon: Icons.lan_outlined,
              label: widget.strings.lanTab,
              onTap: () => _selectSection(PlaymeshShareSection.lan),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ShareTab(
              key: const Key('share-tab-internet'),
              selected: _section == PlaymeshShareSection.internet,
              icon: Icons.public_outlined,
              label: widget.strings.internetTab,
              onTap: () => _selectSection(PlaymeshShareSection.internet),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ShareTab(
              key: const Key('share-tab-room'),
              selected: _section == PlaymeshShareSection.room,
              icon: Icons.groups_outlined,
              label: widget.strings.roomTab,
              badge: connectedCount,
              onTap: () => _selectSection(PlaymeshShareSection.room),
            ),
          ),
        ],
      ),
    );
  }

  void _selectSection(PlaymeshShareSection section) {
    if (_section == section) {
      if (section == PlaymeshShareSection.internet) {
        _run(widget.onInternetOpened);
      }
      return;
    }
    setState(() => _section = section);
    if (section == PlaymeshShareSection.internet) {
      _run(widget.onInternetOpened);
    }
  }

  Widget _buildLan(BuildContext context) {
    return _ScrollableSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LaneIntro(
            icon: Icons.wifi_tethering,
            label: widget.strings.lanTab,
            hint: widget.strings.lanHint,
            tone: _LaneTone.local,
          ),
          const SizedBox(height: 16),
          if (widget.model.lanLoading)
            const _SectionProgress()
          else ...<Widget>[
            if (widget.model.lanError != null)
              _SectionMessage(message: widget.model.lanError!, error: true),
            if (widget.model.lanLinks.isEmpty && widget.model.lanError == null)
              _SectionMessage(message: widget.strings.noLanLinks),
            if (widget.model.lanLinks.isNotEmpty)
              _LinkPresentation(
                links: widget.model.lanLinks,
                selectedId: widget.model.selectedLanLinkId,
                selectable: widget.onSelectLanLink != null,
                actionMode: widget.actionMode,
                strings: widget.strings,
                onSelect: widget.onSelectLanLink == null
                    ? null
                    : (link) => _runWithId(widget.onSelectLanLink, link.id),
                onAction: (link) => _runLinkAction(link),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildInternet(BuildContext context) {
    final model = widget.model;
    final hasCatalog = model.serverCatalog != null;
    return _ScrollableSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LaneIntro(
            icon: Icons.public,
            label: widget.strings.internetTab,
            hint: widget.strings.internetHint,
            tone: _LaneTone.internet,
          ),
          const SizedBox(height: 16),
          if (model.internetLoading)
            const _SectionProgress()
          else ...<Widget>[
            if (model.internetError != null)
              _SectionMessage(message: model.internetError!, error: true),
            if (model.internetLinks.isNotEmpty)
              _LinkPresentation(
                links: model.internetLinks,
                selectedId: model.selectedInternetLinkId,
                selectable: false,
                actionMode: widget.actionMode,
                strings: widget.strings,
                onAction: (link) => _runLinkAction(link),
              )
            else if (model.internetError == null &&
                (!hasCatalog || model.serverCatalog!.selectedId != null))
              _SectionMessage(message: widget.strings.noInternetLinks),
          ],
          if (hasCatalog) ...<Widget>[
            const SizedBox(height: 18),
            _buildServerCatalog(context, model.serverCatalog!),
          ],
        ],
      ),
    );
  }

  Widget _buildServerCatalog(
    BuildContext context,
    PlaymeshShareServerCatalog catalog,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    final visibleOptions = catalog.options
        .where(
          (option) =>
              query.isEmpty || option.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (catalog.searchEnabled || catalog.refreshEnabled)
          Row(
            children: <Widget>[
              if (catalog.searchEnabled)
                Expanded(
                  child: TextField(
                    key: const Key('share-server-search'),
                    controller: _searchController,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: widget.strings.serverSearchHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              if (catalog.searchEnabled && catalog.refreshEnabled)
                const SizedBox(width: 8),
              if (catalog.refreshEnabled)
                IconButton.filledTonal(
                  key: const Key('share-server-refresh'),
                  tooltip: widget.strings.refreshServersTooltip,
                  onPressed: catalog.loading || widget.onServerRefresh == null
                      ? null
                      : () => _run(widget.onServerRefresh),
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        if (catalog.searchEnabled || catalog.refreshEnabled)
          const SizedBox(height: 12),
        if (catalog.loading)
          const _SectionProgress(height: 120)
        else if (catalog.errorMessage != null)
          _SectionMessage(message: catalog.errorMessage!, error: true)
        else if (visibleOptions.isEmpty)
          _SectionMessage(message: widget.strings.noServers)
        else
          for (final option in visibleOptions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: option.id == catalog.selectedId
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                child: ListTile(
                  key: ValueKey<String>('share-server-${option.id}'),
                  enabled: option.enabled,
                  minTileHeight: 52,
                  title: Text(
                    option.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: option.latencyMilliseconds == null
                      ? null
                      : Text('${option.latencyMilliseconds} ms'),
                  trailing: option.id == catalog.selectedId
                      ? const Icon(Icons.check_circle)
                      : const Icon(Icons.chevron_right),
                  onTap:
                      !catalog.selectionEnabled ||
                          widget.onServerSelected == null
                      ? null
                      : () => _runWithId(widget.onServerSelected, option.id),
                ),
              ),
            ),
        if (catalog.selectedId != null &&
            widget.onServerDisconnected != null) ...<Widget>[
          const SizedBox(height: 4),
          OutlinedButton.icon(
            key: const Key('share-server-disconnect'),
            onPressed: catalog.loading
                ? null
                : () => _run(widget.onServerDisconnected),
            icon: const Icon(Icons.link_off),
            label: Text(widget.strings.disconnectServer),
          ),
        ],
      ],
    );
  }

  Widget _buildRoom(BuildContext context) {
    return _ScrollableSection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _LaneIntro(
            icon: Icons.groups,
            label: widget.strings.roomTab,
            hint: widget.strings.roomHint,
            tone: _LaneTone.room,
          ),
          const SizedBox(height: 16),
          if (widget.model.participants.isEmpty)
            _SectionMessage(message: widget.strings.noPlayers)
          else
            for (final participant in widget.model.participants)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                    key: ValueKey<String>(
                      'share-participant-${participant.id}',
                    ),
                    leading: CircleAvatar(
                      child: Icon(
                        participant.connected
                            ? Icons.person
                            : Icons.person_off_outlined,
                      ),
                    ),
                    title: Text(
                      participant.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    trailing: Text(
                      participant.connected
                          ? widget.strings.playerOnline
                          : widget.strings.playerOffline,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  void _runLinkAction(PlaymeshShareLink link) {
    unawaited(Future<void>.sync(() => widget.onLinkAction(link)));
  }

  void _run(PlaymeshShareVoidAction? action) {
    if (action != null) {
      unawaited(Future<void>.sync(action));
    }
  }

  void _runWithId(PlaymeshShareIdAction? action, String id) {
    if (action != null) {
      unawaited(Future<void>.sync(() => action(id)));
    }
  }
}

class _ShareTab extends StatelessWidget {
  const _ShareTab({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 18),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              if (badge != null) ...<Widget>[
                const SizedBox(width: 4),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary
                        : colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$badge',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected
                          ? colors.onPrimary
                          : colors.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _LaneTone { local, internet, room }

class _LaneIntro extends StatelessWidget {
  const _LaneIntro({
    required this.icon,
    required this.label,
    required this.hint,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String hint;
  final _LaneTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      _LaneTone.local => (colors.tertiaryContainer, colors.onTertiaryContainer),
      _LaneTone.internet => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      _LaneTone.room => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: foreground.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: foreground),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foreground.withValues(alpha: 0.82),
                      height: 1.35,
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

class _ScrollableSection extends StatelessWidget {
  const _ScrollableSection({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('share-panel-scroll'),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _LinkPresentation extends StatelessWidget {
  const _LinkPresentation({
    required this.links,
    required this.selectedId,
    required this.selectable,
    required this.actionMode,
    required this.strings,
    required this.onAction,
    this.onSelect,
  });

  final List<PlaymeshShareLink> links;
  final String? selectedId;
  final bool selectable;
  final PlaymeshShareActionMode actionMode;
  final PlaymeshSharePanelStrings strings;
  final ValueChanged<PlaymeshShareLink> onAction;
  final ValueChanged<PlaymeshShareLink>? onSelect;

  PlaymeshShareLink get _activeLink {
    for (final link in links) {
      if (link.id == selectedId) {
        return link;
      }
    }
    return links.first;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 540;
        final qr = _ShareQr(
          link: _activeLink,
          size: compact ? 148 : 190,
          semanticLabel: strings.qrSemantics,
        );
        final list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final link in links)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ShareLinkTile(
                  link: link,
                  selected: link.id == _activeLink.id,
                  selectable: selectable,
                  actionMode: actionMode,
                  strings: strings,
                  onSelect: onSelect,
                  onAction: onAction,
                ),
              ),
          ],
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(child: qr),
              const SizedBox(height: 14),
              list,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            qr,
            const SizedBox(width: 18),
            Expanded(child: list),
          ],
        );
      },
    );
  }
}

class _ShareQr extends StatelessWidget {
  const _ShareQr({
    required this.link,
    required this.size,
    required this.semanticLabel,
  });

  final PlaymeshShareLink link;
  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final compactLabel = link.label?.trim().isNotEmpty == true
        ? link.label!.trim()
        : playmeshCompactShareLink(link.url);
    final bytes = link.qrPngBytes;
    return Semantics(
      image: true,
      label: '$semanticLabel, $compactLabel',
      child: ExcludeSemantics(
        child: Container(
          width: size + 20,
          height: size + 20,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: bytes == null
              ? QrImageView(
                  data: link.url.toString(),
                  size: size,
                  padding: EdgeInsets.zero,
                )
              : Image.memory(
                  Uint8List.fromList(bytes),
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.qr_code_2,
                    size: 72,
                    color: Colors.black,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ShareLinkTile extends StatelessWidget {
  const _ShareLinkTile({
    required this.link,
    required this.selected,
    required this.selectable,
    required this.actionMode,
    required this.strings,
    required this.onAction,
    this.onSelect,
  });

  final PlaymeshShareLink link;
  final bool selected;
  final bool selectable;
  final PlaymeshShareActionMode actionMode;
  final PlaymeshSharePanelStrings strings;
  final ValueChanged<PlaymeshShareLink> onAction;
  final ValueChanged<PlaymeshShareLink>? onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = playmeshCompactShareLink(link.url);
    final label = link.label?.trim();
    final actionTooltip = actionMode == PlaymeshShareActionMode.share
        ? strings.shareLinkTooltip
        : strings.copyLinkTooltip;
    return Semantics(
      label: label?.isNotEmpty == true ? '$label, $compact' : compact,
      button: selectable,
      child: Material(
        key: ValueKey<String>('share-link-${link.id}'),
        color: selected
            ? colors.primaryContainer
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(12, 3, 4, 3),
          leading: selectable
              ? Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                )
              : const Icon(Icons.link),
          title: Text(
            label?.isNotEmpty == true ? label! : compact,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: label?.isNotEmpty == true
              ? Text(compact, maxLines: 1, overflow: TextOverflow.ellipsis)
              : null,
          trailing: IconButton(
            key: ValueKey<String>('share-link-action-${link.id}'),
            tooltip: actionTooltip,
            onPressed: () => onAction(link),
            icon: Icon(
              actionMode == PlaymeshShareActionMode.share
                  ? Icons.share_outlined
                  : Icons.copy_outlined,
            ),
          ),
          onTap: selectable && onSelect != null ? () => onSelect!(link) : null,
        ),
      ),
    );
  }
}

class _SectionProgress extends StatelessWidget {
  const _SectionProgress({this.height = 180});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

class _SectionMessage extends StatelessWidget {
  const _SectionMessage({required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 28),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: error ? Theme.of(context).colorScheme.error : null,
        ),
      ),
    );
  }
}
