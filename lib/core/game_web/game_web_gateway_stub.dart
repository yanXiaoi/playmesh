import 'game_web_gateway_contract.dart';
import '../storage/game_storage_service.dart';
import '../../models/game_summary.dart';

Future<GameWebGateway> startGameWebGateway({
  required String gameRootAssetPath,
  String? gameRootFilePath,
  required bool multiplayer,
  required String displayMode,
  required GameOrientation orientation,
  GameOrientation? controllerOrientation,
  String gameEntryPath = 'app/index.html',
  String controllerEntryPath = 'app/controller/index.html',
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
  throw UnsupportedError('当前平台不支持浏览器游戏网关');
}
