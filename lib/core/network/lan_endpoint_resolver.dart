import 'lan_endpoint_resolver_stub.dart'
    if (dart.library.io) 'lan_endpoint_resolver_io.dart'
    as implementation;
import 'lan_endpoint.dart';

Future<List<LanEndpointCandidate>> resolveLanEndpointCandidates(int port) {
  return implementation.resolveLanEndpointCandidates(port);
}

Future<List<Uri>> resolveLanEndpoints(int port) async =>
    (await resolveLanEndpointCandidates(
      port,
    )).map((candidate) => candidate.uri).toList(growable: false);
