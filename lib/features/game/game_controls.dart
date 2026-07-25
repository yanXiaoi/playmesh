import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.onShare,
    this.secondaryActions = const [],
  });

  final String backTooltip;
  final VoidCallback onBack;
  final VoidCallback onReload;
  final bool showPerformance;
  final VoidCallback onTogglePerformance;
  final VoidCallback onEnterFullscreen;
  final VoidCallback onExitFullscreen;
  final VoidCallback? onShare;
  final List<GameToolAction> secondaryActions;

  @override
  State<GameToolDock> createState() => _GameToolDockState();
}

class _GameToolDockState extends State<GameToolDock> {
  static const _dockWidth = 48.0;
  static const _menuWidth = 220.0;
  Offset? _offset;
  bool _expanded = false;
  bool _menuVisible = false;

  int get _buttonCount =>
      6 +
      (widget.onShare == null ? 0 : 1) +
      (widget.secondaryActions.isEmpty ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
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
        final menuHeight = min(
          widget.secondaryActions.length * 52.0,
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
                  color: const Color(0xb8121720),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: IconTheme(
                    data: const IconThemeData(color: Colors.white),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
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
                  onTap: () => setState(() => _menuVisible = false),
                ),
              ),
              Positioned(
                left: menuLeft,
                top: menuTop,
                width: _menuWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: menuHeight),
                  child: _GameActionMenu(
                    actions: widget.secondaryActions,
                    onSelected: (action) {
                      setState(() => _menuVisible = false);
                      action.onPressed();
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
    return IconButton(
      tooltip: '展开游戏工具',
      onPressed: () => setState(() {
        _expanded = true;
        _menuVisible = false;
      }),
      icon: const Icon(Icons.sports_esports_outlined),
    );
  }

  Widget _expandedDock({required Axis axis, required double viewportExtent}) {
    final buttons = <Widget>[
      IconButton(
        tooltip: '收纳游戏工具',
        onPressed: () => setState(() {
          _expanded = false;
          _menuVisible = false;
        }),
        icon: const Icon(Icons.unfold_less),
      ),
      IconButton(
        tooltip: widget.backTooltip,
        onPressed: widget.onBack,
        icon: const Icon(Icons.arrow_back),
      ),
      IconButton(
        tooltip: '刷新游戏',
        onPressed: widget.onReload,
        icon: const Icon(Icons.refresh),
      ),
      if (widget.onShare case final onShare?)
        IconButton(
          tooltip: '二维码与链接',
          onPressed: onShare,
          icon: const Icon(Icons.qr_code_2_outlined),
        ),
      IconButton(
        tooltip: widget.showPerformance ? '隐藏性能信息' : '显示性能信息',
        onPressed: widget.onTogglePerformance,
        icon: Icon(
          Icons.speed,
          color: widget.showPerformance
              ? Colors.lightGreenAccent
              : Colors.white54,
        ),
      ),
      IconButton(
        tooltip: '进入全屏',
        onPressed: widget.onEnterFullscreen,
        icon: const Icon(Icons.fullscreen),
      ),
      IconButton(
        tooltip: '退出全屏',
        onPressed: widget.onExitFullscreen,
        icon: const Icon(Icons.fullscreen_exit),
      ),
      if (widget.secondaryActions.isNotEmpty)
        IconButton(
          tooltip: '更多游戏操作',
          icon: const Icon(Icons.more_vert),
          onPressed: () => setState(() => _menuVisible = !_menuVisible),
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
}

class _GameActionMenu extends StatelessWidget {
  const _GameActionMenu({required this.actions, required this.onSelected});

  final List<GameToolAction> actions;
  final ValueChanged<GameToolAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('game-action-menu'),
      color: const Color(0xff20242b),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      elevation: 12,
      shadowColor: Colors.black,
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Color(0xfff4f7fb),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        child: IconTheme(
          data: const IconThemeData(color: Color(0xfff4f7fb)),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions)
                  InkWell(
                    onTap: () => onSelected(action),
                    child: SizedBox(
                      height: 52,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(action.icon),
                            const SizedBox(width: 12),
                            Text(action.label),
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
    return Material(
      color: const Color(0xff20242b),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
          child: DefaultTextStyle(
            style: const TextStyle(color: Color(0xffe8edf4), height: 1.45),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
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
                          labelStyle: const TextStyle(color: Color(0xfff4f7fb)),
                          backgroundColor: const Color(0xff343b46),
                          side: const BorderSide(color: Color(0xff596272)),
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
    return Material(
      color: const Color(0xb8000000),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xff17191d),
              border: Border.all(color: const Color(0xff596272)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: IconTheme(
                    data: const IconThemeData(color: Color(0xfff4f7fb)),
                    child: Row(
                      children: [
                        const SizedBox(width: 14),
                        const Icon(
                          Icons.receipt_long_outlined,
                          color: Colors.lightGreenAccent,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            '运行日志',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '复制最近日志',
                          onPressed: logs.isEmpty
                              ? null
                              : () => _copyLogs(context),
                          icon: const Icon(Icons.copy_all_outlined),
                        ),
                        IconButton(
                          tooltip: '清空日志',
                          onPressed: logs.isEmpty ? null : onClear,
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                        IconButton(
                          tooltip: '关闭运行日志',
                          onPressed: onClose,
                          icon: const Icon(Icons.close),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xff596272)),
                Expanded(
                  child: logs.isEmpty
                      ? const Center(
                          child: Text(
                            '等待 console 输出...',
                            style: TextStyle(color: Color(0xffa7b0bd)),
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制最近 ${logs.length} 条日志')));
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
