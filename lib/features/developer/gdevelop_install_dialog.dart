import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/developer/gdevelop_local_package_source.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../widgets/endpoint_picker.dart';
import 'visual_gdevelop_controller.dart';

typedef GDevelopLocalPackagePicker = Future<XFile?> Function();
typedef GDevelopErrorMessageBuilder =
    String Function(BuildContext context, Object error);

Future<void> showGDevelopInstallDialog(
  BuildContext context, {
  required VisualGDevelopController controller,
  required GDevelopErrorMessageBuilder errorMessageBuilder,
  GDevelopLocalPackagePicker? localPackagePicker,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _GDevelopInstallDialog(
      controller: controller,
      errorMessageBuilder: errorMessageBuilder,
      localPackagePicker: localPackagePicker ?? _pickLocalPackage,
    ),
  );
}

Future<XFile?> _pickLocalPackage() => openFile(
  acceptedTypeGroups: const [
    XTypeGroup(label: 'GDevelop WebIDE ZIP', extensions: ['zip']),
  ],
);

enum _GDevelopInstallMethod { local, online }

class _GDevelopInstallDialog extends StatefulWidget {
  const _GDevelopInstallDialog({
    required this.controller,
    required this.errorMessageBuilder,
    required this.localPackagePicker,
  });

  final VisualGDevelopController controller;
  final GDevelopErrorMessageBuilder errorMessageBuilder;
  final GDevelopLocalPackagePicker localPackagePicker;

  @override
  State<_GDevelopInstallDialog> createState() => _GDevelopInstallDialogState();
}

class _GDevelopInstallDialogState extends State<_GDevelopInstallDialog> {
  _GDevelopInstallMethod? _method;
  XFile? _localPackage;
  Object? _pickerError;
  int _step = 0;
  bool _picking = false;
  bool _submitted = false;

  int get _stepCount => switch (_method) {
    _GDevelopInstallMethod.local => 3,
    _GDevelopInstallMethod.online => 4,
    null => 3,
  };

  bool get _isLastStep => _step == _stepCount - 1;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogHeight = math.min(660.0, size.height * 0.88);
    return PopScope(
      canPop: !widget.controller.state.operationRunning,
      child: Dialog(
        key: const Key('gdevelop-install-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: SizedBox(
          width: 640,
          height: dialogHeight,
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => _buildDialog(context),
          ),
        ),
      ),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final visual = widget.controller.state;
    final running = visual.operationRunning;
    final completed = _submitted && visual.completedOperation != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
          child: Row(
            children: [
              const Icon(Icons.memory_rounded),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.tr('creator.gdevelop_install_dialog_title'),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: context.tr('common.close'),
                onPressed: running ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (!running && !completed) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _stepTitle(context),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${_step + 1} / $_stepCount',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          LinearProgressIndicator(
            value: (_step + 1) / _stepCount,
            minHeight: 3,
          ),
        ],
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AnimatedSwitcher(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              child: KeyedSubtree(
                key: ValueKey<String>(
                  '$running-$completed-${_method?.name}-$_step',
                ),
                child: running
                    ? _GDevelopOperationProgress(state: visual)
                    : completed
                    ? _buildCompleted(context, visual.completedOperation!)
                    : _buildStep(context),
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: _buildActions(context),
        ),
      ],
    );
  }

  Widget _buildStep(BuildContext context) {
    final visual = widget.controller.state;
    final content = switch ((_method, _step)) {
      (null, _) || (_, 0) => _buildMethodStep(context),
      (_GDevelopInstallMethod.local, 1) => _buildLocalPackageStep(context),
      (_GDevelopInstallMethod.local, _) => _buildLocalConfirmation(context),
      (_GDevelopInstallMethod.online, 1) => _buildConfigSourceStep(context),
      (_GDevelopInstallMethod.online, 2) => _buildDownloadSourceStep(context),
      (_GDevelopInstallMethod.online, _) => _buildOnlineConfirmation(context),
    };
    final error = _currentError(visual);
    if (error == null) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        content,
        const SizedBox(height: 12),
        _DialogMessage(
          message: error is _PickerFailure
              ? context.tr(
                  'creator.gdevelop_local_picker_failed',
                  arguments: {'error': error.error},
                )
              : widget.errorMessageBuilder(context, error),
        ),
      ],
    );
  }

  Widget _buildMethodStep(BuildContext context) {
    return Column(
      children: [
        _InstallMethodTile(
          icon: Icons.folder_zip_outlined,
          label: context.tr('creator.gdevelop_local_install'),
          selected: _method == _GDevelopInstallMethod.local,
          onTap: () => setState(() {
            _method = _GDevelopInstallMethod.local;
            _submitted = false;
          }),
        ),
        const SizedBox(height: 10),
        _InstallMethodTile(
          icon: Icons.cloud_download_outlined,
          label: context.tr('creator.gdevelop_online_install'),
          selected: _method == _GDevelopInstallMethod.online,
          onTap: () => setState(() {
            _method = _GDevelopInstallMethod.online;
            _submitted = false;
          }),
        ),
      ],
    );
  }

  Widget _buildLocalPackageStep(BuildContext context) {
    final selected = _localPackage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected != null) ...[
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            child: ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: Text(
                selected.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          key: const Key('gdevelop-local-install-button'),
          onPressed: _picking ? null : _selectLocalPackage,
          icon: _picking
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.folder_open_rounded),
          label: Text(
            context.tr(
              selected == null
                  ? 'creator.gdevelop_choose_zip'
                  : 'creator.gdevelop_change_zip',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigSourceStep(BuildContext context) {
    final controller = widget.controller.configSourcePicker;
    if (controller == null) return const LinearProgressIndicator(minHeight: 2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EndpointPicker(
          controller: controller,
          refreshLabel: context.tr('creator.gdevelop_refresh_sources'),
          emptyLabel: context.tr('creator.gdevelop_config_source_empty'),
          probingLabel: context.tr('creator.gdevelop_probe_checking'),
          timeoutLabel: context.tr('creator.gdevelop_probe_timeout'),
          unreachableLabel: context.tr('creator.gdevelop_probe_unreachable'),
          unsupportedLabel: context.tr('creator.gdevelop_probe_unsupported'),
          latencyLabelBuilder: (latencyMs) => context.tr(
            'creator.gdevelop_probe_latency',
            arguments: {'latency': latencyMs},
          ),
          onSelected: widget.controller.selectConfigSource,
        ),
        if (widget.controller.state.loadingRelease) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(minHeight: 2),
        ],
      ],
    );
  }

  Widget _buildDownloadSourceStep(BuildContext context) {
    final controller = widget.controller.downloadSourcePicker;
    if (controller == null) return const LinearProgressIndicator(minHeight: 2);
    return EndpointPicker(
      controller: controller,
      refreshLabel: context.tr('creator.gdevelop_refresh_sources'),
      emptyLabel: context.tr('creator.gdevelop_download_source_empty'),
      probingLabel: context.tr('creator.gdevelop_probe_checking'),
      timeoutLabel: context.tr('creator.gdevelop_probe_timeout'),
      unreachableLabel: context.tr('creator.gdevelop_probe_unreachable'),
      unsupportedLabel: context.tr('creator.gdevelop_probe_unsupported'),
      latencyLabelBuilder: (latencyMs) => context.tr(
        'creator.gdevelop_probe_latency',
        arguments: {'latency': latencyMs},
      ),
      onSelected: (_) {},
    );
  }

  Widget _buildLocalConfirmation(BuildContext context) {
    return _ReviewTable(
      rows: [
        (
          context.tr('creator.gdevelop_install_method'),
          context.tr('creator.gdevelop_local_install'),
        ),
        (
          context.tr('creator.gdevelop_package_step'),
          _localPackage?.name ?? '—',
        ),
      ],
    );
  }

  Widget _buildOnlineConfirmation(BuildContext context) {
    final visual = widget.controller.state;
    final release = visual.release;
    return _ReviewTable(
      rows: [
        (
          context.tr('creator.gdevelop_config_source_title'),
          widget.controller.configSourcePicker?.selected?.name ?? '—',
        ),
        (
          context.tr('creator.gdevelop_download_source_title'),
          widget.controller.selectedDownload?.name ?? '—',
        ),
        (
          context.tr('creator.gdevelop_release'),
          release == null
              ? '—'
              : '${release.version} · ${_shortSha256(release.sha256)} · '
                    '${_formatBytes(release.size)}',
        ),
      ],
    );
  }

  Widget _buildCompleted(
    BuildContext context,
    VisualGDevelopOperation operation,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 48, color: colors.primary),
            const SizedBox(height: 12),
            Text(
              context.tr(
                'creator.gdevelop_operation_complete',
                arguments: {'action': _operationLabel(context, operation)},
              ),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final visual = widget.controller.state;
    if (visual.operationRunning) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            key: const Key('gdevelop-cancel-button'),
            onPressed: widget.controller.cancelOperation,
            icon: const Icon(Icons.close_rounded),
            label: Text(context.tr('creator.gdevelop_action_cancel')),
          ),
        ],
      );
    }
    if (_submitted && visual.completedOperation != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('common.done')),
          ),
        ],
      );
    }
    final operation = _onlineOperation;
    return Row(
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('common.cancel')),
        ),
        const Spacer(),
        if (_step > 0) ...[
          TextButton(
            key: const Key('gdevelop-back-button'),
            onPressed: _previousStep,
            child: Text(context.tr('creator.gdevelop_previous')),
          ),
          const SizedBox(width: 8),
        ],
        FilledButton(
          key: _isLastStep
              ? ValueKey<String>(
                  operation == VisualGDevelopOperation.repair
                      ? 'gdevelop-repair-button'
                      : 'gdevelop-install-button',
                )
              : const Key('gdevelop-next-button'),
          onPressed: _canContinue ? _next : null,
          child: Text(
            _isLastStep
                ? _operationLabel(
                    context,
                    _method == _GDevelopInstallMethod.local
                        ? VisualGDevelopOperation.install
                        : operation ?? VisualGDevelopOperation.install,
                  )
                : context.tr('creator.gdevelop_next'),
          ),
        ),
      ],
    );
  }

  VisualGDevelopOperation? get _onlineOperation {
    final visual = widget.controller.state;
    return visual.primaryOperation ??
        (visual.releaseMatchesInstallation
            ? VisualGDevelopOperation.repair
            : null);
  }

  bool get _canContinue {
    if (_step == 0) return _method != null;
    return switch (_method) {
      _GDevelopInstallMethod.local =>
        _step == 1 ? _localPackage != null && !_picking : true,
      _GDevelopInstallMethod.online => switch (_step) {
        1 =>
          widget.controller.configSourcePicker?.selected != null &&
              widget.controller.state.release != null &&
              !widget.controller.state.loadingRelease,
        2 => widget.controller.selectedDownload != null,
        _ => _onlineOperation != null,
      },
      null => false,
    };
  }

  Object? _currentError(VisualGDevelopState visual) {
    if (_pickerError case final error?) return _PickerFailure(error);
    if (_method == _GDevelopInstallMethod.online && _step == 1) {
      return visual.configError ?? visual.releaseError;
    }
    if (_isLastStep) return visual.operationError;
    return null;
  }

  String _stepTitle(BuildContext context) {
    if (_step == 0) return context.tr('creator.gdevelop_install_method');
    return switch (_method) {
      _GDevelopInstallMethod.local =>
        _step == 1
            ? context.tr('creator.gdevelop_package_step')
            : context.tr('common.confirm'),
      _GDevelopInstallMethod.online => switch (_step) {
        1 => context.tr('creator.gdevelop_config_source_title'),
        2 => context.tr('creator.gdevelop_download_source_title'),
        _ => context.tr('common.confirm'),
      },
      null => context.tr('creator.gdevelop_install_method'),
    };
  }

  void _previousStep() {
    if (_step == 0) return;
    setState(() {
      _step -= 1;
      _submitted = false;
      _pickerError = null;
    });
  }

  Future<void> _next() async {
    if (!_canContinue) return;
    if (!_isLastStep) {
      setState(() => _step += 1);
      return;
    }
    setState(() => _submitted = true);
    if (_method == _GDevelopInstallMethod.local) {
      await _installLocalPackage();
      return;
    }
    final operation = _onlineOperation;
    if (operation == VisualGDevelopOperation.repair) {
      await widget.controller.repair();
    } else {
      await widget.controller.startPrimaryOperation();
    }
  }

  Future<void> _selectLocalPackage() async {
    setState(() {
      _picking = true;
      _pickerError = null;
    });
    try {
      final selected = await widget.localPackagePicker();
      if (!mounted) return;
      setState(() {
        if (selected != null) _localPackage = selected;
        _picking = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _pickerError = error;
      });
    }
  }

  Future<void> _installLocalPackage() async {
    final selected = _localPackage;
    if (selected == null) return;
    final source = GDevelopLocalPackageSource(
      displayName: selected.name,
      openRead: selected.openRead,
      readAsBytes: selected.readAsBytes,
    );
    try {
      await widget.controller.installLocalPackage(
        source: source,
        allowMemoryFallback: false,
      );
    } on GDevelopLocalPackageStreamingUnavailable {
      if (!mounted) return;
      setState(() => _submitted = false);
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(
                dialogContext.tr('creator.gdevelop_memory_fallback_title'),
              ),
              content: Text(
                dialogContext.tr('creator.gdevelop_memory_fallback_message'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dialogContext.tr('common.cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(
                    dialogContext.tr('creator.gdevelop_memory_fallback_use'),
                  ),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
      setState(() => _submitted = true);
      await widget.controller.installLocalPackage(
        source: source,
        allowMemoryFallback: true,
      );
    }
  }
}

class _InstallMethodTile extends StatelessWidget {
  const _InstallMethodTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: selected ? colors.primary : null),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewTable extends StatelessWidget {
  const _ReviewTable({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      rows[index].$1,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[index].$2,
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            if (index != rows.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _GDevelopOperationProgress extends StatelessWidget {
  const _GDevelopOperationProgress({required this.state});

  final VisualGDevelopState state;

  @override
  Widget build(BuildContext context) {
    final progress = state.progress;
    final operation = state.operation!;
    final value = progress?.fraction.clamp(0.0, 1.0).toDouble();
    final message = progress == null
        ? context.tr(
            'creator.gdevelop_operation_preparing',
            arguments: {'action': _operationLabel(context, operation)},
          )
        : context.tr(
            'creator.gdevelop_operation_progress',
            arguments: {
              'action': _operationLabel(context, operation),
              'percent': (value! * 100).round(),
              'received': _formatBytes(progress.receivedBytes),
              'total': _formatBytes(progress.totalBytes),
            },
          );
    return Semantics(
      liveRegion: true,
      value: message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: value, minHeight: 4),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _DialogMessage extends StatelessWidget {
  const _DialogMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 19, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: TextStyle(color: color)),
        ),
      ],
    );
  }
}

class _PickerFailure {
  const _PickerFailure(this.error);

  final Object error;
}

String _operationLabel(
  BuildContext context,
  VisualGDevelopOperation operation,
) => switch (operation) {
  VisualGDevelopOperation.install => context.tr(
    'creator.gdevelop_action_install',
  ),
  VisualGDevelopOperation.upgrade => context.tr(
    'creator.gdevelop_action_upgrade',
  ),
  VisualGDevelopOperation.repair => context.tr(
    'creator.gdevelop_action_repair',
  ),
};

String _shortSha256(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '—';
  return normalized.length <= 12 ? normalized : normalized.substring(0, 12);
}

String _formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
