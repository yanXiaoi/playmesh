import 'dart:async';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../../core/developer/developer_channel.dart';
import '../../core/developer/gdevelop_web_ide_installer_contract.dart';
import '../../core/developer/gdevelop_local_package_source.dart';
import '../../core/download/endpoint_document_contract.dart';
import '../../core/download/endpoint_probe_contract.dart';
import '../../core/download/safe_zip_extractor_contract.dart';
import '../../core/download/verified_resumable_download_contract.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../ui/playmesh_ui.dart';
import '../../widgets/endpoint_picker.dart';
import 'gdevelop_notices_dialog.dart';
import 'developer_mode_controller.dart';
import 'developer_workspace_links.dart';
import 'developer_workspace_page.dart';
import 'gdevelop_workspace_route_coordinator.dart';
import 'source_development_controller.dart';
import 'visual_gdevelop_controller.dart';

typedef GDevelopLocalPackagePicker = Future<XFile?> Function();

class GameCreationPage extends StatefulWidget {
  const GameCreationPage({
    super.key,
    this.developerProvider,
    this.gdevelopProbeService,
    this.localPackagePicker,
  });

  static const routeName = '/create-game';
  static const developerSwitchKey = Key('game-creation-developer-switch');
  static const gdevelopNoticesButtonKey = Key('game-creation-gdevelop-notices');
  static const sourcePanelKey = Key('game-creation-source-panel');
  static const visualPanelKey = Key('game-creation-visual-panel');
  static const gdevelopInstallButtonKey = Key('gdevelop-install-button');
  static const gdevelopRepairButtonKey = Key('gdevelop-repair-button');
  static const gdevelopCancelButtonKey = Key('gdevelop-cancel-button');
  static const gdevelopLocalInstallButtonKey = Key(
    'gdevelop-local-install-button',
  );

  final DeveloperModeProvider? developerProvider;
  final EndpointProbeService? gdevelopProbeService;
  final GDevelopLocalPackagePicker? localPackagePicker;

  @override
  State<GameCreationPage> createState() => _GameCreationPageState();
}

class _GameCreationPageState extends State<GameCreationPage> {
  late final DeveloperSessionController _sessionController;
  late final SourceDevelopmentController _sourceController;
  late final VisualGDevelopController _visualController;
  late final TextEditingController _portController;
  late final TextEditingController _tokenController;
  DeveloperSession? _synchronizedSession;
  bool _hasSynchronizedSession = false;
  bool _sourceExpanded = true;
  bool _visualExpanded = false;

  @override
  void initState() {
    super.initState();
    _sessionController = DeveloperSessionController(widget.developerProvider)
      ..addListener(_handleSessionChanged);
    _sourceController = SourceDevelopmentController(widget.developerProvider)
      ..addListener(_handleEntryChanged);
    _visualController = VisualGDevelopController(
      widget.developerProvider,
      probeService: widget.gdevelopProbeService,
    )..addListener(_handleEntryChanged);
    _portController = TextEditingController(
      text: defaultDeveloperPort.toString(),
    );
    _tokenController = TextEditingController();
    unawaited(_sessionController.initialize());
  }

  @override
  void dispose() {
    _sessionController
      ..removeListener(_handleSessionChanged)
      ..dispose();
    _sourceController
      ..removeListener(_handleEntryChanged)
      ..dispose();
    _visualController
      ..removeListener(_handleEntryChanged)
      ..dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _handleSessionChanged() {
    if (!mounted) return;
    final state = _sessionController.state;
    final port = state.port.toString();
    if (_portController.text != port) _portController.text = port;
    if (_tokenController.text != state.token) {
      _tokenController.text = state.token;
    }
    final session = state.session;
    if (!_hasSynchronizedSession || !identical(session, _synchronizedSession)) {
      _hasSynchronizedSession = true;
      _synchronizedSession = session;
      unawaited(_sourceController.synchronize(session));
      unawaited(_visualController.synchronize(session));
    }
    setState(() {});
  }

  void _handleEntryChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = _sessionController.state;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('creator.title'))),
      body: PlaymeshBackground(
        child: ListView(
          children: [
            ResponsivePage(
              maxWidth: 880,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  EntranceAnimation(
                    child: _DeveloperModeCard(
                      providerAvailable: widget.developerProvider != null,
                      state: state,
                      portController: _portController,
                      tokenController: _tokenController,
                      onToggle: (enabled) => unawaited(
                        enabled
                            ? _sessionController.enable(
                                portText: _portController.text,
                                token: _tokenController.text,
                              )
                            : _sessionController.disable(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  EntranceAnimation(
                    delay: const Duration(milliseconds: 45),
                    child: _WorkspaceAccordionPanel(
                      key: GameCreationPage.sourcePanelKey,
                      icon: Icons.code_rounded,
                      title: context.tr('creator.source_title'),
                      description: context.tr('creator.source_description'),
                      expanded: _sourceExpanded,
                      onToggle: _toggleSourcePanel,
                      child: _buildSourceWorkspaceBody(state),
                    ),
                  ),
                  const SizedBox(height: 12),
                  EntranceAnimation(
                    delay: const Duration(milliseconds: 90),
                    child: _WorkspaceAccordionPanel(
                      key: GameCreationPage.visualPanelKey,
                      icon: Icons.account_tree_outlined,
                      title: context.tr('creator.visual_title'),
                      description: context.tr('creator.visual_description'),
                      expanded: _visualExpanded,
                      onToggle: _toggleVisualPanel,
                      child: _buildVisualWorkspaceBody(state),
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

  Widget _buildSourceWorkspaceBody(DeveloperSessionState state) {
    if (!state.enabled) {
      return Text(context.tr('creator.enable_first'));
    }
    final source = _sourceController.state;
    if (source.loading) return const LinearProgressIndicator(minHeight: 2);
    if (source.error case final error?) {
      return Text(_developerErrorMessage(context, error));
    }
    return DeveloperWorkspaceLinks(
      links: source.links,
      openLabel: context.tr('creator.open_source_workspace'),
      openIcon: Icons.code_rounded,
      emptyMessage: context.tr('creator.no_lan_address'),
      onOpenWorkspace: _openSourceWorkspace,
    );
  }

  Widget _buildVisualWorkspaceBody(DeveloperSessionState state) {
    final visual = _visualController.state;
    if (visual.loading) return const LinearProgressIndicator(minHeight: 2);
    final installationAllowed =
        !state.enabled && !state.loading && state.targetEnabled == null;
    final installed =
        visual.installation?.state == GDevelopWebIdeInstallationState.ready;
    final configPicker = _visualController.configSourcePicker;
    final downloadPicker = _visualController.downloadSourcePicker;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GDevelopInstallationStatus(state: visual),
        const SizedBox(height: 8),
        _GDevelopDistributionNotice(
          onOpenNotices: installed && widget.developerProvider != null
              ? () => showGDevelopDistributionNotices(
                  context,
                  loadNotices: widget
                      .developerProvider!
                      .loadInstalledGDevelopWebIdeNotices,
                )
              : null,
        ),
        if (!state.enabled) ...[
          const SizedBox(height: 8),
          _GDevelopInlineMessage(
            icon: Icons.power_settings_new_rounded,
            message: context.tr('creator.gdevelop_enable_to_open'),
          ),
        ],
        if (visual.statusError case final error?) ...[
          const SizedBox(height: 8),
          _GDevelopInlineMessage(
            icon: Icons.warning_amber_rounded,
            message: _gdevelopErrorMessage(context, error),
            error: true,
          ),
        ],
        if (installed) ...[
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DeveloperWorkspaceLinks(
                    links: visual.links,
                    openLabel: context.tr('creator.open_gdevelop'),
                    openIcon: Icons.open_in_browser_rounded,
                    emptyMessage: context.tr('creator.no_lan_address'),
                    onOpenWorkspace: _openVisualWorkspace,
                  ),
                  if (visual.starting) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 6),
                    Text(context.tr('creator.gdevelop_gateway_starting')),
                  ],
                  if (visual.startError case final error?) ...[
                    const SizedBox(height: 10),
                    _GDevelopInlineMessage(
                      icon: Icons.error_outline_rounded,
                      message: _developerErrorMessage(context, error),
                      error: true,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: visual.starting
                            ? null
                            : () =>
                                  unawaited(_visualController.ensureStarted()),
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(
                          context.tr('creator.gdevelop_gateway_retry'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            const Icon(Icons.memory_rounded, size: 20),
            const SizedBox(width: 8),
            Text(
              context.tr('creator.gdevelop_kernel_management'),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        if (!installationAllowed) ...[
          const SizedBox(height: 10),
          _GDevelopInlineMessage(
            icon: Icons.power_settings_new_rounded,
            message: context.tr('creator.gdevelop_disable_to_install'),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          key: GameCreationPage.gdevelopLocalInstallButtonKey,
          onPressed: visual.operationRunning || !installationAllowed
              ? null
              : _selectLocalPackage,
          icon: const Icon(Icons.folder_zip_outlined),
          label: Text(context.tr('creator.gdevelop_local_install')),
        ),
        const SizedBox(height: 6),
        Text(
          context.tr('creator.gdevelop_local_install_hint'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 18),
        Text(
          context.tr('creator.gdevelop_distribution_title'),
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          context.tr('creator.gdevelop_distribution_description'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (visual.configError case final error?) ...[
          const SizedBox(height: 12),
          _GDevelopInlineMessage(
            icon: Icons.error_outline_rounded,
            message: _gdevelopErrorMessage(context, error),
            error: true,
          ),
        ],
        if (configPicker != null) ...[
          const SizedBox(height: 16),
          EndpointPicker(
            controller: configPicker,
            title: context.tr('creator.gdevelop_config_source_title'),
            description: context.tr(
              'creator.gdevelop_config_source_description',
            ),
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
            onSelected: (endpoint) =>
                unawaited(_visualController.selectConfigSource(endpoint)),
          ),
        ],
        if (visual.loadingRelease) ...[
          const SizedBox(height: 14),
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 8),
          Text(context.tr('creator.gdevelop_manifest_loading')),
        ],
        if (visual.releaseError case final error?) ...[
          const SizedBox(height: 12),
          _GDevelopInlineMessage(
            icon: Icons.error_outline_rounded,
            message: _gdevelopErrorMessage(context, error),
            error: true,
          ),
        ],
        if (visual.release case final release?) ...[
          const SizedBox(height: 16),
          _GDevelopReleaseIdentity(
            version: release.version,
            size: release.size,
            sha256: release.sha256,
          ),
          if (visual.releaseMatchesInstallation) ...[
            const SizedBox(height: 8),
            _GDevelopInlineMessage(
              icon: Icons.verified_outlined,
              message: context.tr('creator.gdevelop_release_current'),
            ),
          ],
        ],
        if (downloadPicker != null) ...[
          const SizedBox(height: 16),
          EndpointPicker(
            controller: downloadPicker,
            title: context.tr('creator.gdevelop_download_source_title'),
            description: context.tr(
              'creator.gdevelop_download_source_description',
            ),
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
          ),
        ],
        if (visual.operationRunning) ...[
          const SizedBox(height: 16),
          _GDevelopOperationProgress(state: visual),
        ],
        if (visual.operationError case final error?) ...[
          const SizedBox(height: 12),
          _GDevelopInlineMessage(
            icon: Icons.error_outline_rounded,
            message: _gdevelopErrorMessage(context, error),
            error: true,
          ),
        ],
        if (visual.completedOperation case final operation?) ...[
          const SizedBox(height: 12),
          _GDevelopInlineMessage(
            icon: Icons.check_circle_outline_rounded,
            message: context.tr(
              'creator.gdevelop_operation_complete',
              arguments: {
                'action': _gdevelopOperationLabel(context, operation),
              },
            ),
          ),
        ],
        if (visual.release != null || visual.operationRunning) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (visual.primaryOperation case final operation?)
                FilledButton.icon(
                  key: GameCreationPage.gdevelopInstallButtonKey,
                  onPressed:
                      installationAllowed &&
                          _visualController.canStartPrimaryOperation
                      ? () =>
                            unawaited(_visualController.startPrimaryOperation())
                      : null,
                  icon: Icon(_gdevelopOperationIcon(operation)),
                  label: Text(_gdevelopOperationLabel(context, operation)),
                ),
              if (_visualController.canRepair ||
                  (visual.releaseMatchesInstallation &&
                      !visual.operationRunning))
                OutlinedButton.icon(
                  key: GameCreationPage.gdevelopRepairButtonKey,
                  onPressed: installationAllowed && _visualController.canRepair
                      ? () => unawaited(_visualController.repair())
                      : null,
                  icon: const Icon(Icons.healing_rounded),
                  label: Text(context.tr('creator.gdevelop_action_repair')),
                ),
              if (visual.operationRunning)
                OutlinedButton.icon(
                  key: GameCreationPage.gdevelopCancelButtonKey,
                  onPressed: _visualController.cancelOperation,
                  icon: const Icon(Icons.close_rounded),
                  label: Text(context.tr('creator.gdevelop_action_cancel')),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _selectLocalPackage() async {
    XFile? selected;
    try {
      selected =
          await (widget.localPackagePicker?.call() ??
              openFile(
                acceptedTypeGroups: const [
                  XTypeGroup(label: 'GDevelop WebIDE ZIP', extensions: ['zip']),
                ],
              ));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'creator.gdevelop_local_picker_failed',
              arguments: {'error': error},
            ),
          ),
        ),
      );
      return;
    }
    if (selected == null || !mounted) return;
    final source = GDevelopLocalPackageSource(
      displayName: selected.name,
      openRead: selected.openRead,
      readAsBytes: selected.readAsBytes,
    );
    try {
      await _visualController.installLocalPackage(
        source: source,
        allowMemoryFallback: false,
      );
    } on GDevelopLocalPackageStreamingUnavailable {
      if (!mounted) return;
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
      await _visualController.installLocalPackage(
        source: source,
        allowMemoryFallback: true,
      );
    }
  }

  void _toggleSourcePanel() {
    setState(() {
      _sourceExpanded = !_sourceExpanded;
      if (_sourceExpanded) _visualExpanded = false;
    });
  }

  void _toggleVisualPanel() {
    setState(() {
      _visualExpanded = !_visualExpanded;
      if (_visualExpanded) _sourceExpanded = false;
    });
    if (_visualExpanded) {
      unawaited(_visualController.ensureStarted());
    }
  }

  void _openSourceWorkspace(Uri workspaceUri) {
    _openWorkspace(
      _sourceController.inAppWorkspaceUri(workspaceUri),
      context.tr('creator.source_title'),
    );
  }

  void _openVisualWorkspace(Uri workspaceUri) {
    unawaited(
      gdevelopWorkspaceRouteCoordinator.open(
        context: context,
        workspaceUri: _visualController.inAppWorkspaceUri(workspaceUri),
        title: context.tr('creator.visual_title'),
      ),
    );
  }

  void _openWorkspace(Uri workspaceUri, String title) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DeveloperWorkspacePage(
            workspaceUri: workspaceUri,
            workspaceTitle: title,
          ),
        ),
      ),
    );
  }
}

class _GDevelopDistributionNotice extends StatelessWidget {
  const _GDevelopDistributionNotice({required this.onOpenNotices});

  final VoidCallback? onOpenNotices;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: colors.primary, size: 20),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                context.tr('creator.gdevelop_unofficial_notice'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: GameCreationPage.gdevelopNoticesButtonKey,
              onPressed: onOpenNotices,
              child: Text(context.tr('creator.gdevelop_notices')),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeveloperModeCard extends StatelessWidget {
  const _DeveloperModeCard({
    required this.providerAvailable,
    required this.state,
    required this.portController,
    required this.tokenController,
    required this.onToggle,
  });

  final bool providerAvailable;
  final DeveloperSessionState state;
  final TextEditingController portController;
  final TextEditingController tokenController;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const GradientIcon(
                  icon: Icons.developer_mode_rounded,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('creator.developer_mode'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        context.tr('creator.developer_mode_hint'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: GameCreationPage.developerSwitchKey,
                  value: state.targetEnabled ?? state.enabled,
                  onChanged: providerAvailable && !state.loading
                      ? onToggle
                      : null,
                ),
              ],
            ),
            if (state.loading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final port = TextField(
                  controller: portController,
                  enabled:
                      providerAvailable && !state.enabled && !state.loading,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: context.tr('settings.port'),
                    hintText: defaultDeveloperPort.toString(),
                  ),
                );
                final token = TextField(
                  controller: tokenController,
                  enabled:
                      providerAvailable && !state.enabled && !state.loading,
                  decoration: InputDecoration(
                    labelText: 'Token',
                    hintText: context.tr('creator.token_hint'),
                  ),
                );
                if (constraints.maxWidth < 520) {
                  return Column(
                    children: [port, const SizedBox(height: 12), token],
                  );
                }
                return Row(
                  children: [
                    SizedBox(width: 140, child: port),
                    const SizedBox(width: 12),
                    Expanded(child: token),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            if (!providerAvailable)
              Text(context.tr('creator.channel_unsupported'))
            else if (state.error case final error?)
              Text(
                context.tr(
                  'creator.unavailable',
                  arguments: {'error': _developerErrorMessage(context, error)},
                ),
              )
            else if (state.loading)
              Text(
                context.tr(
                  state.targetEnabled == false
                      ? 'creator.stopping'
                      : 'creator.starting',
                ),
              )
            else if (state.enabled)
              Text(
                context.tr(
                  'creator.enabled',
                  arguments: {'hint': state.session?.tokenHint ?? '------'},
                ),
              )
            else
              Text(context.tr('creator.developer_description')),
            if (state.enabled &&
                Theme.of(context).platform == TargetPlatform.android) ...[
              const SizedBox(height: 8),
              Text(
                context.tr('creator.android_description'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkspaceAccordionPanel extends StatelessWidget {
  const _WorkspaceAccordionPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GradientIcon(icon: icon, size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: expanded
                ? Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: colors.outlineVariant),
                      ),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _GDevelopInstallationStatus extends StatelessWidget {
  const _GDevelopInstallationStatus({required this.state});

  final VisualGDevelopState state;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final installation = state.installation;
    final (
      icon,
      message,
      background,
      foreground,
    ) = switch (installation?.state) {
      GDevelopWebIdeInstallationState.ready => (
        Icons.check_circle_rounded,
        context.tr(
          'creator.gdevelop_status_installed',
          arguments: {
            'version': installation?.marker?.version ?? '—',
            'build': _shortGDevelopSha256(installation?.marker?.sha256),
          },
        ),
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      GDevelopWebIdeInstallationState.needsRepair => (
        Icons.healing_rounded,
        context.tr('creator.gdevelop_status_needs_repair'),
        colors.errorContainer,
        colors.onErrorContainer,
      ),
      GDevelopWebIdeInstallationState.absent => (
        Icons.download_for_offline_outlined,
        context.tr('creator.gdevelop_status_absent'),
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      null => (
        Icons.help_outline_rounded,
        context.tr('creator.gdevelop_status_unknown'),
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: foreground, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GDevelopReleaseIdentity extends StatelessWidget {
  const _GDevelopReleaseIdentity({
    required this.version,
    required this.size,
    required this.sha256,
  });

  final String version;
  final int size;
  final String sha256;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr(
                'creator.gdevelop_release_identity',
                arguments: {
                  'version': version,
                  'build': _shortGDevelopSha256(sha256),
                  'size': _formatGDevelopBytes(size),
                },
              ),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'SHA-256  $sha256',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
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
            arguments: {'action': _gdevelopOperationLabel(context, operation)},
          )
        : context.tr(
            'creator.gdevelop_operation_progress',
            arguments: {
              'action': _gdevelopOperationLabel(context, operation),
              'percent': (value! * 100).round(),
              'received': _formatGDevelopBytes(progress.receivedBytes),
              'total': _formatGDevelopBytes(progress.totalBytes),
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

class _GDevelopInlineMessage extends StatelessWidget {
  const _GDevelopInlineMessage({
    required this.icon,
    required this.message,
    this.error = false,
  });

  final IconData icon;
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = error ? colors.error : colors.primary;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

String _gdevelopOperationLabel(
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

IconData _gdevelopOperationIcon(VisualGDevelopOperation operation) =>
    switch (operation) {
      VisualGDevelopOperation.install => Icons.download_rounded,
      VisualGDevelopOperation.upgrade => Icons.upgrade_rounded,
      VisualGDevelopOperation.repair => Icons.healing_rounded,
    };

String _formatGDevelopBytes(int bytes) {
  const mebibyte = 1024 * 1024;
  if (bytes < mebibyte) return '$bytes B';
  return '${(bytes / mebibyte).toStringAsFixed(1)} MiB';
}

String _shortGDevelopSha256(String? sha256) =>
    sha256 == null || sha256.length < 12 ? '—' : sha256.substring(0, 12);

String _gdevelopErrorMessage(
  BuildContext context,
  Object error,
) => switch (error) {
  EndpointDocumentLoadException(kind: EndpointDocumentFailureKind.timeout) ||
  VerifiedDownloadException(
    kind: VerifiedDownloadFailureKind.timeout,
  ) => context.tr('creator.gdevelop_error_timeout'),
  EndpointDocumentLoadException(
    kind: EndpointDocumentFailureKind.dns ||
        EndpointDocumentFailureKind.tls ||
        EndpointDocumentFailureKind.http ||
        EndpointDocumentFailureKind.network,
  ) ||
  VerifiedDownloadException(
    kind: VerifiedDownloadFailureKind.http ||
        VerifiedDownloadFailureKind.network ||
        VerifiedDownloadFailureKind.invalidUrl,
  ) => context.tr('creator.gdevelop_error_network'),
  EndpointDocumentLoadException(
    kind: EndpointDocumentFailureKind.invalidDocument ||
        EndpointDocumentFailureKind.invalidUtf8 ||
        EndpointDocumentFailureKind.tooLarge ||
        EndpointDocumentFailureKind.invalidUrl,
  ) ||
  FormatException() => context.tr('creator.gdevelop_error_manifest'),
  VerifiedDownloadException(kind: VerifiedDownloadFailureKind.quota) =>
    context.tr('creator.gdevelop_error_space'),
  VerifiedDownloadException(kind: VerifiedDownloadFailureKind.cancelled) =>
    context.tr('creator.gdevelop_error_cancelled'),
  VerifiedDownloadException(
    kind: VerifiedDownloadFailureKind.invalidResponse ||
        VerifiedDownloadFailureKind.sizeMismatch ||
        VerifiedDownloadFailureKind.sha256Mismatch,
  ) =>
    context.tr('creator.gdevelop_error_integrity'),
  SafeZipExtractionException() => context.tr('creator.gdevelop_error_archive'),
  GDevelopWebIdeInstallBusyException() => context.tr(
    'creator.gdevelop_error_busy',
  ),
  GDevelopWebIdeInstallException(
    diagnostic: 'gdevelop_developer_mode_must_be_disabled_before_install',
  ) => context.tr('creator.gdevelop_disable_to_install'),
  GDevelopWebIdeInstallException(diagnostic: final diagnostic)
      when diagnostic.startsWith('gdevelop_local_package_read_failed') =>
    context.tr('creator.gdevelop_error_local_read'),
  GDevelopWebIdeInstallException(
    diagnostic: 'gdevelop_local_package_empty' ||
        'gdevelop_required_file_missing' ||
        'gdevelop_required_file_invalid' ||
        'gdevelop_integration_identity_mismatch',
  ) =>
    context.tr('creator.gdevelop_error_local_invalid'),
  GDevelopWebIdeInstallException() => context.tr(
    'creator.gdevelop_error_install',
  ),
  _ => context.tr('creator.gdevelop_error_unknown'),
};

String _developerErrorMessage(BuildContext context, Object error) =>
    switch (error) {
      DeveloperPortException(error: DeveloperPortError.notInteger) =>
        context.tr('settings.port_integer_error'),
      DeveloperPortException(error: DeveloperPortError.outOfRange) =>
        context.tr('settings.port_range_error'),
      FormatException(:final message) => message,
      StateError(:final message) => message,
      _ => error.toString(),
    };
