const playmeshCoreTunnelPath = '/playmesh/core';
const playmeshCoreTunnelProtocol = 'playmesh-core-tunnel';
const playmeshShareTokenHeader = 'X-Playmesh-Share-Token';

abstract interface class LocalTunnelGateway {
  Uri get localBaseUri;

  Future<void> close();
}
