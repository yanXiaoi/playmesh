import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/download/endpoint_probe_contract.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/update/app_update_models.dart';
import '../../core/update/app_update_service.dart';

Future<void> showPlaymeshAppUpdateDialog(
  BuildContext context, {
  required AppUpdateChecker checker,
}) => showDialog<void>(
  context: context,
  builder: (context) => _AppUpdateDialog(checker: checker),
);

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.checker});

  final AppUpdateChecker checker;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  AppUpdateCheckResult? _result;
  Object? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('app-update-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Row(
        children: [
          Icon(
            Icons.system_update_alt_rounded,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(context.tr('settings.update_title'))),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _loading
              ? _buildLoading(context)
              : _error != null
              ? _buildError(context)
              : _buildResult(context, _result!),
        ),
      ),
      actions: [
        if (!_loading)
          TextButton.icon(
            onPressed: _check,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.tr('settings.update_check_again')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('common.close')),
        ),
      ],
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Column(
      key: const ValueKey('app-update-loading'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 12),
        Text(
          context.tr('settings.update_checking'),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Column(
      key: const ValueKey('app-update-error'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_off_rounded,
          size: 36,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 12),
        Text(_errorMessage(context, _error!), textAlign: TextAlign.center),
      ],
    );
  }

  Widget _buildResult(BuildContext context, AppUpdateCheckResult result) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color, stateLabel) = switch (result.versionState) {
      AppUpdateVersionState.available => (
        Icons.new_releases_rounded,
        colors.primary,
        context.tr('settings.update_available'),
      ),
      AppUpdateVersionState.current => (
        Icons.verified_rounded,
        colors.tertiary,
        context.tr('settings.update_current'),
      ),
      AppUpdateVersionState.ahead => (
        Icons.science_rounded,
        colors.secondary,
        context.tr('settings.update_ahead'),
      ),
    };
    return ConstrainedBox(
      key: const ValueKey('app-update-result'),
      constraints: const BoxConstraints(maxHeight: 560),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: color.withAlpha(18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withAlpha(72)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: color),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          stateLabel,
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _VersionLabel(
                        label: context.tr('settings.update_current_version'),
                        version: result.currentVersion.toString(),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: colors.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                      _VersionLabel(
                        label: context.tr('settings.update_latest_version'),
                        version: result.latestVersion.toString(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    context.tr(
                      'settings.update_source_summary',
                      arguments: {
                        'source': result.source.name,
                        'valid': result.successfulSourceCount,
                        'total': result.sourceCount,
                      },
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('app-update-release-notes-button'),
                onPressed: () => _showReleaseNotes(result.releaseNotes),
                icon: const Icon(Icons.notes_rounded),
                label: Text(context.tr('settings.update_view_release_notes')),
              ),
            ),
            const SizedBox(height: 16),
            _SectionLabel(
              icon: Icons.download_rounded,
              label: context.tr(
                'settings.update_downloads',
                arguments: {
                  'platform': _platformLabel(context, result.platform),
                },
              ),
            ),
            const SizedBox(height: 8),
            if (!result.platformAvailable)
              Text(context.tr('settings.update_platform_unavailable'))
            else if (result.downloads.isEmpty)
              Text(context.tr('settings.update_downloads_empty'))
            else
              for (final download in result.downloads)
                Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: _AppUpdateDownloadTile(
                    download: download,
                    onOpen: () => _openDownload(download),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.checker.checkForUpdates();
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _openDownload(AppUpdateDownload download) async {
    final opened = await widget.checker.openDownload(download);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr(
            opened
                ? 'settings.update_browser_opened'
                : 'settings.update_browser_failed',
          ),
        ),
      ),
    );
  }

  Future<void> _showReleaseNotes(String releaseNotes) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('app-update-release-notes-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(context.tr('settings.update_release_notes')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 480),
          child: SingleChildScrollView(child: SelectableText(releaseNotes)),
        ),
        actions: [
          TextButton(
            key: const Key('app-update-release-notes-close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.tr('common.close')),
          ),
        ],
      ),
    );
  }

  String _errorMessage(BuildContext context, Object error) {
    if (error is AppUpdateCheckException) {
      return switch (error.kind) {
        AppUpdateCheckFailureKind.invalidConfiguration => context.tr(
          'settings.update_error_configuration',
        ),
        AppUpdateCheckFailureKind.noAvailableManifest => context.tr(
          'settings.update_error_network',
        ),
        AppUpdateCheckFailureKind.closed => context.tr(
          'settings.update_error_unknown',
        ),
      };
    }
    return context.tr('settings.update_error_unknown');
  }

  String _platformLabel(BuildContext context, String platform) =>
      context.tr('settings.update_platform_$platform');
}

class _VersionLabel extends StatelessWidget {
  const _VersionLabel({required this.label, required this.version});

  final String label;
  final String version;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Column(
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 3),
          Text(
            version,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
      ],
    );
  }
}

class _AppUpdateDownloadTile extends StatelessWidget {
  const _AppUpdateDownloadTile({required this.download, required this.onOpen});

  final AppUpdateDownload download;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final (color, status) = switch (download.probe.state) {
      EndpointProbeState.reachable => (
        Theme.of(context).colorScheme.primary,
        context.tr(
          'settings.update_latency',
          arguments: {'latency': download.probe.latencyMs ?? 0},
        ),
      ),
      EndpointProbeState.timeout => (
        Theme.of(context).colorScheme.error,
        context.tr('settings.update_latency_timeout'),
      ),
      EndpointProbeState.unreachable => (
        Theme.of(context).colorScheme.error,
        context.tr('settings.update_latency_unreachable'),
      ),
      EndpointProbeState.unsupported => (
        Theme.of(context).colorScheme.tertiary,
        context.tr('settings.update_latency_unsupported'),
      ),
      EndpointProbeState.probing => (
        Theme.of(context).colorScheme.onSurfaceVariant,
        context.tr('settings.update_latency_checking'),
      ),
    };
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: ValueKey('app-update-download-${download.endpoint.url}'),
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  download.endpoint.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                status,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFamily: 'Consolas',
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              IconButton(
                key: ValueKey(
                  'app-update-download-open-${download.endpoint.url}',
                ),
                tooltip: context.tr('settings.update_open_browser'),
                onPressed: onOpen,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_browser_rounded, size: 19),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
