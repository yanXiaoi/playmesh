import 'package:flutter/material.dart';

import '../../core/developer/developer_run_controller.dart';
import '../../core/game_package/game_asset_gateway.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import '../../core/game_sdk/sdk_feature_registry.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../models/game_summary.dart';
import 'local_game_web_view.dart';

class GameLauncher extends StatelessWidget {
  const GameLauncher({
    super.key,
    required this.game,
    required this.localUserId,
    required this.localNickname,
    this.bridge,
    this.resourceSource,
    this.developerResourceSession,
    this.appLanHost,
    this.onOpenSharePanel,
    this.onExitRequested,
    this.onNicknameUpdate,
    this.onSystemBackHandlerChanged,
    this.onJavaScriptExecutorChanged,
  });

  final GameSummary game;
  final String localUserId;
  final String localNickname;
  final GameSdkBridge? bridge;
  final GameWebResourceSource? resourceSource;
  final DeveloperResourceSession? developerResourceSession;
  final AppLanHost? appLanHost;
  final Future<void> Function()? onOpenSharePanel;
  final Future<void> Function()? onExitRequested;
  final Future<Object?> Function(Map<String, Object?> payload)?
  onNicknameUpdate;
  final ValueChanged<VoidCallback?>? onSystemBackHandlerChanged;
  final ValueChanged<DeveloperWebViewJavaScriptExecutor?>?
  onJavaScriptExecutorChanged;

  @override
  Widget build(BuildContext context) {
    final source =
        resourceSource ??
        resolveGameWebResourceSource(game, developerResourceSession);
    if (source == null) {
      return const _PackageFailure(error: FormatException('游戏缺少已安装包目录'));
    }
    return LocalGameWebView(
      resourceSource: source,
      entryPath: game.entry.gameEntryPath,
      title: game.name,
      gameSdkVersion: game.sdkVersion.isEmpty ? null : game.sdkVersion,
      appSdkVersion: game.appSdkVersion.isEmpty ? null : game.appSdkVersion,
      bridge: bridge,
      localUserId: localUserId,
      localNickname: localNickname,
      declaredCapabilities: game.capabilities
          .requiredForRole(controller: false)
          .toList(),
      appLanHost: appLanHost,
      onOpenSharePanel: onOpenSharePanel,
      onExitRequested: onExitRequested,
      onNicknameUpdate: onNicknameUpdate,
      onSystemBackHandlerChanged: onSystemBackHandlerChanged,
      onJavaScriptExecutorChanged: onJavaScriptExecutorChanged,
    );
  }
}

GameWebResourceSource? resolveGameWebResourceSource(
  GameSummary game,
  DeveloperResourceSession? developerResourceSession,
) => switch (developerResourceSession) {
  final session? => DevelopmentGameWebResourceSource(
    baseUri: session.resourceBaseUri,
    credential: session.credential,
    expiresAt: session.expiresAt,
  ),
  null => switch (game.entry.packageRootFilePath) {
    final root? => InstalledGameWebResourceSource(packageRootPath: root),
    null => null,
  },
};

class _PackageFailure extends StatelessWidget {
  const _PackageFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xff241516),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.tr(
              'game.package_validation_failed',
              arguments: {'error': error},
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
