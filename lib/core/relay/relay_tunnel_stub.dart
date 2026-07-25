import 'relay_tunnel_contract.dart';

Future<RelayHostSession> startRelayHostSession({
  required Uri serverBaseUri,
  required String sourceToken,
  required String hostPath,
  required String clientPath,
  required Uri authorityWebBaseUri,
  required Uri authorityCoreBaseUri,
  required Uri authorityEntryUri,
  required int maxConnectionsPerTunnel,
}) {
  throw UnsupportedError('当前平台不支持公共中转主机');
}

Future<RelayClientGateway> startRelayClientGateway({
  required Uri invitationUri,
  required RelayTarget target,
}) {
  throw UnsupportedError('当前平台不支持公共中转客户端');
}
