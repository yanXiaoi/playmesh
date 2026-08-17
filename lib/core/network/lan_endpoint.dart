enum LanAddressType {
  privateIpv4,
  carrierGradeNatIpv4,
  benchmarkIpv4,
  publicIpv4,
  uniqueLocalIpv6,
  globalIpv6,
  other,
}

enum LanEndpointRisk { low, caution, high }

class LanEndpointCandidate {
  const LanEndpointCandidate({
    required this.uri,
    required this.interfaceName,
    required this.interfaceIndex,
    required this.addressType,
    required this.risk,
  });

  final Uri uri;
  final String interfaceName;
  final int interfaceIndex;
  final LanAddressType addressType;
  final LanEndpointRisk risk;

  LanEndpointCandidate withUri(Uri value) => LanEndpointCandidate(
    uri: value,
    interfaceName: interfaceName,
    interfaceIndex: interfaceIndex,
    addressType: addressType,
    risk: risk,
  );
}

({LanAddressType type, LanEndpointRisk risk}) classifyLanAddress(
  List<int> bytes,
) {
  if (bytes.length == 4) {
    final first = bytes[0];
    final second = bytes[1];
    if (first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168)) {
      return (type: LanAddressType.privateIpv4, risk: LanEndpointRisk.low);
    }
    if (first == 100 && second >= 64 && second <= 127) {
      return (
        type: LanAddressType.carrierGradeNatIpv4,
        risk: LanEndpointRisk.caution,
      );
    }
    if (first == 198 && (second == 18 || second == 19)) {
      return (
        type: LanAddressType.benchmarkIpv4,
        risk: LanEndpointRisk.caution,
      );
    }
    return (type: LanAddressType.publicIpv4, risk: LanEndpointRisk.high);
  }
  if (bytes.length == 16) {
    if ((bytes[0] & 0xfe) == 0xfc) {
      return (type: LanAddressType.uniqueLocalIpv6, risk: LanEndpointRisk.low);
    }
    return (type: LanAddressType.globalIpv6, risk: LanEndpointRisk.high);
  }
  return (type: LanAddressType.other, risk: LanEndpointRisk.high);
}

int compareLanEndpointCandidates(
  LanEndpointCandidate left,
  LanEndpointCandidate right,
) {
  final riskComparison = left.risk.index.compareTo(right.risk.index);
  if (riskComparison != 0) return riskComparison;
  final typeComparison = left.addressType.index.compareTo(
    right.addressType.index,
  );
  if (typeComparison != 0) return typeComparison;
  final interfaceComparison = left.interfaceName.toLowerCase().compareTo(
    right.interfaceName.toLowerCase(),
  );
  if (interfaceComparison != 0) return interfaceComparison;
  final indexComparison = left.interfaceIndex.compareTo(right.interfaceIndex);
  if (indexComparison != 0) return indexComparison;
  return left.uri.toString().compareTo(right.uri.toString());
}

List<LanEndpointCandidate> sortLanEndpointCandidates(
  Iterable<LanEndpointCandidate> candidates,
) {
  final sorted = candidates.toList(growable: false);
  sorted.sort(compareLanEndpointCandidates);
  return List.unmodifiable(sorted);
}
