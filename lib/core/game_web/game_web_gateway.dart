import 'game_web_gateway_contract.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_summary.dart';
import 'game_web_gateway_stub.dart'
    if (dart.library.io) 'game_web_gateway_io.dart'
    as implementation;

export 'game_web_gateway_contract.dart';

Future<GameWebGateway> startGameWebGateway({
  required String gameRootAssetPath,
  String? gameRootFilePath,
  required bool multiplayer,
  required String displayMode,
  required GameOrientation orientation,
  GameOrientation? controllerOrientation,
  String gameEntryPath = 'app/index.html',
  String controllerEntryPath = 'app/controller/index.html',
  String gameName = 'Playmesh 游戏',
  String? gameSdkVersion,
  String? appSdkVersion,
  List<String> requiredCapabilities = const [],
  List<String> controllerRequiredCapabilities = const [],
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
    orientation: orientation,
    controllerOrientation: controllerOrientation,
    gameEntryPath: gameEntryPath,
    controllerEntryPath: controllerEntryPath,
    gameName: gameName,
    gameSdkVersion: gameSdkVersion,
    appSdkVersion: appSdkVersion,
    requiredCapabilities: requiredCapabilities,
    controllerRequiredCapabilities: controllerRequiredCapabilities,
    coreEndpoint: coreEndpoint,
    joinCode: joinCode,
    shareToken: shareToken,
    storage: storage,
  );
}
