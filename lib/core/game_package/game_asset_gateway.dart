import 'game_asset_gateway_contract.dart';
import 'game_asset_gateway_stub.dart'
    if (dart.library.io) 'game_asset_gateway_io.dart';

export 'game_asset_gateway_contract.dart';

Future<GameAssetGateway> startGameAssetGateway({
  String? gameRootAssetPath,
  String? gameRootFilePath,
  required String entryAssetPath,
}) {
  return startPlatformGameAssetGateway(
    gameRootAssetPath: gameRootAssetPath,
    gameRootFilePath: gameRootFilePath,
    entryAssetPath: entryAssetPath,
  );
}
