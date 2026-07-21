import 'game_asset_gateway_contract.dart';

Future<GameAssetGateway> startPlatformGameAssetGateway({
  String? gameRootAssetPath,
  String? gameRootFilePath,
  required String entryAssetPath,
}) {
  throw UnsupportedError('当前平台不支持本地游戏资源网关');
}
