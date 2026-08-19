import 'lan_endpoint_resolver_stub.dart'
    if (dart.library.io) 'lan_endpoint_resolver_io.dart'
    as implementation;
import 'lan_endpoint.dart';

Future<List<LanEndpointCandidate>> resolveLanEndpointCandidates(
  int port, {
  bool includeLinkLocal = false,
}) {
  return implementation.resolveLanEndpointCandidates(
    port,
    includeLinkLocal: includeLinkLocal,
  );
}

Future<List<Uri>> resolveLanEndpoints(
  int port, {
  bool includeLinkLocal = false,
}) async => (await resolveLanEndpointCandidates(
  port,
  includeLinkLocal: includeLinkLocal,
)).map((candidate) => candidate.uri).toList(growable: false);
