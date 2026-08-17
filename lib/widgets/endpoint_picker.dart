import 'package:flutter/material.dart';

import '../core/download/endpoint_picker_controller.dart';
import '../core/download/endpoint_probe_contract.dart';
import '../core/download/named_download_endpoint.dart';

typedef EndpointLatencyLabelBuilder = String Function(int latencyMs);

class EndpointPicker extends StatefulWidget {
  const EndpointPicker({
    super.key,
    required this.controller,
    required this.title,
    required this.description,
    required this.refreshLabel,
    required this.emptyLabel,
    required this.probingLabel,
    required this.timeoutLabel,
    required this.unreachableLabel,
    required this.unsupportedLabel,
    required this.latencyLabelBuilder,
    required this.onSelected,
    this.autoProbe = true,
  });

  final EndpointPickerController controller;
  final String title;
  final String description;
  final String refreshLabel;
  final String emptyLabel;
  final String probingLabel;
  final String timeoutLabel;
  final String unreachableLabel;
  final String unsupportedLabel;
  final EndpointLatencyLabelBuilder latencyLabelBuilder;
  final ValueChanged<NamedDownloadEndpoint> onSelected;
  final bool autoProbe;

  @override
  State<EndpointPicker> createState() => _EndpointPickerState();
}

class _EndpointPickerState extends State<EndpointPicker> {
  @override
  void initState() {
    super.initState();
    _scheduleInitialProbe();
  }

  @override
  void didUpdateWidget(covariant EndpointPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        (!oldWidget.autoProbe && widget.autoProbe)) {
      _scheduleInitialProbe();
    }
  }

  void _scheduleInitialProbe() {
    if (!widget.autoProbe || widget.controller.endpoints.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.probeAll();
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      widget.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: widget.controller.endpoints.isEmpty
                    ? null
                    : widget.controller.refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(widget.refreshLabel),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.controller.endpoints.isEmpty)
            _EndpointEmptyState(label: widget.emptyLabel)
          else
            for (final endpoint in widget.controller.endpoints) ...[
              _EndpointChoice(
                endpoint: endpoint,
                result: widget.controller.resultFor(endpoint),
                selected: widget.controller.selected == endpoint,
                enabled: widget.controller.canSelect(endpoint),
                statusLabel: _statusLabel(
                  widget.controller.resultFor(endpoint),
                ),
                onTap: () {
                  if (widget.controller.select(endpoint)) {
                    widget.onSelected(endpoint);
                  }
                },
              ),
              if (endpoint != widget.controller.endpoints.last)
                const SizedBox(height: 8),
            ],
        ],
      );
    },
  );

  String _statusLabel(EndpointProbeResult? result) {
    switch (result?.state) {
      case EndpointProbeState.reachable:
        return widget.latencyLabelBuilder(result!.latencyMs ?? 0);
      case EndpointProbeState.timeout:
        return widget.timeoutLabel;
      case EndpointProbeState.unreachable:
        return widget.unreachableLabel;
      case EndpointProbeState.unsupported:
        return widget.unsupportedLabel;
      case EndpointProbeState.probing:
      case null:
        return widget.probingLabel;
    }
  }
}

class _EndpointEmptyState extends StatelessWidget {
  const _EndpointEmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _EndpointChoice extends StatelessWidget {
  const _EndpointChoice({
    required this.endpoint,
    required this.result,
    required this.selected,
    required this.enabled,
    required this.statusLabel,
    required this.onTap,
  });

  final NamedDownloadEndpoint endpoint;
  final EndpointProbeResult? result;
  final bool selected;
  final bool enabled;
  final String statusLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: 0.48);
    final statusColor = switch (result?.state) {
      EndpointProbeState.reachable => colors.primary,
      EndpointProbeState.unreachable ||
      EndpointProbeState.timeout => colors.error,
      EndpointProbeState.unsupported => colors.tertiary,
      EndpointProbeState.probing || null => colors.onSurfaceVariant,
    };
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: '${endpoint.name}, ${endpoint.url.host}, $statusLabel',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer.withValues(alpha: 0.4)
              : colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: enabled ? colors.primary : foreground,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        endpoint.name,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        endpoint.url.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground.withValues(alpha: 0.72),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    child: Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
