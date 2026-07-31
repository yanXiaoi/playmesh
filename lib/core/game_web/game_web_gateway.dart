import 'game_web_gateway_contract.dart';
import '../game_package/game_web_resource_source.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_summary.dart';
import 'game_web_gateway_stub.dart'
    if (dart.library.io) 'game_web_gateway_io.dart'
    as implementation;

export 'game_web_gateway_contract.dart';
export '../game_package/game_web_resource_source.dart';

Future<GameWebGateway> startGameWebGateway({
  required GameWebResourceSource source,
  required bool multiplayer,
  required String displayMode,
  required GameOrientation orientation,
  GameOrientation? controllerOrientation,
  required String gameEntryPath,
  String? controllerEntryPath,
  required String gameId,
  String gameName = 'Playmesh 游戏',
  List<String> tags = const [],
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
    source: source,
    multiplayer: multiplayer,
    displayMode: displayMode,
    orientation: orientation,
    controllerOrientation: controllerOrientation,
    gameEntryPath: gameEntryPath,
    controllerEntryPath: controllerEntryPath,
    gameId: gameId,
    gameName: gameName,
    tags: tags,
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
