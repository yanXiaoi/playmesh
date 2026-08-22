import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/developer/developer_channel.dart';
import '../../core/developer/gdevelop_web_ide_installer_contract.dart';
import '../../core/download/endpoint_document_contract.dart';
import '../../core/download/endpoint_probe_contract.dart';
import '../../core/download/safe_zip_extractor_contract.dart';
import '../../core/download/verified_resumable_download_contract.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../ui/playmesh_ui.dart';
import 'developer_mode_controller.dart';
import 'developer_workspace_links.dart';
import 'developer_workspace_page.dart';
import 'gdevelop_install_dialog.dart';
import 'gdevelop_notices_dialog.dart';
import 'gdevelop_workspace_route_coordinator.dart';
import 'source_development_controller.dart';
import 'visual_gdevelop_controller.dart';

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
  static const gdevelopManageButtonKey = Key('gdevelop-manage-button');
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
                      description: null,
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GDevelopInstallationStatus(state: visual),
        if (visual.statusError case final error?) ...[
          const SizedBox(height: 8),
          _GDevelopInlineMessage(
            icon: Icons.warning_amber_rounded,
            message: _gdevelopErrorMessage(context, error),
            error: true,
          ),
        ],
        if (installed && state.enabled) ...[
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
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
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: GameCreationPage.gdevelopManageButtonKey,
              onPressed:
                  widget.developerProvider != null &&
                      installationAllowed &&
                      !visual.operationRunning
                  ? _showGDevelopInstallDialog
                  : null,
              icon: const Icon(Icons.memory_rounded),
              label: Text(context.tr('creator.gdevelop_manage')),
            ),
            TextButton.icon(
              key: GameCreationPage.gdevelopNoticesButtonKey,
              onPressed: installed && widget.developerProvider != null
                  ? () => showGDevelopDistributionNotices(
                      context,
                      loadNotices: widget
                          .developerProvider!
                          .loadInstalledGDevelopWebIdeNotices,
                    )
                  : null,
              icon: const Icon(Icons.gavel_outlined),
              label: Text(context.tr('creator.gdevelop_notices')),
            ),
          ],
        ),
      ],
    );
  }

  void _showGDevelopInstallDialog() {
    unawaited(
      showGDevelopInstallDialog(
        context,
        controller: _visualController,
        errorMessageBuilder: _gdevelopErrorMessage,
        localPackagePicker: widget.localPackagePicker,
      ),
    );
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
    unawaited(_openVisualWorkspaceWithFreshCapability(workspaceUri));
  }

  Future<void> _openVisualWorkspaceWithFreshCapability(Uri workspaceUri) async {
    final currentWorkspaceUri = await _visualController.workspaceUriForOpen(
      workspaceUri,
    );
    if (!mounted || currentWorkspaceUri == null) return;
    await gdevelopWorkspaceRouteCoordinator.open(
      context: context,
      workspaceUri: _visualController.inAppWorkspaceUri(currentWorkspaceUri),
      title: context.tr('creator.visual_title'),
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
  final String? description;
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
                        if (description?.trim().isNotEmpty == true) ...[
                          const SizedBox(height: 3),
                          Text(
                            description!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
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
  ) =>
    context.tr('creator.gdevelop_disable_to_install'),
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
