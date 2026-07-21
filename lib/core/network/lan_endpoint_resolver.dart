import 'lan_endpoint_resolver_stub.dart'
    if (dart.library.io) 'lan_endpoint_resolver_io.dart'
    as implementation;

Future<List<Uri>> resolveLanEndpoints(int port) {
  return implementation.resolveLanEndpoints(port);
}
