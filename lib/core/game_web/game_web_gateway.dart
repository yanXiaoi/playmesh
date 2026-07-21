import 'game_web_gateway_contract.dart';
import '../storage/game_storage_service.dart';
import 'game_web_gateway_stub.dart'
    if (dart.library.io) 'game_web_gateway_io.dart'
    as implementation;

export 'game_web_gateway_contract.dart';

Future<GameWebGateway> startGameWebGateway({
  required String gameRootAssetPath,
  String? gameRootFilePath,
  required bool multiplayer,
  required String displayMode,
  String gameEntryPath = 'app/index.html',
  String controllerEntryPath = 'app/controller/index.html',
  String gameId = 'com.playmesh.unknown',
  String gameName = 'Playmesh 游戏',
  List<String> requiredCapabilities = const [],
  Uri? coreEndpoint,
  String? joinCode,
  required String shareToken,
  required GameStorageService storage,
}) {
  return implementation.startGameWebGateway(
    gameRootAssetPath: gameRootAssetPath,
    gameRootFilePath: gameRootFilePath,
    multiplayer: multiplayer,
    displayMode: displayMode,
    gameEntryPath: gameEntryPath,
    controllerEntryPath: controllerEntryPath,
    gameId: gameId,
    gameName: gameName,
    requiredCapabilities: requiredCapabilities,
    coreEndpoint: coreEndpoint,
    joinCode: joinCode,
    shareToken: shareToken,
    storage: storage,
  );
}
