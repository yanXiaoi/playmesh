import 'relay_tunnel_contract.dart';
import 'relay_tunnel_stub.dart'
    if (dart.library.io) 'relay_tunnel_io.dart'
    as implementation;

export 'relay_tunnel_contract.dart';

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
  return implementation.startRelayHostSession(
    serverBaseUri: serverBaseUri,
    sourceToken: sourceToken,
    hostPath: hostPath,
    clientPath: clientPath,
    authorityWebBaseUri: authorityWebBaseUri,
    authorityCoreBaseUri: authorityCoreBaseUri,
    authorityEntryUri: authorityEntryUri,
    maxConnectionsPerTunnel: maxConnectionsPerTunnel,
  );
}

Future<RelayClientGateway> startRelayClientGateway({
  required Uri invitationUri,
  required RelayTarget target,
}) {
  return implementation.startRelayClientGateway(
    invitationUri: invitationUri,
    target: target,
  );
}
