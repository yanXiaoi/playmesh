import 'dart:io';

Future<List<Uri>> resolveLanEndpoints(int port) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final hosts = <String>{};
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      hosts.add(address.address);
    }
  }
  return hosts
      .map((host) => Uri(scheme: 'http', host: host, port: port))
      .toList(growable: false);
}
