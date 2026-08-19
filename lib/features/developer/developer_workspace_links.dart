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
    return LayoutBuilder(
      builder: (context, constraints) {
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (selectedLink != null) ...[
              FilledButton.icon(
                onPressed: () => widget.onOpenWorkspace(selectedLink.uri),
                icon: Icon(widget.openIcon),
                label: Text(widget.openLabel),
              ),
              const SizedBox(height: 12),
            ],
            if (displayedLinks.isEmpty)
              Text(widget.emptyMessage)
            else
              for (final link in displayedLinks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    selected: link == selectedLink,
                    selectedTileColor: colors.secondaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    textColor: colors.onSurface,
                    iconColor: colors.onSurfaceVariant,
                    selectedColor: colors.onSecondaryContainer,
                    leading: Icon(
                      link == selectedLink
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(link.uri.host),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${context.tr('creator.lan_interface')}: '
                          '${link.interfaceName} · '
                          '${_addressTypeLabel(context, link.addressType)} · '
                          '${_riskLabel(context, link.risk)}',
                        ),
                        SelectableText(
                          link.uri.toString(),
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            color: link == selectedLink
                                ? colors.onSecondaryContainer
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: context.tr('creator.copy_link'),
                      onPressed: () => _copyLink(context, link.uri),
                      icon: const Icon(Icons.copy_rounded),
                    ),
                    onTap: () => setState(() => _selectedLink = link),
                  ),
                ),
            if (displayedLinks.isNotEmpty)
              Text(context.tr('creator.qr_description')),
          ],
        );
        final qr = selectedLink == null
            ? null
            : DeveloperWorkspaceQrCode(uri: selectedLink.uri);
        if (constraints.maxWidth < 560 && qr != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [qr, const SizedBox(height: 12), details],
          );
        }
        if (qr == null) return details;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            qr,
            const SizedBox(width: 16),
            Expanded(child: details),
          ],
        );
      },
    );
  }

  String _addressTypeLabel(BuildContext context, LanAddressType type) =>
      context.tr(switch (type) {
        LanAddressType.privateIpv4 => 'creator.lan_type_private_ipv4',
        LanAddressType.linkLocalIpv4 => 'creator.lan_type_link_local_ipv4',
        LanAddressType.carrierGradeNatIpv4 =>
          'creator.lan_type_carrier_nat_ipv4',
        LanAddressType.benchmarkIpv4 => 'creator.lan_type_benchmark_ipv4',
        LanAddressType.publicIpv4 => 'creator.lan_type_public_ipv4',
        LanAddressType.uniqueLocalIpv6 => 'creator.lan_type_unique_local_ipv6',
        LanAddressType.globalIpv6 => 'creator.lan_type_global_ipv6',
        LanAddressType.other => 'creator.lan_type_other',
      });

  String _riskLabel(BuildContext context, LanEndpointRisk risk) =>
      context.tr(switch (risk) {
        LanEndpointRisk.low => 'creator.lan_risk_low',
        LanEndpointRisk.caution => 'creator.lan_risk_caution',
        LanEndpointRisk.high => 'creator.lan_risk_high',
      });

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
    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: QrImageView(data: uri.toString(), size: 150),
      ),
    );
  }
}
