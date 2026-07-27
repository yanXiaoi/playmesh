import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/playmesh_localization.dart';
import '../../ui/focus/playmesh_shortcuts.dart';

class GameToolAction {
  const GameToolAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// 游戏容器用来控制悬浮工具区的短生命周期控制器。
///
/// 控制器不保存位置或展开状态；运行时重建后始终回到默认收起状态。
class GameToolDockController {
  _GameToolDockState? _state;

  bool get isMoving => _state?._moving ?? false;

  void openTools() => _state?._openTools();

  bool showFromSdk() => _state?._showFromSdk() ?? false;

  bool hideFromSdk() => _state?._hideFromSdk() ?? false;

  void beginMoveMode() => _state?._beginMoveMode();

  bool closeTopLayer() => _state?._closeTopLayer() ?? false;

  void restoreFocus() => _state?._restoreDockFocus();

  KeyEventResult handleMoveKey(KeyEvent event) {
    return _state?._handleMoveKey(event) ?? KeyEventResult.ignored;
  }

  void _attach(_GameToolDockState state) {
    _state = state;
  }

  void _detach(_GameToolDockState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// 让游戏运行面统一接管遥控器、键盘和手柄快捷键。
///
/// 移动悬浮球时方向键、确认键和返回键由移动模式优先消费；其余状态下，
/// F10/Menu 打开工具，返回键交给页面按“面板 -> 工具 -> 页面”的顺序处理。
class GameRuntimeShortcutScope extends StatefulWidget {
  const GameRuntimeShortcutScope({
    super.key,
    required this.controller,
    required this.onBack,
    required this.onOpenTools,
    required this.onMoveTools,
    required this.child,
  });

  final GameToolDockController controller;
  final VoidCallback onBack;
  final VoidCallback onOpenTools;
  final VoidCallback onMoveTools;
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
    if (widget.controller.handleMoveKey(event) == KeyEventResult.handled) {
      return true;
    }
    final intent = PlaymeshShortcutRegistry.resolveRawKeyEvent(
      event,
      altPressed: HardwareKeyboard.instance.isAltPressed,
    );
    if (intent is PlaymeshOpenMenuIntent ||
        intent is PlaymeshOpenGameToolsIntent) {
      widget.onOpenTools();
      return true;
    }
    if (intent is PlaymeshMoveGameToolsIntent) {
      widget.onMoveTools();
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
              widget.onOpenTools();
              return null;
            },
          ),
          PlaymeshOpenGameToolsIntent:
              CallbackAction<PlaymeshOpenGameToolsIntent>(
                onInvoke: (_) {
                  widget.onOpenTools();
                  return null;
                },
              ),
          PlaymeshMoveGameToolsIntent:
              CallbackAction<PlaymeshMoveGameToolsIntent>(
                onInvoke: (_) {
                  widget.onMoveTools();
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
            return widget.controller.handleMoveKey(event);
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// App 游戏容器共用的悬浮工具区。
///
/// 工具区显式设置前景色和背景色，避免被游戏页面或 App 主题污染。
class GameToolDock extends StatefulWidget {
  const GameToolDock({
    super.key,
    required this.backTooltip,
    required this.onBack,
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

  final String backTooltip;
  final VoidCallback onBack;
  final VoidCallback onReload;
  final bool showPerformance;
  final VoidCallback onTogglePerformance;
  final VoidCallback onEnterFullscreen;
  final VoidCallback onExitFullscreen;
  final Object? resetKey;
  final VoidCallback? onShare;
  final VoidCallback? onOpenLogs;
  final List<GameToolAction> secondaryActions;
  final GameToolDockController? controller;

  @override
  State<GameToolDock> createState() => _GameToolDockState();
}

class _GameToolDockState extends State<GameToolDock> {
  static const _dockWidth = 48.0;
  static const _menuWidth = 220.0;
  static const _moveStep = 16.0;

  final FocusNode _collapsedFocus = FocusNode(
    debugLabel: 'game-tools-collapsed',
  );
  final FocusNode _collapseFocus = FocusNode(debugLabel: 'game-tools-collapse');
  final FocusNode _backFocus = FocusNode(debugLabel: 'game-tools-back');
  final FocusNode _reloadFocus = FocusNode(debugLabel: 'game-tools-reload');
  final FocusNode _shareFocus = FocusNode(debugLabel: 'game-tools-share');
  final FocusNode _logsFocus = FocusNode(debugLabel: 'game-tools-logs');
  final FocusNode _enterFullscreenFocus = FocusNode(
    debugLabel: 'game-tools-enter-fullscreen',
  );
  final FocusNode _exitFullscreenFocus = FocusNode(
    debugLabel: 'game-tools-exit-fullscreen',
  );
  final FocusNode _moreFocus = FocusNode(debugLabel: 'game-tools-more');
  final List<FocusNode> _menuFocusNodes = [];

  Offset? _offset;
  Offset? _resolvedOffset;
  Offset? _moveOrigin;
  BoxConstraints? _lastConstraints;
  double _lastTopInset = 0;
  double _lastBottomInset = 0;
  bool _expanded = false;
  bool _menuVisible = false;
  bool _moving = false;
  bool _visible = true;
  bool _openedFromSdk = false;
  FocusNode? _lastDockFocus;

  List<FocusNode> get _dockFocusNodes => [
    _collapsedFocus,
    _collapseFocus,
    _backFocus,
    _reloadFocus,
    _shareFocus,
    _logsFocus,
    _enterFullscreenFocus,
    _exitFullscreenFocus,
    _moreFocus,
  ];

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _syncMenuFocusNodes();
    for (final node in _dockFocusNodes) {
      node.addListener(_rememberDockFocus);
    }
  }

  @override
  void didUpdateWidget(covariant GameToolDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    _syncMenuFocusNodes();
    if (oldWidget.resetKey != widget.resetKey) {
      _expanded = false;
      _menuVisible = false;
      _moving = false;
      _visible = true;
      _openedFromSdk = false;
      _offset = null;
      _moveOrigin = null;
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    for (final node in _dockFocusNodes) {
      node
        ..removeListener(_rememberDockFocus)
        ..dispose();
    }
    for (final node in _menuFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _syncMenuFocusNodes() {
    final actionCount = widget.secondaryActions.length + 1;
    while (_menuFocusNodes.length < actionCount) {
      _menuFocusNodes.add(
        FocusNode(debugLabel: 'game-tools-menu-${_menuFocusNodes.length}'),
      );
    }
    while (_menuFocusNodes.length > actionCount) {
      _menuFocusNodes.removeLast().dispose();
    }
  }

  void _rememberDockFocus() {
    for (final node in _dockFocusNodes) {
      if (node.hasFocus) {
        _lastDockFocus = node;
        return;
      }
    }
  }

  int get _buttonCount =>
      6 +
      (widget.onShare == null ? 0 : 1) +
      (widget.onOpenLogs == null ? 0 : 1);

  List<GameToolAction> _menuActions(BuildContext context) => [
    ...widget.secondaryActions,
    GameToolAction(
      icon: Icons.speed,
      label: widget.showPerformance
          ? context.tr('game.performance_hide')
          : context.tr('game.performance_show'),
      onPressed: widget.onTogglePerformance,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final colorScheme = Theme.of(context).colorScheme;
        final menuActions = _menuActions(context);
        final animationDuration = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180);
        final topInset = MediaQuery.paddingOf(context).top + 12;
        final bottomInset = MediaQuery.paddingOf(context).bottom + 12;
        final availableHeight = max(
          _dockWidth,
          constraints.maxHeight - topInset - bottomInset,
        );
        final expandedExtent = _dockWidth * _buttonCount;
        final horizontal =
            _expanded &&
            availableHeight < expandedExtent &&
            constraints.maxWidth >= expandedExtent + 24;
        final dockSize = !_expanded
            ? const Size(_dockWidth, _dockWidth)
            : horizontal
            ? Size(expandedExtent, _dockWidth)
            : Size(_dockWidth, min(expandedExtent, availableHeight));
        final fallback = Offset(
          constraints.maxWidth - dockSize.width - 12,
          topInset,
        );
        final offset = _clampOffset(
          _offset ?? fallback,
          constraints,
          dockSize,
          topInset,
          bottomInset,
        );
        _resolvedOffset = offset;
        _lastConstraints = constraints;
        _lastTopInset = topInset;
        _lastBottomInset = bottomInset;
        final menuHeight = min(
          menuActions.length * 52.0,
          max(52.0, constraints.maxHeight - 16),
        );
        final menuLeft =
            (horizontal
                    ? offset.dx + dockSize.width - _menuWidth
                    : offset.dx - _menuWidth - 8)
                .clamp(8.0, max(8.0, constraints.maxWidth - _menuWidth - 8))
                .toDouble();
        final menuTop =
            (horizontal ? offset.dy + dockSize.height + 8 : offset.dy)
                .clamp(8.0, max(8.0, constraints.maxHeight - menuHeight - 8))
                .toDouble();
        return Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              child: GestureDetector(
                onPanUpdate: (details) {
                  if (_moving) return;
                  setState(() {
                    _offset = _clampOffset(
                      offset + details.delta,
                      constraints,
                      dockSize,
                      topInset,
                      bottomInset,
                    );
                  });
                },
                child: Material(
                  color: _moving
                      ? colorScheme.tertiaryContainer
                      : colorScheme.inverseSurface.withAlpha(240),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: _moving
                          ? colorScheme.tertiary
                          : colorScheme.primary,
                      width: _moving ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: IconTheme(
                    data: IconThemeData(
                      color: _moving
                          ? colorScheme.onTertiaryContainer
                          : colorScheme.onInverseSurface,
                    ),
                    child: AnimatedSize(
                      duration: animationDuration,
                      curve: Curves.easeOutCubic,
                      child: AnimatedSwitcher(
                        duration: animationDuration,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.92,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: _expanded
                            ? KeyedSubtree(
                                key: const ValueKey('expanded-game-tools'),
                                child: _expandedDock(
                                  axis: horizontal
                                      ? Axis.horizontal
                                      : Axis.vertical,
                                  viewportExtent: horizontal
                                      ? dockSize.width
                                      : dockSize.height,
                                ),
                              )
                            : KeyedSubtree(
                                key: const ValueKey('collapsed-game-tools'),
                                child: _collapsedDock(),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_menuVisible) ...[
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('game-action-menu-dismiss-area'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeMenu,
                ),
              ),
              Positioned(
                left: menuLeft,
                top: menuTop,
                width: _menuWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: menuHeight),
                  child: _GameActionMenu(
                    actions: menuActions,
                    focusNodes: _menuFocusNodes,
                    onSelected: (action) {
                      _lastDockFocus = _moreFocus;
                      _runToolAction(action.onPressed);
                    },
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _collapsedDock() {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: _moving,
      label: _moving
          ? context.tr('game.tools_move')
          : context.tr('game.tools_open'),
      child: IconButton(
        key: const Key('game-tool-dock-handle'),
        focusNode: _collapsedFocus,
        tooltip: _moving
            ? context.tr('game.tools_move')
            : context.tr('game.tools_open'),
        onPressed: _moving ? _ignoreMoveActivation : _openTools,
        icon: Icon(
          _moving ? Icons.open_with_rounded : Icons.sports_esports_outlined,
          color: _moving
              ? colorScheme.onTertiaryContainer
              : colorScheme.onInverseSurface,
        ),
      ),
    );
  }

  Widget _expandedDock({required Axis axis, required double viewportExtent}) {
    final buttons = <Widget>[
      IconButton(
        key: const Key('game-tool-collapse'),
        focusNode: _collapseFocus,
        tooltip: context.tr('game.tools_close'),
        onPressed: _collapseTools,
        icon: const Icon(Icons.unfold_less),
      ),
      IconButton(
        key: const Key('game-tool-back'),
        focusNode: _backFocus,
        tooltip: widget.backTooltip,
        onPressed: () => _runToolAction(widget.onBack),
        icon: const Icon(Icons.arrow_back),
      ),
      IconButton(
        key: const Key('game-tool-reload'),
        focusNode: _reloadFocus,
        tooltip: context.tr('game.reload'),
        onPressed: () => _runToolAction(widget.onReload),
        icon: const Icon(Icons.refresh),
      ),
      if (widget.onShare case final onShare?)
        IconButton(
          key: const Key('game-tool-share'),
          focusNode: _shareFocus,
          tooltip: context.tr('game.share'),
          onPressed: () {
            _lastDockFocus = _shareFocus;
            _runToolAction(onShare);
          },
          icon: const Icon(Icons.qr_code_2_outlined),
        ),
      if (widget.onOpenLogs case final onOpenLogs?)
        IconButton(
          key: const Key('game-tool-logs'),
          focusNode: _logsFocus,
          tooltip: context.tr('game.logs'),
          onPressed: () {
            _lastDockFocus = _logsFocus;
            _runToolAction(onOpenLogs);
          },
          icon: const Icon(Icons.receipt_long_outlined),
        ),
      IconButton(
        key: const Key('game-tool-enter-fullscreen'),
        focusNode: _enterFullscreenFocus,
        tooltip: context.tr('game.fullscreen_enter'),
        onPressed: () => _runToolAction(widget.onEnterFullscreen),
        icon: const Icon(Icons.fullscreen),
      ),
      IconButton(
        key: const Key('game-tool-exit-fullscreen'),
        focusNode: _exitFullscreenFocus,
        tooltip: context.tr('game.fullscreen_exit'),
        onPressed: () => _runToolAction(widget.onExitFullscreen),
        icon: const Icon(Icons.fullscreen_exit),
      ),
      IconButton(
        key: const Key('game-tool-more'),
        focusNode: _moreFocus,
        tooltip: context.tr('game.more_actions'),
        icon: const Icon(Icons.more_vert),
        onPressed: _toggleMenu,
      ),
    ];
    final dock = axis == Axis.horizontal
        ? Row(mainAxisSize: MainAxisSize.min, children: buttons)
        : Column(mainAxisSize: MainAxisSize.min, children: buttons);
    return SizedBox(
      width: axis == Axis.horizontal ? viewportExtent : _dockWidth,
      height: axis == Axis.vertical ? viewportExtent : _dockWidth,
      child: SingleChildScrollView(scrollDirection: axis, child: dock),
    );
  }

  Offset _clampOffset(
    Offset value,
    BoxConstraints constraints,
    Size dockSize,
    double topInset,
    double bottomInset,
  ) {
    final maxX = max(0.0, constraints.maxWidth - dockSize.width);
    final maxY = max(
      topInset,
      constraints.maxHeight - bottomInset - dockSize.height,
    );
    return Offset(
      value.dx.clamp(0.0, maxX).toDouble(),
      value.dy.clamp(topInset, maxY).toDouble(),
    );
  }

  void _openTools() {
    if (!mounted || _moving) return;
    setState(() {
      _visible = true;
      _expanded = true;
      _menuVisible = false;
      _openedFromSdk = false;
    });
    _requestFocus(_collapseFocus);
  }

  bool _showFromSdk() {
    if (!mounted) return false;
    setState(() {
      _visible = true;
      _expanded = true;
      _menuVisible = false;
      _moving = false;
      _openedFromSdk = true;
    });
    _requestFocus(_collapseFocus);
    return true;
  }

  bool _hideFromSdk() {
    if (!mounted) return false;
    setState(() {
      _visible = false;
      _expanded = false;
      _menuVisible = false;
      _moving = false;
      _openedFromSdk = false;
    });
    return true;
  }

  void _ignoreMoveActivation() {
    // 移动模式的确认键由 _handleMoveKey 保存位置，避免同时触发展开动作。
  }

  void _collapseTools() {
    if (!mounted) return;
    final hide = _openedFromSdk;
    setState(() {
      _expanded = false;
      _menuVisible = false;
      _visible = !hide;
      _openedFromSdk = false;
    });
    if (!hide) _requestFocus(_collapsedFocus);
  }

  void _runToolAction(VoidCallback action) {
    if (!mounted) return;
    final hide = _openedFromSdk;
    setState(() {
      _expanded = false;
      _menuVisible = false;
      _visible = !hide;
      _openedFromSdk = false;
    });
    action();
    if (!hide) _requestFocus(_collapsedFocus);
  }

  void _toggleMenu() {
    if (!mounted || _moving) return;
    _lastDockFocus = _moreFocus;
    if (_menuVisible) {
      _closeMenu();
      return;
    }
    setState(() => _menuVisible = true);
    if (_menuFocusNodes.isNotEmpty) {
      _requestFocus(_menuFocusNodes.first);
    }
  }

  void _closeMenu() {
    if (!mounted || !_menuVisible) return;
    setState(() => _menuVisible = false);
    _requestFocus(_moreFocus);
  }

  bool _closeTopLayer() {
    if (_moving) {
      _finishMove(commit: false);
      return true;
    }
    if (_menuVisible) {
      _closeMenu();
      return true;
    }
    if (_expanded) {
      _collapseTools();
      return true;
    }
    return false;
  }

  void _beginMoveMode() {
    if (!mounted) return;
    final origin = _resolvedOffset;
    if (origin == null) return;
    setState(() {
      _expanded = false;
      _menuVisible = false;
      _moving = true;
      _visible = true;
      _openedFromSdk = false;
      _moveOrigin = origin;
      _offset = origin;
    });
    _requestFocus(_collapsedFocus);
  }

  KeyEventResult _handleMoveKey(KeyEvent event) {
    if (!_moving || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.gameButtonB) {
      _finishMove(commit: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA) {
      _finishMove(commit: true);
      return KeyEventResult.handled;
    }
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => const Offset(-_moveStep, 0),
      LogicalKeyboardKey.arrowRight => const Offset(_moveStep, 0),
      LogicalKeyboardKey.arrowUp => const Offset(0, -_moveStep),
      LogicalKeyboardKey.arrowDown => const Offset(0, _moveStep),
      _ => null,
    };
    if (delta == null) return KeyEventResult.ignored;
    final constraints = _lastConstraints;
    final current = _offset ?? _resolvedOffset;
    if (constraints == null || current == null) return KeyEventResult.handled;
    setState(() {
      _offset = _clampOffset(
        current + delta,
        constraints,
        const Size(_dockWidth, _dockWidth),
        _lastTopInset,
        _lastBottomInset,
      );
    });
    return KeyEventResult.handled;
  }

  void _finishMove({required bool commit}) {
    if (!mounted || !_moving) return;
    setState(() {
      if (!commit) _offset = _moveOrigin;
      _moveOrigin = null;
      _moving = false;
    });
    _requestFocus(_collapsedFocus);
  }

  void _restoreDockFocus() {
    final target = _lastDockFocus;
    if (target != null && target.canRequestFocus && target.context != null) {
      _requestFocus(target);
      return;
    }
    _requestFocus(_expanded ? _collapseFocus : _collapsedFocus);
  }

  void _requestFocus(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.canRequestFocus || node.context == null) return;
      node.requestFocus();
    });
  }
}

class _GameActionMenu extends StatelessWidget {
  const _GameActionMenu({
    required this.actions,
    required this.focusNodes,
    required this.onSelected,
  });

  final List<GameToolAction> actions;
  final List<FocusNode> focusNodes;
  final ValueChanged<GameToolAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('game-action-menu'),
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      elevation: 4,
      child: DefaultTextStyle(
        style: TextStyle(
          color: colorScheme.onSurface,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        child: IconTheme(
          data: IconThemeData(color: colorScheme.onSurface),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var index = 0; index < actions.length; index++)
                  InkWell(
                    key: ValueKey('game-action-menu-item-$index'),
                    focusNode: focusNodes[index],
                    autofocus: index == 0,
                    onTap: () => onSelected(actions[index]),
                    child: SizedBox(
                      height: 52,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(actions[index].icon),
                            const SizedBox(width: 12),
                            Expanded(child: Text(actions[index].label)),
                          ],
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
                                  color: _logColor(level),
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

  static Color _logColor(String level) {
    return switch (level) {
      'error' => const Color(0xffff8a80),
      'warn' => const Color(0xffffd180),
      'debug' => const Color(0xff80cbc4),
      _ => const Color(0xffe5e7eb),
    };
  }
}
