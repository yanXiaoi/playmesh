import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PlaymeshBackIntent extends Intent {
  const PlaymeshBackIntent();
}

class PlaymeshOpenMenuIntent extends Intent {
  const PlaymeshOpenMenuIntent();
}

class PlaymeshFocusSearchIntent extends Intent {
  const PlaymeshFocusSearchIntent();
}

abstract final class PlaymeshShortcutRegistry {
  static const Map<ShortcutActivator, Intent> shortcuts = {
    SingleActivator(LogicalKeyboardKey.escape): PlaymeshBackIntent(),
    SingleActivator(LogicalKeyboardKey.browserBack): PlaymeshBackIntent(),
    SingleActivator(LogicalKeyboardKey.goBack): PlaymeshBackIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonB): PlaymeshBackIntent(),
    SingleActivator(LogicalKeyboardKey.contextMenu): PlaymeshOpenMenuIntent(),
    SingleActivator(LogicalKeyboardKey.f10): PlaymeshOpenMenuIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonStart):
        PlaymeshOpenMenuIntent(),
    SingleActivator(LogicalKeyboardKey.keyF, control: true):
        PlaymeshFocusSearchIntent(),
    SingleActivator(LogicalKeyboardKey.keyF, meta: true):
        PlaymeshFocusSearchIntent(),
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };
}

class PlaymeshFocusPolicy extends ReadingOrderTraversalPolicy {
  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final moved = super.inDirection(currentNode, direction);
    if (moved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = primaryFocus?.context;
        if (context != null && context.mounted) {
          Scrollable.ensureVisible(
            context,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        }
      });
    }
    return moved;
  }
}

class PlaymeshFocusRestorationController {
  final Map<String, FocusNode> _nodes = {};
  final Map<String, VoidCallback> _listeners = {};
  String? _lastFocusedId;

  String? get lastFocusedId => _lastFocusedId;

  void register(String stableId, FocusNode node) {
    final existing = _nodes[stableId];
    if (identical(existing, node)) return;
    if (existing != null) {
      final listener = _listeners.remove(stableId);
      if (listener != null) existing.removeListener(listener);
    }
    _nodes[stableId] = node;
    void listener() {
      if (node.hasFocus) _lastFocusedId = stableId;
    }

    _listeners[stableId] = listener;
    node.addListener(listener);
  }

  void unregister(String stableId, FocusNode node) {
    if (!identical(_nodes[stableId], node)) return;
    _nodes.remove(stableId);
    final listener = _listeners.remove(stableId);
    if (listener != null) node.removeListener(listener);
  }

  bool hasFocus(String stableId) => _nodes[stableId]?.hasFocus ?? false;

  void restore({
    String? preferredId,
    Iterable<String> fallbackIds = const [],
    FocusNode? fallback,
  }) {
    FocusNode? target;
    final ids = <String?>[preferredId, _lastFocusedId, ...fallbackIds];
    for (final id in ids) {
      final candidate = id == null ? null : _nodes[id];
      if (_canRestore(candidate)) {
        target = candidate;
        break;
      }
    }
    if (target == null && _canRestore(fallback)) target = fallback;
    if (target == null) return;
    final selectedTarget = target;
    selectedTarget.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = selectedTarget.context;
      if (context != null && context.mounted) {
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 120),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  void dispose() {
    for (final entry in _nodes.entries) {
      final listener = _listeners[entry.key];
      if (listener != null) entry.value.removeListener(listener);
    }
    _nodes.clear();
    _listeners.clear();
  }

  bool _canRestore(FocusNode? node) {
    final context = node?.context;
    return node != null &&
        node.canRequestFocus &&
        context != null &&
        context.mounted;
  }
}
