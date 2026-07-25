import '../game_web/local_tunnel_gateway_contract.dart';

const relayProtocolVersion = '2.0.0';

enum RelayTarget {
  web(1),
  core(2);

  const RelayTarget(this.protocolCode);

  final int protocolCode;
}

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
