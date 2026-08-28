import 'game_asset_gateway_contract.dart';
import 'game_web_resource_source.dart';
import '../storage/game_storage_service.dart';

Future<GameAssetGateway> startPlatformGameAssetGateway({
  required GameWebResourceSource source,
  required String entryPath,
  String? gameSdkVersion,
  String? appSdkVersion,
  Object? config,
  GameStorageService? storage,
}) {
  throw UnsupportedError('当前平台不支持本地游戏资源网关');
}
