import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/playmesh_localization.dart';
import '../../ui/focus/playmesh_shortcuts.dart';

class GameSidebarAction {
  const GameSidebarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// 游戏容器用来控制平台侧边栏的短生命周期控制器。
///
/// 控制器不持久化打开状态；运行时重建后始终保持关闭。
class GameSidebarController {
  _GameSidebarState? _state;

  bool get isOpen => _state?._open ?? false;

  void open() => _state?._openSidebar();

  bool showFromSdk() => _state?._showFromSdk() ?? false;

  bool hideFromSdk() => _state?._hideFromSdk() ?? false;

  bool closeTopLayer() => _state?._closeTopLayer() ?? false;

  void restoreFocus() => _state?._restoreSidebarFocus();

  void _attach(_GameSidebarState state) {
    _state = state;
  }

  void _detach(_GameSidebarState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// 让游戏运行面统一接管遥控器、键盘和手柄快捷键。
///
/// F10/Menu 打开侧边栏；返回键交给页面按“覆盖层 -> 侧边栏”的顺序处理，
/// 不允许直接离开游戏。
class GameRuntimeShortcutScope extends StatefulWidget {
  const GameRuntimeShortcutScope({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onOpenSidebar,
    required this.child,
  });

  final GameSidebarController controller;
  final VoidCallback onBack;
  final VoidCallback onOpenSidebar;
  final Widget child;

  @override
  State<GameRuntimeShortcutScope> createState() =>
      _GameRuntimeShortcutScopeState();
}

class _GameRuntimeShortcutScopeState extends State<GameRuntimeShortcutScope> {
  final Set<PhysicalKeyboardKey> _hardwareConsumedKeys = {};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    super.dispose();
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is KeyUpEvent) {
      _hardwareConsumedKeys.remove(event.physicalKey);
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final handled = _handleRuntimeHardwareKey(event);
    if (handled) _hardwareConsumedKeys.add(event.physicalKey);
    return handled;
  }

  bool _handleRuntimeHardwareKey(KeyEvent event) {
    final intent = PlaymeshShortcutRegistry.resolveRawKeyEvent(event);
    if (intent is PlaymeshOpenMenuIntent ||
        intent is PlaymeshOpenGameSidebarIntent) {
      widget.onOpenSidebar();
      return true;
    }
    if (intent is PlaymeshBackIntent) {
      widget.onBack();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: PlaymeshShortcutRegistry.shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          PlaymeshBackIntent: CallbackAction<PlaymeshBackIntent>(
            onInvoke: (_) {
              widget.onBack();
              return null;
            },
          ),
          PlaymeshOpenMenuIntent: CallbackAction<PlaymeshOpenMenuIntent>(
            onInvoke: (_) {
              widget.onOpenSidebar();
              return null;
            },
          ),
          PlaymeshOpenGameSidebarIntent:
              CallbackAction<PlaymeshOpenGameSidebarIntent>(
                onInvoke: (_) {
                  widget.onOpenSidebar();
                  return null;
                },
              ),
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (_hardwareConsumedKeys.contains(event.physicalKey)) {
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// App 游戏容器共用的平台侧边栏。
///
/// 侧边栏不提供常驻入口；只能由返回键、菜单快捷键或 SDK 打开。
class GameSidebar extends StatefulWidget {
  const GameSidebar({
    super.key,
    required this.backLabel,
    required this.onBack,
    required this.onContinue,
    required this.onReload,
    required this.showPerformance,
    required this.onTogglePerformance,
    required this.onEnterFullscreen,
    required this.onExitFullscreen,
    this.resetKey,
    this.onShare,
    this.onOpenLogs,
    this.secondaryActions = const [],
    this.controller,
  });

  final String backLabel;
  final VoidCallback onBack;
  final VoidCallback onContinue;
  final VoidCallback onReload;
  final bool showPerformance;
  final VoidCallback onTogglePerformance;
  final VoidCallback onEnterFullscreen;
  final VoidCallback onExitFullscreen;
  final Object? resetKey;
  final VoidCallback? onShare;
  final VoidCallback? onOpenLogs;
  final List<GameSidebarAction> secondaryActions;
  final GameSidebarController? controller;

  @override
  State<GameSidebar> createState() => _GameSidebarState();
}

class _GameSidebarState extends State<GameSidebar> {
  final FocusNode _continueFocus = FocusNode(
    debugLabel: 'game-sidebar-continue',
  );
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(covariant GameSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.resetKey != widget.resetKey) {
      _open = false;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _continueFocus.dispose();
    super.dispose();
  }

  List<GameSidebarAction> _additionalActions(BuildContext context) => [
    ...widget.secondaryActions,
    GameSidebarAction(
      icon: Icons.speed,
      label: widget.showPerformance
          ? context.tr('game.performance_hide')
          : context.tr('game.performance_show'),
      onPressed: widget.onTogglePerformance,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colorScheme = Theme.of(context).colorScheme;
        final portrait = constraints.maxHeight >= constraints.maxWidth;
        final width = min(
          constraints.maxWidth,
          portrait
              ? min(360.0, constraints.maxWidth * 0.88)
              : min(420.0, constraints.maxWidth * 0.46),
        );
        final animationDuration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220);
        return ExcludeFocus(
          excluding: !_open,
          child: ExcludeSemantics(
            excluding: !_open,
            child: IgnorePointer(
              ignoring: !_open,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: animationDuration,
                      opacity: _open ? 1 : 0,
                      child: GestureDetector(
                        key: const Key('game-sidebar-dismiss-area'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _closeSidebar,
                        child: ColoredBox(color: Colors.black.withAlpha(150)),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedSlide(
                      duration: animationDuration,
                      curve: Curves.easeOutCubic,
                      offset: _open ? Offset.zero : const Offset(1, 0),
                      child: SizedBox(
                        key: const Key('game-sidebar'),
                        width: width,
                        height: constraints.maxHeight,
                        child: Material(
                          color: colorScheme.surface,
                          elevation: 16,
                          child: SafeArea(
                            left: false,
                            child: _buildSidebar(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
          child: Row(
            children: [
              Icon(Icons.sports_esports_outlined, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.tr('game.sidebar_title'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colorScheme.outlineVariant),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _GameSidebarActionTile(
                key: const Key('game-sidebar-continue'),
                focusNode: _continueFocus,
                icon: Icons.play_arrow_rounded,
                label: context.tr('game.continue'),
                emphasized: true,
                onPressed: _closeSidebar,
              ),
              _GameSidebarActionTile(
                key: const Key('game-sidebar-reload'),
                icon: Icons.refresh,
                label: context.tr('game.reload'),
                onPressed: () => _runAction(widget.onReload),
              ),
              if (widget.onShare case final onShare?)
                _GameSidebarActionTile(
                  key: const Key('game-sidebar-share'),
                  icon: Icons.qr_code_2_outlined,
                  label: context.tr('game.share'),
                  onPressed: () => _runAction(onShare),
                ),
              if (widget.onOpenLogs case final onOpenLogs?)
                _GameSidebarActionTile(
                  key: const Key('game-sidebar-logs'),
                  icon: Icons.receipt_long_outlined,
                  label: context.tr('game.logs'),
                  onPressed: () => _runAction(onOpenLogs),
                ),
              _GameSidebarActionTile(
                key: const Key('game-sidebar-enter-fullscreen'),
                icon: Icons.fullscreen,
                label: context.tr('game.fullscreen_enter'),
                onPressed: () => _runAction(widget.onEnterFullscreen),
              ),
              _GameSidebarActionTile(
                key: const Key('game-sidebar-exit-fullscreen'),
                icon: Icons.fullscreen_exit,
                label: context.tr('game.fullscreen_exit'),
                onPressed: () => _runAction(widget.onExitFullscreen),
              ),
              for (final action in _additionalActions(context))
                _GameSidebarActionTile(
                  icon: action.icon,
                  label: action.label,
                  onPressed: () => _runAction(action.onPressed),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: colorScheme.outlineVariant),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _GameSidebarActionTile(
            key: const Key('game-sidebar-exit'),
            icon: Icons.exit_to_app,
            label: widget.backLabel,
            foregroundColor: colorScheme.error,
            onPressed: () => _runAction(widget.onBack),
          ),
        ),
      ],
    );
  }

  void _openSidebar() {
    if (!mounted || _open) return;
    setState(() {
      _open = true;
    });
    _requestFocus(_continueFocus);
  }

  bool _showFromSdk() {
    if (!mounted) return false;
    setState(() {
      _open = true;
    });
    _requestFocus(_continueFocus);
    return true;
  }

  bool _hideFromSdk() {
    if (!mounted) return false;
    _closeSidebar();
    return true;
  }

  void _runAction(VoidCallback action) {
    _closeSidebar(resumeGame: false);
    action();
  }

  void _closeSidebar({bool resumeGame = true}) {
    if (!mounted || !_open) return;
    setState(() {
      _open = false;
    });
    if (resumeGame) widget.onContinue();
  }

  bool _closeTopLayer() {
    if (_open) {
      _closeSidebar();
      return true;
    }
    return false;
  }

  void _restoreSidebarFocus() {
    if (_open) _requestFocus(_continueFocus);
  }

  void _requestFocus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.canRequestFocus || node.context == null) return;
      node.requestFocus();
    });
  }
}

class _GameSidebarActionTile extends StatelessWidget {
  const _GameSidebarActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.emphasized = false,
    this.foregroundColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool emphasized;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = foregroundColor ?? colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: emphasized ? colorScheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(icon, color: color),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: emphasized
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GameToolInfoSheet extends StatelessWidget {
  const GameToolInfoSheet({
    super.key,
    required this.title,
    required this.description,
    this.labels = const [],
  });

  final String title;
  final String description;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: DefaultTextStyle(
            style: TextStyle(color: colorScheme.onSurface, height: 1.45),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('game-info-close'),
                      autofocus: true,
                      tooltip: context.tr('common.close'),
                      onPressed: () =>
                          unawaited(Navigator.of(context).maybePop()),
                      icon: Icon(Icons.close, color: colorScheme.onSurface),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(description),
                if (labels.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final label in labels)
                        Chip(
                          label: Text(label),
                          labelStyle: TextStyle(
                            color: colorScheme.onSecondaryContainer,
                          ),
                          backgroundColor: colorScheme.secondaryContainer,
                          side: BorderSide(color: colorScheme.outlineVariant),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class GameRuntimeLogOverlay extends StatelessWidget {
  const GameRuntimeLogOverlay({
    super.key,
    required this.logs,
    required this.onClear,
    required this.onClose,
  });

  final List<Map<String, Object?>> logs;
  final VoidCallback onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.black.withAlpha(184),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: IconTheme(
                    data: IconThemeData(color: colorScheme.onSurface),
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.receipt_long_outlined,
                          color: Colors.lightGreenAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.tr('game.logs'),
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: context.tr('game.logs_copy'),
                          onPressed: logs.isEmpty
                              ? null
                              : () => _copyLogs(context),
                          icon: const Icon(Icons.copy_all_outlined),
                        ),
                        IconButton(
                          tooltip: context.tr('game.logs_clear'),
                          onPressed: logs.isEmpty ? null : onClear,
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                        IconButton(
                          key: const Key('game-runtime-log-close'),
                          autofocus: true,
                          tooltip: context.tr('game.logs_close'),
                          onPressed: onClose,
                          icon: const Icon(Icons.close),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: colorScheme.outlineVariant),
                Expanded(
                  child: logs.isEmpty
                      ? Center(
                          child: Text(
                            context.tr('game.logs_waiting'),
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.all(12),
                          itemCount: logs.length,
                          itemBuilder: (context, index) {
                            final event = logs[logs.length - index - 1];
                            final level = event['level']?.toString() ?? 'log';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText(
                                _formatLog(event),
                                style: TextStyle(
                                  color: _logColor(colorScheme, level),
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _logTime(Object? value) {
    final milliseconds = value is int
        ? value
        : int.tryParse(value?.toString() ?? '');
    if (milliseconds == null) return '--:--:--';
    final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Future<void> _copyLogs(BuildContext context) async {
    final text = logs.map(_formatLog).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.tr('game.logs_copied', arguments: {'count': logs.length}),
        ),
      ),
    );
  }

  static String _formatLog(Map<String, Object?> event) {
    final level = event['level']?.toString() ?? 'log';
    final eventType = event['eventType']?.toString();
    final filename = event['filename']?.toString();
    final line = event['line']?.toString();
    final column = event['column']?.toString();
    final stack = event['stack']?.toString();
    final kind = eventType == null || eventType == 'console'
        ? ''
        : ' [$eventType]';
    final location = filename == null || filename.isEmpty
        ? ''
        : ' ($filename${line == null ? '' : ':$line${column == null ? '' : ':$column'}'})';
    final message =
        '${_logTime(event['timestamp'])} '
        '[${event['source'] ?? 'game'}] [$level]$kind '
        '${event['message'] ?? ''}$location';
    if (stack == null || stack.isEmpty || message.contains(stack)) {
      return message;
    }
    return '$message\n$stack';
  }

  static Color _logColor(ColorScheme colorScheme, String level) {
    final dark = colorScheme.brightness == Brightness.dark;
    return switch (level) {
      'error' => dark ? const Color(0xffffb4ab) : const Color(0xffa91515),
      'warn' => dark ? const Color(0xffffd180) : const Color(0xff7a4600),
      'debug' => dark ? const Color(0xff80cbc4) : const Color(0xff00675f),
      _ => colorScheme.onSurface,
    };
  }
}
