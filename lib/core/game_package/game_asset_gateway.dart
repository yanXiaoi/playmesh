import 'game_asset_gateway_contract.dart';
import 'game_asset_gateway_stub.dart'
    if (dart.library.io) 'game_asset_gateway_io.dart';
import 'game_web_resource_source.dart';
import '../storage/game_storage_service.dart';

export 'game_asset_gateway_contract.dart';
export 'game_web_resource_source.dart';

Future<GameAssetGateway> startGameAssetGateway({
  required GameWebResourceSource source,
  required String entryPath,
  String? gameSdkVersion,
  String? appSdkVersion,
  GameStorageService? storage,
}) {
  return startPlatformGameAssetGateway(
    source: source,
    entryPath: entryPath,
    gameSdkVersion: gameSdkVersion,
    appSdkVersion: appSdkVersion,
    storage: storage,
  );
}
