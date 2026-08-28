import 'relay_tunnel_contract.dart';
import 'relay_tunnel_stub.dart'
    if (dart.library.io) 'relay_tunnel_io.dart'
    as implementation;

export 'relay_tunnel_contract.dart';

Future<RelayHostSession> startRelayHostSession({
  required Uri coreBaseUri,
  required String sessionId,
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
    coreBaseUri: coreBaseUri,
    sessionId: sessionId,
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

Future<RelayClientSession> startRelayClientSession({
  required Uri coreBaseUri,
  required Uri invitationUri,
}) {
  return implementation.startRelayClientSession(
    coreBaseUri: coreBaseUri,
    invitationUri: invitationUri,
  );
}
