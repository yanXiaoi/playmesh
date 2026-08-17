import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/catalog/online_game_catalog.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/localization/playmesh_ui_controller.dart';
import '../../core/localization/playmesh_ui_preferences.dart';
import '../../core/protocol/go_core_status.dart';
import '../../core/release/playmesh_release_notes.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/services/go_core_status_service.dart';
import '../../core/update/app_update_service.dart';
import '../../ui/playmesh_ui.dart';
import 'app_update_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.statusProvider,
    this.catalogController,
    this.uiController,
    this.updateChecker,
  });

  static const routeName = '/settings';

  final GoCoreStatusProvider? statusProvider;
  final GameCatalogController? catalogController;
  final PlaymeshUiController? uiController;
  final AppUpdateChecker? updateChecker;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final GoCoreStatusProvider _statusProvider;
  late final bool _ownsStatusProvider;
  late final AppUpdateChecker _updateChecker;
  late final bool _ownsUpdateChecker;
  GoCoreStatusResult? _result;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _ownsStatusProvider = widget.statusProvider == null;
    _statusProvider = widget.statusProvider ?? GoCoreRuntime.bundled();
    _ownsUpdateChecker = widget.updateChecker == null;
    _updateChecker = widget.updateChecker ?? AppUpdateService.bundled();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    if (_ownsStatusProvider) {
      unawaited(_statusProvider.close());
    }
    if (_ownsUpdateChecker) {
      _updateChecker.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('settings.title'))),
      body: PlaymeshBackground(
        child: ListView(
          children: [
            ResponsivePage(
              maxWidth: 880,
              child: Column(
                children: [
                  EntranceAnimation(
                    child: _AboutSection(
                      onCheckUpdates: () => _showAppUpdateDialog(context),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (widget.uiController case final ui?) ...[
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 20),
                      child: _AppearanceSection(controller: ui),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (widget.catalogController case final catalog?) ...[
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 40),
                      child: _CatalogShareSection(controller: catalog),
                    ),
                    const SizedBox(height: 14),
                  ],
                  EntranceAnimation(
                    delay: const Duration(milliseconds: 80),
                    child: _CoreStatusSection(
                      endpoint: _statusProvider.endpoint,
                      isLoading: _isLoading,
                      result: _result,
                      onRefresh: _refreshStatus,
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

  Future<void> _refreshStatus() async {
    if (!_isLoading) {
      setState(() => _isLoading = true);
    }

    final result = await _statusProvider.check();
    if (!mounted) {
      return;
    }

    setState(() {
      _result = result;
      _isLoading = false;
    });
  }

  Future<void> _showAppUpdateDialog(BuildContext context) =>
      showPlaymeshAppUpdateDialog(context, checker: _updateChecker);
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection({required this.controller});

  static const _systemLocaleValue = '__system__';

  final PlaymeshUiController controller;

  @override
  Widget build(BuildContext context) {
    final manifest = controller.catalog.manifest;
    final preferences = controller.preferences;
    final selectedLocale = preferences.localeMode == PlaymeshLocaleMode.system
        ? _systemLocaleValue
        : preferences.localeId!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const GradientIcon(
                  icon: Icons.contrast_rounded,
                  size: 44,
                  iconSize: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.tr('settings.appearance'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (manifest.allowLocaleSwitch)
              DropdownButtonFormField<String>(
                initialValue: selectedLocale,
                decoration: InputDecoration(
                  labelText: context.tr('settings.language'),
                  prefixIcon: const Icon(Icons.language_rounded),
                ),
                items: [
                  DropdownMenuItem(
                    value: _systemLocaleValue,
                    child: Text(context.tr('settings.language_system')),
                  ),
                  for (final locale in manifest.enabledLocales)
                    DropdownMenuItem(
                      value: locale.id,
                      child: Text(locale.label),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  unawaited(
                    value == _systemLocaleValue
                        ? controller.useSystemLocale()
                        : controller.useLocale(value),
                  );
                },
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.language_rounded),
                title: Text(context.tr('settings.language')),
                subtitle: Text(
                  manifest
                      .descriptor(
                        preferences.localeId ?? manifest.defaultLocale,
                      )
                      .label,
                ),
              ),
            const SizedBox(height: 16),
            Text(
              context.tr('settings.theme'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            if (manifest.allowThemeSwitch)
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<PlaymeshThemePreference>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: PlaymeshThemePreference.system,
                      icon: const Icon(Icons.brightness_auto_outlined),
                      label: Text(context.tr('settings.theme_system')),
                    ),
                    ButtonSegment(
                      value: PlaymeshThemePreference.light,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: Text(context.tr('settings.theme_light')),
                    ),
                    ButtonSegment(
                      value: PlaymeshThemePreference.dark,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: Text(context.tr('settings.theme_dark')),
                    ),
                  ],
                  selected: {preferences.theme},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      unawaited(controller.useTheme(selection.first));
                    }
                  },
                ),
              )
            else
              Text(context.tr('settings.theme_${preferences.theme.wireName}')),
          ],
        ),
      ),
    );
  }
}

class _CatalogShareSection extends StatefulWidget {
  const _CatalogShareSection({required this.controller});

  final GameCatalogController controller;

  @override
  State<_CatalogShareSection> createState() => _CatalogShareSectionState();
}

class _CatalogShareSectionState extends State<_CatalogShareSection> {
  late final TextEditingController _portController;
  late final TextEditingController _tokenController;
  Future<List<Uri>>? _links;
  Uri? _selectedLink;
  bool _busy = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController();
    _tokenController = TextEditingController();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      await widget.controller.initialize();
      _portController.text = widget.controller.share.port.toString();
      _tokenController.text = widget.controller.share.token;
      _links = widget.controller.sharingEndpoints();
    } on Object catch (error) {
      _error = error;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final enabled = widget.controller.sharing;
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('settings.catalog_share'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: _busy
                        ? null
                        : (value) => unawaited(_setEnabled(value)),
                  ),
                ],
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final port = TextField(
                    controller: _portController,
                    enabled: !enabled && !_busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: context.tr('settings.port'),
                      hintText: '16668',
                    ),
                  );
                  final token = TextField(
                    controller: _tokenController,
                    enabled: !enabled && !_busy,
                    decoration: InputDecoration(
                      labelText: context.tr('settings.catalog_token'),
                    ),
                  );
                  if (constraints.maxWidth < 520) {
                    return Column(
                      children: [port, const SizedBox(height: 10), token],
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
              const SizedBox(height: 10),
              if (_error != null || widget.controller.shareError != null)
                Text(
                  context.tr(
                    'settings.catalog_unavailable',
                    arguments: {
                      'error': _error ?? widget.controller.shareError,
                    },
                  ),
                )
              else if (!enabled)
                Text(context.tr('settings.catalog_share_description'))
              else
                FutureBuilder<List<Uri>>(
                  future: _links,
                  builder: (context, snapshot) {
                    final links = snapshot.data ?? const [];
                    final selected =
                        _selectedLink ?? (links.isEmpty ? null : links.first);
                    final config = selected == null
                        ? null
                        : widget.controller.configurationUriFor(
                            selected,
                            name: 'Playmesh ${selected.host}',
                          );
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final details = Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (links.isEmpty)
                              Text(context.tr('settings.no_lan_address'))
                            else
                              for (final link in links)
                                ListTile(
                                  dense: true,
                                  leading: Icon(
                                    link == selected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off,
                                  ),
                                  title: Text(link.host),
                                  subtitle: SelectableText(
                                    link.toString(),
                                    style: const TextStyle(
                                      fontFamily: 'Consolas',
                                      fontSize: 12,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    tooltip: context.tr(
                                      'settings.copy_catalog_config',
                                    ),
                                    onPressed: config == null
                                        ? null
                                        : () => _copyConfig(config),
                                    icon: const Icon(Icons.copy),
                                  ),
                                  onTap: () =>
                                      setState(() => _selectedLink = link),
                                ),
                            Text(context.tr('settings.catalog_qr_description')),
                          ],
                        );
                        final qr = config == null
                            ? null
                            : ColoredBox(
                                color: Colors.white,
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: QrImageView(
                                    data: config.toString(),
                                    size: 150,
                                  ),
                                ),
                              );
                        if (constraints.maxWidth < 560 || qr == null) {
                          return Column(
                            children: [
                              if (qr != null) ...[
                                qr,
                                const SizedBox(height: 10),
                              ],
                              details,
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            qr,
                            const SizedBox(width: 14),
                            Expanded(child: details),
                          ],
                        );
                      },
                    );
                  },
                ),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _setEnabled(bool enabled) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (enabled) {
        final port = int.tryParse(_portController.text.trim());
        if (port == null) {
          throw FormatException(context.tr('settings.port_integer_error'));
        }
        await widget.controller.enableSharing(
          port: port,
          token: _tokenController.text,
        );
        _links = widget.controller.sharingEndpoints();
      } else {
        await widget.controller.disableSharing();
        _links = null;
        _selectedLink = null;
      }
    } on Object catch (error) {
      _error = error;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyConfig(Uri configuration) async {
    await Clipboard.setData(ClipboardData(text: configuration.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('settings.catalog_config_copied'))),
    );
  }
}

class _CoreStatusSection extends StatelessWidget {
  const _CoreStatusSection({
    required this.endpoint,
    required this.isLoading,
    required this.result,
    required this.onRefresh,
  });

  final Uri endpoint;
  final bool isLoading;
  final GoCoreStatusResult? result;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final presentation = _StatusPresentation.from(context, isLoading, result);
    final status = result?.status;
    final requestId = result?.requestId;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('settings.core_status'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('settings.core_refresh'),
                    onPressed: isLoading ? null : onRefresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (isLoading) const LinearProgressIndicator(minHeight: 2),
            ListTile(
              leading: Icon(presentation.icon, color: presentation.color),
              title: Text(presentation.label),
              subtitle: Text(presentation.message),
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: Text(context.tr('settings.service_address')),
              subtitle: SelectableText(endpoint.toString()),
            ),
            if (status != null)
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text('Core ${status.coreVersion}'),
                subtitle: Text(
                  context.tr(
                    'settings.started_at',
                    arguments: {
                      'time': _formatTimestamp(context, status.startedAt),
                    },
                  ),
                ),
              ),
            if (requestId != null)
              ListTile(
                leading: const Icon(Icons.tag),
                title: Text(context.tr('settings.request_id')),
                subtitle: SelectableText(requestId),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusPresentation {
  const _StatusPresentation({
    required this.label,
    required this.message,
    required this.icon,
    required this.color,
  });

  final String label;
  final String message;
  final IconData icon;
  final Color color;

  factory _StatusPresentation.from(
    BuildContext context,
    bool isLoading,
    GoCoreStatusResult? result,
  ) {
    if (isLoading) {
      return _StatusPresentation(
        label: context.tr('settings.core_checking'),
        message: context.tr('settings.core_connecting'),
        icon: Icons.sync,
        color: Theme.of(context).colorScheme.primary,
      );
    }

    switch (result?.availability) {
      case GoCoreAvailability.online:
        return _StatusPresentation(
          label: context.tr('settings.core_online'),
          message: context.tr('settings.core_online_description'),
          icon: Icons.check_circle_outline,
          color: const Color(0xff287d3c),
        );
      case GoCoreAvailability.offline:
        return _StatusPresentation(
          label: context.tr('settings.core_offline'),
          message: result!.message,
          icon: Icons.cloud_off_outlined,
          color: const Color(0xffa35b00),
        );
      case GoCoreAvailability.error:
        return _StatusPresentation(
          label: context.tr('settings.core_error'),
          message: result!.message,
          icon: Icons.error_outline,
          color: const Color(0xffb3261e),
        );
      case null:
        return _StatusPresentation(
          label: context.tr('settings.core_unchecked'),
          message: context.tr('settings.core_unchecked_description'),
          icon: Icons.help_outline,
          color: Colors.grey,
        );
    }
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.onCheckUpdates});

  final VoidCallback onCheckUpdates;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final identity = Row(
              children: [
                const GradientIcon(
                  icon: Icons.hub_rounded,
                  size: 54,
                  iconSize: 27,
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Playmesh $playmeshVersion',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        context.tr(
                          'settings.about_description',
                          arguments: {'build': playmeshBuildNumber},
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
            final actions = Wrap(
              spacing: 6,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: const Key('check-app-update-button'),
                  onPressed: onCheckUpdates,
                  icon: const Icon(Icons.system_update_alt_rounded),
                  label: Text(context.tr('settings.check_updates')),
                ),
                IconButton(
                  tooltip: context.tr('settings.release_notes'),
                  onPressed: () => _showReleaseNotes(context),
                  icon: const Icon(Icons.new_releases_outlined),
                ),
              ],
            );
            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [identity, const SizedBox(height: 12), actions],
              );
            }
            return Row(
              children: [
                Expanded(child: identity),
                const SizedBox(width: 12),
                actions,
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _showReleaseNotes(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.tr(
            'settings.release_title',
            arguments: {'version': playmeshVersion},
          ),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (
                  var index = 0;
                  index < playmeshReleaseHighlightCount;
                  index++
                )
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 7),
                          child: Icon(Icons.circle, size: 5),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            context.tr('release.highlight_${index + 1}'),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  context.tr(
                    'settings.build_number',
                    arguments: {'build': playmeshBuildNumber},
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.tr('common.close')),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(BuildContext context, DateTime timestamp) {
  final local = timestamp.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatMediumDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
}
