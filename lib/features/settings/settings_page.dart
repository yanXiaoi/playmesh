import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/developer/developer_channel.dart';
import '../../core/catalog/online_game_catalog.dart';
import '../../core/protocol/go_core_status.dart';
import '../../core/release/playmesh_release_notes.dart';
import '../../core/services/go_core_runtime.dart';
import '../../core/services/go_core_status_service.dart';
import '../../ui/playmesh_ui.dart';
import '../developer/developer_workspace_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.statusProvider,
    this.developerProvider,
    this.catalogController,
  });

  static const routeName = '/settings';

  final GoCoreStatusProvider? statusProvider;
  final DeveloperModeProvider? developerProvider;
  final GameCatalogController? catalogController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final GoCoreStatusProvider _statusProvider;
  late final DeveloperModeProvider? _developerProvider;
  late final bool _ownsStatusProvider;
  late final TextEditingController _developerPortController;
  late final TextEditingController _developerTokenController;
  GoCoreStatusResult? _result;
  DeveloperSession? _developerSession;
  List<Uri> _developerLinks = const [];
  Object? _developerError;
  bool _isLoading = true;
  bool _developerLoading = false;
  bool? _developerTargetEnabled;

  @override
  void initState() {
    super.initState();
    _ownsStatusProvider = widget.statusProvider == null;
    _statusProvider = widget.statusProvider ?? GoCoreRuntime.bundled();
    _developerProvider =
        widget.developerProvider ??
        (_statusProvider is DeveloperModeProvider
            ? _statusProvider as DeveloperModeProvider
            : null);
    _developerLoading = _developerProvider != null;
    _developerPortController = TextEditingController(
      text: defaultDeveloperPort.toString(),
    );
    _developerTokenController = TextEditingController();
    _refreshStatus();
    unawaited(_initializeDeveloperMode());
  }

  @override
  void dispose() {
    _developerPortController.dispose();
    _developerTokenController.dispose();
    if (_ownsStatusProvider) {
      unawaited(_statusProvider.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: PlaymeshBackground(
        child: ListView(
          children: [
            ResponsivePage(
              maxWidth: 880,
              child: Column(
                children: [
                  const EntranceAnimation(child: _AboutSection()),
                  if (widget.catalogController case final catalog?) ...[
                    const SizedBox(height: 14),
                    EntranceAnimation(
                      delay: const Duration(milliseconds: 40),
                      child: _CatalogShareSection(controller: catalog),
                    ),
                  ],
                  const SizedBox(height: 14),
                  EntranceAnimation(
                    delay: const Duration(milliseconds: 60),
                    child: _DeveloperModeSection(
                      providerAvailable: _developerProvider != null,
                      portController: _developerPortController,
                      tokenController: _developerTokenController,
                      loading: _developerLoading,
                      targetEnabled: _developerTargetEnabled,
                      session: _developerSession,
                      links: _developerLinks,
                      error: _developerError,
                      onEnable: _enableDeveloperMode,
                      onDisable: _disableDeveloperMode,
                      onOpenWorkspace: _openDeveloperWorkspace,
                    ),
                  ),
                  const SizedBox(height: 14),
                  EntranceAnimation(
                    delay: const Duration(milliseconds: 120),
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
    if (!_isLoading || _result == null) {
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

  Future<void> _enableDeveloperMode() async {
    final provider = _developerProvider;
    if (provider == null) {
      setState(() => _developerError = '当前运行时不支持开发者模式。');
      return;
    }

    final port = int.tryParse(_developerPortController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _developerError = '端口必须在 1 到 65535 之间。');
      return;
    }

    setState(() {
      _developerLoading = true;
      _developerTargetEnabled = true;
      _developerError = null;
      _developerLinks = const [];
    });

    try {
      final session = await provider.enableDeveloperMode(
        port: port,
        token: _developerTokenController.text.trim(),
      );
      final links = await provider.developerWorkspaceLinks(session);
      if (!mounted) {
        return;
      }
      setState(() {
        _developerSession = session;
        _developerLinks = links;
        _developerTokenController.text = session.token ?? '';
        _developerLoading = false;
        _developerTargetEnabled = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _developerError = error;
        _developerLoading = false;
        _developerTargetEnabled = null;
      });
    }
  }

  Future<void> _initializeDeveloperMode() async {
    final provider = _developerProvider;
    if (provider == null) return;
    try {
      if (provider
          case final DeveloperWorkspacePreferenceProvider preferences) {
        final preference = await preferences.loadDeveloperWorkspacePreference();
        if (!mounted) return;
        _developerPortController.text = preference.port.toString();
        _developerTokenController.text = preference.token;
      }
      await _refreshDeveloperMode();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _developerError = error;
        _developerLoading = false;
      });
    }
  }

  Future<void> _refreshDeveloperMode() async {
    final provider = _developerProvider;
    if (provider == null) return;
    try {
      final session = await provider.developerModeStatus();
      final links = session.enabled
          ? await provider.developerWorkspaceLinks(session)
          : const <Uri>[];
      if (!mounted) return;
      setState(() {
        _developerSession = session.enabled ? session : null;
        _developerLinks = links;
        _developerLoading = false;
        if (session.port != null) {
          _developerPortController.text = session.port.toString();
        }
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _developerError = error;
        _developerLoading = false;
      });
    }
  }

  Future<void> _disableDeveloperMode() async {
    final provider = _developerProvider;
    if (provider == null) {
      return;
    }

    setState(() {
      _developerLoading = true;
      _developerTargetEnabled = false;
      _developerError = null;
    });
    try {
      await provider.disableDeveloperMode();
      if (!mounted) {
        return;
      }
      setState(() {
        _developerSession = null;
        _developerLinks = const [];
        _developerLoading = false;
        _developerTargetEnabled = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _developerError = error;
        _developerLoading = false;
        _developerTargetEnabled = null;
      });
    }
  }

  void _openDeveloperWorkspace(Uri workspaceUri) {
    final localUri = workspaceUri.replace(host: '127.0.0.1');
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => DeveloperWorkspacePage(workspaceUri: localUri),
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
                      '分享本机游戏库',
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
                    decoration: const InputDecoration(
                      labelText: '端口',
                      hintText: '16668',
                    ),
                  );
                  final token = TextField(
                    controller: _tokenController,
                    enabled: !enabled && !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Token（留空则无需鉴权）',
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
                Text('游戏库分享不可用：${_error ?? widget.controller.shareError}')
              else if (!enabled)
                const Text('开启后提供分页搜索和游戏包下载接口。Token 留空时局域网设备无需鉴权。')
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
                              const Text('未发现可用局域网地址。')
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
                                    tooltip: '复制游戏源配置',
                                    onPressed: config == null
                                        ? null
                                        : () => _copyConfig(config),
                                    icon: const Icon(Icons.copy),
                                  ),
                                  onTap: () =>
                                      setState(() => _selectedLink = link),
                                ),
                            const Text('扫码会同时配置 Host 和 Token；下载仍会经过本机游戏包安全校验。'),
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
        if (port == null) throw const FormatException('端口必须是整数');
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('游戏源配置已复制')));
  }
}

class _DeveloperModeSection extends StatelessWidget {
  const _DeveloperModeSection({
    required this.providerAvailable,
    required this.portController,
    required this.tokenController,
    required this.loading,
    required this.targetEnabled,
    required this.session,
    required this.links,
    required this.error,
    required this.onEnable,
    required this.onDisable,
    required this.onOpenWorkspace,
  });

  final bool providerAvailable;
  final TextEditingController portController;
  final TextEditingController tokenController;
  final bool loading;
  final bool? targetEnabled;
  final DeveloperSession? session;
  final List<Uri> links;
  final Object? error;
  final Future<void> Function() onEnable;
  final Future<void> Function() onDisable;
  final ValueChanged<Uri> onOpenWorkspace;

  @override
  Widget build(BuildContext context) {
    final enabled = session?.enabled ?? false;
    final selectedLink = links.isEmpty ? null : links.first;
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
                    '开发者模式',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Switch(
                  value: targetEnabled ?? enabled,
                  onChanged: providerAvailable && !loading
                      ? (value) => unawaited(value ? onEnable() : onDisable())
                      : null,
                ),
              ],
            ),
            if (loading) const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final port = TextField(
                  controller: portController,
                  enabled: providerAvailable && !enabled && !loading,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    hintText: '16666',
                  ),
                );
                final token = TextField(
                  controller: tokenController,
                  enabled: providerAvailable && !enabled && !loading,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    hintText: '留空则复用已保存值',
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
              const Text('当前 Go Core Provider 不支持开发者通道。')
            else if (error != null)
              Text('开发者模式不可用：${_developerErrorMessage(error)}')
            else if (loading)
              Text(targetEnabled == false ? '正在关闭开发者通道…' : '正在启动开发者通道并准备工作区地址…')
            else if (!enabled)
              const Text(
                '开发者通道独立监听指定端口；端口、Token 和工作区链接会持久保存，不会重启当前 Go Core 或中断游戏会话。',
              )
            else
              _DeveloperLinks(
                session: session!,
                links: links,
                qrLink: selectedLink,
                onOpenWorkspace: onOpenWorkspace,
              ),
          ],
        ),
      ),
    );
  }
}

class _DeveloperLinks extends StatefulWidget {
  const _DeveloperLinks({
    required this.session,
    required this.links,
    required this.qrLink,
    required this.onOpenWorkspace,
  });

  final DeveloperSession session;
  final List<Uri> links;
  final Uri? qrLink;
  final ValueChanged<Uri> onOpenWorkspace;

  @override
  State<_DeveloperLinks> createState() => _DeveloperLinksState();
}

class _DeveloperLinksState extends State<_DeveloperLinks> {
  Uri? _selectedLink;

  @override
  void initState() {
    super.initState();
    _selectedLink = widget.qrLink;
  }

  @override
  void didUpdateWidget(covariant _DeveloperLinks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedLink == null || !widget.links.contains(_selectedLink)) {
      _selectedLink = widget.qrLink;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedLink = _selectedLink;
    return LayoutBuilder(
      builder: (context, constraints) {
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已开启，token 尾号 ${widget.session.tokenHint ?? '------'}'),
            const SizedBox(height: 8),
            if (selectedLink != null) ...[
              FilledButton.icon(
                onPressed: () => widget.onOpenWorkspace(selectedLink),
                icon: const Icon(Icons.code),
                label: const Text('打开工作区'),
              ),
              const SizedBox(height: 12),
            ],
            if (widget.links.isEmpty)
              const Text('未发现可用局域网地址。')
            else
              for (final link in widget.links)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: link == selectedLink
                        ? const Color(0xffdcebe5)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        link == selectedLink
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(link.host),
                      subtitle: SelectableText(
                        link.toString(),
                        style: const TextStyle(fontFamily: 'Consolas'),
                      ),
                      trailing: IconButton(
                        tooltip: '复制开发者链接',
                        onPressed: () => _copyLink(context, link),
                        icon: const Icon(Icons.copy),
                      ),
                      onTap: () => setState(() => _selectedLink = link),
                    ),
                  ),
                ),
            const Text('点击地址可切换二维码。关闭开发者模式后当前地址立即失效。'),
            if (Theme.of(context).platform == TargetPlatform.android) ...[
              const SizedBox(height: 6),
              Text(
                'Android 会持续披露开发者模式前台服务，并在后台或锁屏时保持工作区服务；'
                '启动游戏等需要可见页面的操作会返回明确的不可用状态。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        );
        final qr = selectedLink == null
            ? null
            : ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(data: selectedLink.toString(), size: 150),
                ),
              );
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

  Future<void> _copyLink(BuildContext context, Uri link) async {
    await Clipboard.setData(ClipboardData(text: link.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('开发者链接已复制')));
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
                      'Go Core',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '重新检查 Go Core',
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
              title: const Text('服务地址'),
              subtitle: SelectableText(endpoint.toString()),
            ),
            if (status != null)
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text('Core ${status.coreVersion}'),
                subtitle: Text('启动于 ${_formatTimestamp(status.startedAt)}'),
              ),
            if (requestId != null)
              ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('请求 ID'),
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
        label: '正在检查',
        message: '正在连接本机 Go Core。',
        icon: Icons.sync,
        color: Theme.of(context).colorScheme.primary,
      );
    }

    switch (result?.availability) {
      case GoCoreAvailability.online:
        return const _StatusPresentation(
          label: '在线',
          message: 'Go Core 连接正常。',
          icon: Icons.check_circle_outline,
          color: Color(0xff287d3c),
        );
      case GoCoreAvailability.offline:
        return _StatusPresentation(
          label: '离线',
          message: result!.message,
          icon: Icons.cloud_off_outlined,
          color: const Color(0xffa35b00),
        );
      case GoCoreAvailability.error:
        return _StatusPresentation(
          label: '错误',
          message: result!.message,
          icon: Icons.error_outline,
          color: const Color(0xffb3261e),
        );
      case null:
        return const _StatusPresentation(
          label: '尚未检查',
          message: '点击刷新按钮检查 Go Core。',
          icon: Icons.help_outline,
          color: Colors.grey,
        );
    }
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const GradientIcon(icon: Icons.hub_rounded, size: 54, iconSize: 27),
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
                  const Text(
                    '局域网优先的 HTML 游戏平台 · 正式版 · 构建 $playmeshBuildNumber',
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '查看本次更新',
              onPressed: () => _showReleaseNotes(context),
              icon: const Icon(Icons.new_releases_outlined),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showReleaseNotes(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Playmesh $playmeshVersion 更新'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in playmeshReleaseHighlights)
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
                        Expanded(child: Text(item)),
                      ],
                    ),
                  ),
                Text(
                  '构建 $playmeshBuildNumber',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

String _formatTimestamp(DateTime timestamp) {
  final local = timestamp.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');

  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}';
}

String _developerErrorMessage(Object? error) => switch (error) {
  FormatException(:final message) => message,
  StateError(:final message) => message,
  _ => error.toString(),
};
