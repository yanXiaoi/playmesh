import 'dart:convert';
import 'dart:math';

const String gdevelopEditorInstanceHeader =
    'X-Playmesh-GDevelop-Editor-Instance';
const String gdevelopEditorPageHeader = 'X-Playmesh-GDevelop-Editor-Page';
const String gdevelopEditorLeaseHeader = 'X-Playmesh-GDevelop-Editor-Lease';

class GDevelopEditorInstanceLease {
  const GDevelopEditorInstanceLease({
    required this.instanceId,
    required this.pageId,
    required this.leaseToken,
    required this.acquiredAt,
    required this.lastHeartbeatAt,
    required this.expiresAt,
  });

  final String instanceId;
  final String pageId;
  final String leaseToken;
  final DateTime acquiredAt;
  final DateTime lastHeartbeatAt;
  final DateTime expiresAt;

  Map<String, Object?> toClientJson({required Duration heartbeatInterval}) => {
    'instanceId': instanceId,
    'pageId': pageId,
    'leaseToken': leaseToken,
    'acquiredAt': acquiredAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'heartbeatIntervalMs': heartbeatInterval.inMilliseconds,
  };

  Map<String, Object?> toOccupiedJson() => {
    'acquiredAt': acquiredAt.toIso8601String(),
    'lastHeartbeatAt': lastHeartbeatAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };

  Map<String, String> toRequestHeaders() => {
    gdevelopEditorInstanceHeader: instanceId,
    gdevelopEditorPageHeader: pageId,
    gdevelopEditorLeaseHeader: leaseToken,
  };
}

class GDevelopEditorInstanceAcquireResult {
  const GDevelopEditorInstanceAcquireResult.acquired(
    this.lease, {
    required this.resumed,
  }) : occupiedBy = null,
       installationInProgress = false;

  const GDevelopEditorInstanceAcquireResult.occupied(this.occupiedBy)
    : lease = null,
      resumed = false,
      installationInProgress = false;

  const GDevelopEditorInstanceAcquireResult.installationInProgress()
    : lease = null,
      occupiedBy = null,
      resumed = false,
      installationInProgress = true;

  final GDevelopEditorInstanceLease? lease;
  final GDevelopEditorInstanceLease? occupiedBy;
  final bool resumed;
  final bool installationInProgress;

  bool get acquired => lease != null;
}

/// Owns the single process-wide GDevelop editor instance lease.
///
/// This manager is intentionally not keyed by game id: an editor can change
/// projects without changing its identity, while two projects in two tabs are
/// still two editor instances.
class GDevelopEditorInstanceLeaseManager {
  GDevelopEditorInstanceLeaseManager({
    DateTime Function()? clock,
    String Function()? tokenFactory,
    this.ttl = const Duration(minutes: 2),
    this.heartbeatInterval = const Duration(seconds: 15),
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _tokenFactory = tokenFactory ?? _secureToken {
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'must be positive');
    }
    if (heartbeatInterval <= Duration.zero || heartbeatInterval >= ttl) {
      throw ArgumentError.value(
        heartbeatInterval,
        'heartbeatInterval',
        'must be positive and shorter than ttl',
      );
    }
  }

  final DateTime Function() _clock;
  final String Function() _tokenFactory;
  final Duration ttl;
  final Duration heartbeatInterval;
  GDevelopEditorInstanceLease? _active;
  bool _installationInProgress = false;
  int _generation = 0;
  final Map<String, int> _aiSessionGenerations = {};

  GDevelopEditorInstanceLease? get active {
    _expireIfStale();
    return _active;
  }

  Map<String, String>? get activeRequestHeaders => active?.toRequestHeaders();

  /// Monotonic identity for the current editor lease. It is not a credential.
  int get generation {
    _expireIfStale();
    return _generation;
  }

  /// Binds an AI editor session to the current editor lease generation.
  /// Credentials stay in Dart and are never added to Chat/Agent prompts.
  bool bindAiSession(String editorSessionId) {
    _validateId(editorSessionId, 'editorSessionId');
    if (active == null) return false;
    _aiSessionGenerations[editorSessionId] = _generation;
    return true;
  }

  bool validatesAiSession(String editorSessionId) {
    if (active == null) return false;
    return _aiSessionGenerations[editorSessionId] == _generation;
  }

  bool get hasActiveAiSessionBinding {
    if (active == null) return false;
    return _aiSessionGenerations.values.any(
      (generation) => generation == _generation,
    );
  }

  void unbindAiSession(String editorSessionId) {
    _aiSessionGenerations.remove(editorSessionId);
  }

  GDevelopEditorInstanceAcquireResult acquire({
    required String instanceId,
    required String pageId,
    String? previousLeaseToken,
    bool resumeAfterReload = false,
  }) {
    _validateId(instanceId, 'instanceId');
    _validateId(pageId, 'pageId');
    if (_installationInProgress) {
      return const GDevelopEditorInstanceAcquireResult.installationInProgress();
    }
    final now = _clock().toUtc();
    _expireIfStale(now);
    final current = _active;
    if (current == null) {
      final lease = _newLease(instanceId: instanceId, pageId: pageId, now: now);
      _replaceActive(lease);
      return GDevelopEditorInstanceAcquireResult.acquired(
        lease,
        resumed: false,
      );
    }

    final provesCurrentLease =
        previousLeaseToken != null &&
        _constantTimeEquals(previousLeaseToken, current.leaseToken) &&
        _constantTimeEquals(instanceId, current.instanceId);
    if (provesCurrentLease &&
        (_constantTimeEquals(pageId, current.pageId) || resumeAfterReload)) {
      // Rotate on every successful recovery. Requests from a page that was
      // replaced by a refresh can no longer mutate the App source of truth.
      final lease = _newLease(
        instanceId: instanceId,
        pageId: pageId,
        now: now,
        acquiredAt: current.acquiredAt,
      );
      _replaceActive(lease);
      return GDevelopEditorInstanceAcquireResult.acquired(lease, resumed: true);
    }
    return GDevelopEditorInstanceAcquireResult.occupied(current);
  }

  GDevelopEditorInstanceLease? heartbeat({
    required String instanceId,
    required String pageId,
    required String leaseToken,
  }) {
    final now = _clock().toUtc();
    _expireIfStale(now);
    final current = _active;
    if (!_matches(
      current,
      instanceId: instanceId,
      pageId: pageId,
      leaseToken: leaseToken,
    )) {
      return null;
    }
    final renewed = GDevelopEditorInstanceLease(
      instanceId: current!.instanceId,
      pageId: current.pageId,
      leaseToken: current.leaseToken,
      acquiredAt: current.acquiredAt,
      lastHeartbeatAt: now,
      expiresAt: now.add(ttl),
    );
    _active = renewed;
    return renewed;
  }

  bool release({
    required String instanceId,
    required String pageId,
    required String leaseToken,
  }) {
    _expireIfStale();
    if (!_matches(
      _active,
      instanceId: instanceId,
      pageId: pageId,
      leaseToken: leaseToken,
    )) {
      return false;
    }
    _replaceActive(null);
    return true;
  }

  bool validates({
    required String instanceId,
    required String pageId,
    required String leaseToken,
  }) {
    _expireIfStale();
    return _matches(
      _active,
      instanceId: instanceId,
      pageId: pageId,
      leaseToken: leaseToken,
    );
  }

  bool beginInstall() {
    _expireIfStale();
    if (_installationInProgress || _active != null) return false;
    _installationInProgress = true;
    return true;
  }

  void endInstall() => _installationInProgress = false;

  bool get installationInProgress => _installationInProgress;

  void clear() {
    _installationInProgress = false;
    _replaceActive(null);
  }

  GDevelopEditorInstanceLease _newLease({
    required String instanceId,
    required String pageId,
    required DateTime now,
    DateTime? acquiredAt,
  }) => GDevelopEditorInstanceLease(
    instanceId: instanceId,
    pageId: pageId,
    leaseToken: _tokenFactory(),
    acquiredAt: acquiredAt ?? now,
    lastHeartbeatAt: now,
    expiresAt: now.add(ttl),
  );

  void _expireIfStale([DateTime? at]) {
    final current = _active;
    if (current == null) return;
    final now = (at ?? _clock()).toUtc();
    if (!now.isBefore(current.expiresAt)) _replaceActive(null);
  }

  void _replaceActive(GDevelopEditorInstanceLease? lease) {
    _generation += 1;
    _active = lease;
    _aiSessionGenerations.clear();
  }

  bool _matches(
    GDevelopEditorInstanceLease? lease, {
    required String instanceId,
    required String pageId,
    required String leaseToken,
  }) =>
      lease != null &&
      _constantTimeEquals(instanceId, lease.instanceId) &&
      _constantTimeEquals(pageId, lease.pageId) &&
      _constantTimeEquals(leaseToken, lease.leaseToken);

  static void _validateId(String value, String name) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value)) {
      throw FormatException('$name is invalid');
    }
  }

  static String _secureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static bool _constantTimeEquals(String left, String right) {
    var result = left.length ^ right.length;
    final length = max(left.length, right.length);
    for (var index = 0; index < length; index += 1) {
      final leftCode = index < left.length ? left.codeUnitAt(index) : 0;
      final rightCode = index < right.length ? right.codeUnitAt(index) : 0;
      result |= leftCode ^ rightCode;
    }
    return result == 0;
  }
}
