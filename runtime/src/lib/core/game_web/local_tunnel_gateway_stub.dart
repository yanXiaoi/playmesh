import 'local_tunnel_gateway_contract.dart';

Future<LocalTunnelGateway> startLocalTunnelGateway({
  required Uri targetBaseUri,
}) {
  throw UnsupportedError('当前平台不支持本地透明回环网关');
}

Future<LocalTunnelGateway> startLocalUpgradeTunnelGateway({
  required Uri targetBaseUri,
  required String path,
  required Map<String, String> headers,
}) {
  throw UnsupportedError('当前平台不支持本地受控 Upgrade 回环网关');
}
