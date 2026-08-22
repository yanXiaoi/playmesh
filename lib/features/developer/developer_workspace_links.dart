import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/localization/playmesh_localization.dart';
import '../../core/network/lan_endpoint.dart';

class DeveloperWorkspaceLinks extends StatefulWidget {
  const DeveloperWorkspaceLinks({
    super.key,
    required this.links,
    required this.openLabel,
    required this.openIcon,
    required this.emptyMessage,
    required this.onOpenWorkspace,
  });

  final List<LanEndpointCandidate> links;
  final String openLabel;
  final IconData openIcon;
  final String emptyMessage;
  final ValueChanged<Uri> onOpenWorkspace;

  @override
  State<DeveloperWorkspaceLinks> createState() =>
      _DeveloperWorkspaceLinksState();
}

class _DeveloperWorkspaceLinksState extends State<DeveloperWorkspaceLinks> {
  LanEndpointCandidate? _selectedLink;

  LanEndpointCandidate? get _effectiveLink {
    if (_selectedLink case final selected?
        when widget.links.contains(selected)) {
      return selected;
    }
    return sortLanEndpointCandidates(widget.links).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final displayedLinks = sortLanEndpointCandidates(widget.links);
    final selectedLink = _effectiveLink;
    final colors = Theme.of(context).colorScheme;
    if (displayedLinks.isEmpty || selectedLink == null) {
      return Text(widget.emptyMessage);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final chooser = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final link in displayedLinks)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Semantics(
                  label: link.uri.host,
                  selected: link == selectedLink,
                  button: true,
                  child: Material(
                    key: ValueKey<String>(
                      'developer-workspace-link-${link.uri.host}',
                    ),
                    color: link == selectedLink
                        ? colors.secondaryContainer
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      textColor: colors.onSurface,
                      iconColor: colors.onSurfaceVariant,
                      leading: Icon(
                        link == selectedLink
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 20,
                      ),
                      title: Text(
                        link.uri.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      trailing: IconButton(
                        tooltip: context.tr('creator.copy_link'),
                        onPressed: () => _copyLink(context, link.uri),
                        icon: const Icon(Icons.copy_outlined),
                      ),
                      onTap: () => setState(() => _selectedLink = link),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 2),
            FilledButton.icon(
              onPressed: () => widget.onOpenWorkspace(selectedLink.uri),
              icon: Icon(widget.openIcon),
              label: Text(widget.openLabel),
            ),
          ],
        );
        final qr = DeveloperWorkspaceQrCode(uri: selectedLink.uri);
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: qr),
              const SizedBox(height: 12),
              chooser,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            qr,
            const SizedBox(width: 14),
            Expanded(child: chooser),
          ],
        );
      },
    );
  }

  Future<void> _copyLink(BuildContext context, Uri link) async {
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr('creator.link_copied'))));
  }
}

class DeveloperWorkspaceQrCode extends StatelessWidget {
  const DeveloperWorkspaceQrCode({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: uri.host,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: QrImageView(
            data: uri.toString(),
            size: 136,
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
