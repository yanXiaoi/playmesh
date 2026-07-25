import 'game_asset_gateway_contract.dart';
import 'game_asset_gateway_stub.dart'
    if (dart.library.io) 'game_asset_gateway_io.dart';
import '../storage/game_storage_service.dart';

export 'game_asset_gateway_contract.dart';

Future<GameAssetGateway> startGameAssetGateway({
  String? gameRootAssetPath,
  String? gameRootFilePath,
  required String entryAssetPath,
  String? gameSdkVersion,
  String? appSdkVersion,
  GameStorageService? storage,
}) {
  return startPlatformGameAssetGateway(
    gameRootAssetPath: gameRootAssetPath,
    gameRootFilePath: gameRootFilePath,
    entryAssetPath: entryAssetPath,
    gameSdkVersion: gameSdkVersion,
    appSdkVersion: appSdkVersion,
    storage: storage,
  );
}
