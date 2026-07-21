import 'game_web_gateway_contract.dart';
import '../storage/game_storage_service.dart';

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
  throw UnsupportedError('当前平台不支持浏览器游戏网关');
}
