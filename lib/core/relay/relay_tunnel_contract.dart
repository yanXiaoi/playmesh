import '../game_web/local_tunnel_gateway_contract.dart';

const relayProtocolVersion = '4.0.0';
const relayCoreControlProtocolVersion = '1.0.0';

enum RelayConnectionStatus { connecting, connected, retrying, disconnected }

abstract interface class RelayHostSession {
  Uri get joinUri;

  RelayConnectionStatus get status;

  Stream<RelayConnectionStatus> get statuses;

  int get connectionCount;

  DateTime get expiresAt;

  Future<void> close();
}

abstract interface class RelayClientGateway implements LocalTunnelGateway {
  Uri get localEntryUri;
}

abstract interface class RelayClientSession {
  RelayClientGateway get webGateway;

  LocalTunnelGateway get coreGateway;

  String get connectionMode;

  Future<void> close();
}
