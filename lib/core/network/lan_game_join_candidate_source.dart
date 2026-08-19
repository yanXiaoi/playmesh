import 'lan_endpoint.dart';

class LanGameJoinCandidateSet {
  LanGameJoinCandidateSet({
    required this.instanceId,
    required this.advertisedGameId,
    required Iterable<LanEndpointCandidate> candidates,
  }) : candidates = List.unmodifiable(candidates);

  final String instanceId;
  final String advertisedGameId;
  final List<LanEndpointCandidate> candidates;
}

class LanGameJoinSourceUnavailableException implements Exception {
  const LanGameJoinSourceUnavailableException();

  @override
  String toString() => '局域网发现候选源不可用';
}

/// 只向统一加入协调器暴露短期秘密候选；UI 和 SDK 只能消费无凭据的发现投影。
abstract interface class LanGameJoinCandidateSource {
  LanGameJoinCandidateSet? findJoinCandidates(String instanceId);
}
