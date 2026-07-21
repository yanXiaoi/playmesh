import 'package:flutter/material.dart';

import '../../core/game_package/asset_game_package_loader.dart';
import '../../models/game_summary.dart';
import '../../core/game_sdk/game_sdk_bridge.dart';
import 'local_game_web_view.dart';

class GameLauncher extends StatefulWidget {
  const GameLauncher({
    super.key,
    required this.game,
    required this.localUserId,
    required this.localNickname,
    this.bridge,
    this.controllerRole = false,
    this.onExitRequested,
  });

  final GameSummary game;
  final String localUserId;
  final String localNickname;
  final GameSdkBridge? bridge;
  final bool controllerRole;
  final Future<void> Function()? onExitRequested;

  @override
  State<GameLauncher> createState() => _GameLauncherState();
}

class _GameLauncherState extends State<GameLauncher> {
  Future<LoadedGamePackage?>? _loadOperation;

  @override
  void initState() {
    super.initState();
    _loadOperation = _loadPackage();
  }

  Future<LoadedGamePackage?> _loadPackage() async {
    if (widget.game.entry.packageRootFilePath != null) return null;
    final packageRoot = widget.game.entry.packageRootAssetPath;
    if (packageRoot == null) {
      return null;
    }
    final package = await AssetGamePackageLoader().load(packageRoot);
    if (package.manifest.id != widget.game.id) {
      throw const FormatException('游戏库记录与 main.json 不一致');
    }
    return package;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<LoadedGamePackage?>(
      future: _loadOperation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _PackageFailure(error: snapshot.error!);
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final fileRoot = widget.game.entry.packageRootFilePath;
        final package = snapshot.data;
        final assetPath = widget.controllerRole
            ? fileRoot != null
                  ? widget.game.entry.controllerEntryPath
                  : package?.controllerEntryAssetPath ??
                        widget.game.entry.controllerEntryPath
            : fileRoot != null
            ? widget.game.entry.gameEntryPath
            : package?.appEntryAssetPath ?? widget.game.entry.assetPath;
        return LocalGameWebView(
          assetPath: assetPath,
          gameRootAssetPath: fileRoot == null ? package?.rootAssetPath : null,
          gameRootFilePath: fileRoot,
          title: widget.game.name,
          bridge: widget.bridge,
          localUserId: widget.localUserId,
          localNickname: widget.localNickname,
          declaredCapabilities: widget.game.capabilities.required.toList(),
          onExitRequested: widget.onExitRequested,
        );
      },
    );
  }
}

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
            '游戏包校验失败\n$error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
