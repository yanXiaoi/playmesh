import 'lan_endpoint.dart';
import 'lan_ipv4_interface_resolver_io.dart';

Future<List<LanEndpointCandidate>> resolveLanEndpointCandidates(
  int port, {
  bool includeLinkLocal = false,
}) async {
  final addresses = await resolveBindableLanIpv4InterfaceAddresses(
    includeLinkLocal: includeLinkLocal,
  );
  final candidates = <LanEndpointCandidate>[];
  final seenAddresses = <String>{};
  for (final entry in addresses) {
    final address = entry.address;
    if (!seenAddresses.add(address.address)) continue;
    final classification = classifyLanAddress(address.rawAddress);
    candidates.add(
      LanEndpointCandidate(
        uri: Uri(scheme: 'http', host: address.address, port: port),
        interfaceName: entry.network.name,
        interfaceIndex: entry.network.index,
        addressType: classification.type,
        risk: classification.risk,
      ),
    );
  }
  // 顺序只表达显式的稳定偏好，不代表地址已经探测可达。
  return sortLanEndpointCandidates(candidates);
}
