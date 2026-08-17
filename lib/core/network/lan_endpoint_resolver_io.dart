import 'dart:io';

import 'lan_endpoint.dart';

Future<List<LanEndpointCandidate>> resolveLanEndpointCandidates(
  int port,
) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.any,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  final candidates = <LanEndpointCandidate>[];
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) continue;
      final classification = classifyLanAddress(address.rawAddress);
      candidates.add(
        LanEndpointCandidate(
          uri: Uri(scheme: 'http', host: address.address, port: port),
          interfaceName: interface.name,
          interfaceIndex: interface.index,
          addressType: classification.type,
          risk: classification.risk,
        ),
      );
    }
  }
  // 顺序只表达显式的稳定偏好，不代表地址已经探测可达。
  return sortLanEndpointCandidates(candidates);
}
