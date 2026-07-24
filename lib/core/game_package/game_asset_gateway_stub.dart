import 'game_asset_gateway_contract.dart';
import '../storage/game_storage_service.dart';

Future<GameAssetGateway> startPlatformGameAssetGateway({
  String? gameRootAssetPath,
  String? gameRootFilePath,
  required String entryAssetPath,
  GameStorageService? storage,
}) {
  throw UnsupportedError('当前平台不支持本地游戏资源网关');
}
