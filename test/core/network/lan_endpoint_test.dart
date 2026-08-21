import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_endpoint.dart';

void main() {
  test('保留 10.x 与 198.18/15，并按显式风险和接口规则稳定排序', () {
    final candidates = sortLanEndpointCandidates([
      _candidate('198.18.0.1', 'vEthernet (WSL)', 7),
      _candidate('10.80.0.4', 'Wi-Fi', 4),
      _candidate('10.31.2.222', 'Ethernet', 2),
    ]);

    expect(candidates.map((candidate) => candidate.uri.host), [
      '10.31.2.222',
      '10.80.0.4',
      '198.18.0.1',
    ]);
    expect(candidates.last.addressType, LanAddressType.benchmarkIpv4);
    expect(candidates.last.risk, LanEndpointRisk.caution);
  });

  test('常见地址类型只标风险，不声称已经可达', () {
    expect(classifyLanAddress([10, 80, 0, 4]), (
      type: LanAddressType.privateIpv4,
      risk: LanEndpointRisk.low,
    ));
    expect(classifyLanAddress([100, 64, 0, 1]), (
      type: LanAddressType.carrierGradeNatIpv4,
      risk: LanEndpointRisk.caution,
    ));
    expect(classifyLanAddress([169, 254, 3, 7]), (
      type: LanAddressType.linkLocalIpv4,
      risk: LanEndpointRisk.caution,
    ));
    expect(classifyLanAddress([198, 19, 255, 255]), (
      type: LanAddressType.benchmarkIpv4,
      risk: LanEndpointRisk.caution,
    ));
    expect(classifyLanAddress([8, 8, 8, 8]), (
      type: LanAddressType.publicIpv4,
      risk: LanEndpointRisk.high,
    ));
  });
}

LanEndpointCandidate _candidate(String host, String name, int index) {
  final octets = host.split('.').map(int.parse).toList(growable: false);
  final classification = classifyLanAddress(octets);
  return LanEndpointCandidate(
    uri: Uri(scheme: 'http', host: host, port: 16666),
    interfaceName: name,
    interfaceIndex: index,
    addressType: classification.type,
    risk: classification.risk,
  );
}
