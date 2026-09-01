import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/game_web/game_join_coordinator.dart';
import '../../core/localization/playmesh_localization.dart';
import 'game_invitation_scanner_page.dart';

const gameInvitationScanJoiningOverlayKey = ValueKey(
  'game-invitation-scan-joining-overlay',
);

typedef GameInvitationPrepare =
    Future<RemoteGameLaunch> Function(
      String raw, {
      required GameJoinPreparationService coordinator,
      required GameJoinContext joinContext,
    });

typedef GameInvitationScanAndPrepare =
    Future<RemoteGameLaunch?> Function(
      BuildContext context, {
      required GameJoinPreparationService coordinator,
      required GameJoinContext joinContext,
      ValueChanged<String>? onScanned,
    });

/// 扫码、手工输入以及 LAN/Relay 邀请共同使用的唯一链接准备入口。
Future<RemoteGameLaunch> prepareGameInvitation(
  String raw, {
  required GameJoinPreparationService coordinator,
  required GameJoinContext joinContext,
}) {
  return coordinator.prepareLink(raw.trim(), context: joinContext);
}

/// 两个 App 扫码入口的唯一“采集二维码 -> 预检邀请”调用链。
Future<RemoteGameLaunch?> scanAndPrepareGameInvitation(
  BuildContext context, {
  required GameJoinPreparationService coordinator,
  required GameJoinContext joinContext,
  ValueChanged<String>? onScanned,
}) async {
  final raw = await Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      settings: const RouteSettings(name: GameInvitationScannerPage.routeName),
      builder: (_) => const GameInvitationScannerPage(),
    ),
  );
  if (raw == null || !context.mounted) return null;
  final normalized = raw.trim();
  if (normalized.isEmpty) return null;
  onScanned?.call(normalized);
  return runGameInvitationScanPreparation(
    context,
    () => prepareGameInvitation(
      normalized,
      coordinator: coordinator,
      joinContext: joinContext,
    ),
  );
}

/// 扫码页退出后，在执行邀请预检前先显示一帧根级阻塞遮罩。
///
/// 首页与“加入对局”页共同经过这里。遮罩只覆盖邀请预检；预检完成后先关闭遮罩，
/// 再由调用方进入远程对局，避免把根级遮罩带到新页面并阻塞整局操作。
Future<T> runGameInvitationScanPreparation<T>(
  BuildContext context,
  Future<T> Function() operation,
) async {
  final joiningLabel = context.tr('join.joining');
  final barrierColor = Theme.of(context).colorScheme.scrim.withAlpha(150);
  final dialogBuilt = Completer<BuildContext>();
  final dialogClosed = showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierLabel: joiningLabel,
    barrierColor: barrierColor,
    transitionDuration: Duration.zero,
    pageBuilder: (dialogContext, _, _) {
      if (!dialogBuilt.isCompleted) dialogBuilt.complete(dialogContext);
      return PopScope<void>(
        key: gameInvitationScanJoiningOverlayKey,
        canPop: false,
        child: GameInvitationJoiningOverlay(
          label: joiningLabel,
          showBarrier: false,
        ),
      );
    },
  );

  final dialogContext = await dialogBuilt.future;
  // 不让后续网络预检占用遮罩首次绘制前的时间片。
  await WidgetsBinding.instance.endOfFrame;
  try {
    return await operation();
  } finally {
    if (dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    await dialogClosed;
  }
}

/// 扫码与手工加入共用的全页“正在加入”视觉和无障碍语义。
class GameInvitationJoiningOverlay extends StatelessWidget {
  const GameInvitationJoiningOverlay({
    super.key,
    required this.label,
    this.showBarrier = true,
  });

  final String label;
  final bool showBarrier;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BlockSemantics(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (showBarrier)
                ModalBarrier(
                  dismissible: false,
                  color: colors.scrim.withAlpha(150),
                ),
              SafeArea(
                minimum: const EdgeInsets.all(24),
                child: Card(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          label,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
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
