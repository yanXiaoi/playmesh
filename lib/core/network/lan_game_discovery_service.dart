import 'dart:async';

import '../game_web/game_web_gateway_contract.dart';
import 'lan_endpoint.dart';
import 'lan_game_advertisement.dart';
import 'lan_game_discovery_platform.dart';
import 'lan_game_join_candidate_source.dart';
import 'lan_game_multicast_protocol.dart';
import 'lan_game_presence.dart';

const maxDiscoveredLanGames = 64;
const _maxRetiredLocalLanGameInstances = 256;

enum LanGameDiscoveryState {
  scanning,
  ready,
  permissionDenied,
  unsupported,
  failed,
}

class DiscoveredLanGame {
  const DiscoveredLanGame({
    required this.instanceId,
    required this.gameId,
    required this.name,
    required this.host,
    required this.hostAddress,
    required this.presence,
  });

  final String instanceId;
  final String gameId;
  final String name;
  final String host;
  final String hostAddress;
  final LanGamePresence presence;
}

class LanGameDiscoverySnapshot {
  LanGameDiscoverySnapshot({
    required this.state,
    required Iterable<DiscoveredLanGame> games,
  }) : games = List.unmodifiable(games);

  final LanGameDiscoveryState state;
  final List<DiscoveredLanGame> games;
}

class LanGameDiscoveryLease {
  LanGameDiscoveryLease._(this._service);

  LanGameDiscoveryService? _service;

  Stream<LanGameDiscoverySnapshot> get snapshots => _service!.snapshots;

  LanGameDiscoverySnapshot get current => _service!.currentSnapshot;

  Future<void> close() async {
    final service = _service;
    if (service == null) return;
    _service = null;
    await service._releaseDiscovery();
  }
}

class LanGameRegistrationLease {
  LanGameRegistrationLease._(this._service, this.instanceId);

  LanGameDiscoveryService? _service;
  final String instanceId;

  Future<void> updatePresence(LanGamePresence presence) {
    final service = _service;
    if (service == null) {
      return Future<void>.error(StateError('局域网发现注册已经关闭'));
    }
    return service._updateRegistrationPresence(instanceId, presence);
  }

  Future<void> close() async {
    final service = _service;
    if (service == null) return;
    _service = null;
    await service._releaseRegistration(instanceId);
  }
}

class LanGameDiscoveryService implements LanGameJoinCandidateSource {
  LanGameDiscoveryService({LanGameDiscoveryPlatform? platform})
    : _platform = platform ?? createLanGameDiscoveryPlatform();

  final LanGameDiscoveryPlatform _platform;
  final StreamController<LanGameDiscoverySnapshot> _snapshotController =
      StreamController<LanGameDiscoverySnapshot>.broadcast();
  final Map<String, _RegistrationEntry> _registrations = {};
  final Map<String, Future<_RegistrationEntry>> _registrationOperations = {};
  final Map<String, Future<void>> _registrationCloseOperations = {};
  final Map<String, LanGamePlatformResolved> _platformRecords = {};
  final Map<String, LanGameJoinCandidateSet> _joinCandidates = {};
  final Set<String> _retiredLocalInstanceIds = <String>{};
  final Map<String, int> _closingRegistrationCounts = <String, int>{};
  LanGamePlatformDiscovery? _discovery;
  StreamSubscription<LanGamePlatformEvent>? _discoverySubscription;
  Future<void>? _discoveryStartOperation;
  int _discoveryGeneration = 0;
  LanGameDiscoverySnapshot _snapshot = LanGameDiscoverySnapshot(
    state: LanGameDiscoveryState.scanning,
    games: const [],
  );
  int _discoveryUsers = 0;
  bool _disposed = false;

  Stream<LanGameDiscoverySnapshot> get snapshots => _snapshotController.stream;

  LanGameDiscoverySnapshot get currentSnapshot => _snapshot;

  @override
  LanGameJoinCandidateSet? findJoinCandidates(String instanceId) {
    if (_disposed ||
        const {
          LanGameDiscoveryState.permissionDenied,
          LanGameDiscoveryState.unsupported,
          LanGameDiscoveryState.failed,
        }.contains(_snapshot.state)) {
      throw const LanGameJoinSourceUnavailableException();
    }
    return _joinCandidates[instanceId];
  }

  Future<LanGameRegistrationLease> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async {
    _ensureActive();
    advertisement.validated();
    _prepareLocalRegistration(advertisement.instanceId);
    final existing = _registrations[advertisement.instanceId];
    if (existing != null) {
      _retiredLocalInstanceIds.remove(advertisement.instanceId);
      if (existing.port != port ||
          existing.advertisement.gameId != advertisement.gameId ||
          existing.advertisement.name != advertisement.name ||
          existing.advertisement.inviteToken != advertisement.inviteToken) {
        throw StateError('同一局域网发现 instance 不能绑定不同分享通道');
      }
      existing.references += 1;
      return LanGameRegistrationLease._(this, advertisement.instanceId);
    }
    final operation = _registrationOperations.putIfAbsent(
      advertisement.instanceId,
      () async {
        final previousClose =
            _registrationCloseOperations[advertisement.instanceId];
        if (previousClose != null) {
          try {
            await previousClose;
          } on Object {
            // close 已经终止后不会再签发 revision；其清理错误不应阻止重新注册。
          }
        }
        if (_disposed) throw StateError('局域网发现服务已经关闭');
        final handle = await _platform.register(
          advertisement: advertisement,
          port: port,
        );
        if (_disposed) {
          try {
            await handle.close();
          } finally {
            throw StateError('局域网发现服务已经关闭');
          }
        }
        final entry = _RegistrationEntry(
          advertisement: advertisement,
          port: port,
          handle: handle,
        );
        _registrations[advertisement.instanceId] = entry;
        return entry;
      },
    );
    // putIfAbsent 返回后，instance 已由 pending operation 或 active entry 保护；
    // 临时 retired 标记不再占用已关闭实例的有界缓存。
    _retiredLocalInstanceIds.remove(advertisement.instanceId);
    try {
      final entry = await operation;
      if (_disposed) throw StateError('局域网发现服务已经关闭');
      if (entry.port != port ||
          entry.advertisement.gameId != advertisement.gameId ||
          entry.advertisement.name != advertisement.name ||
          entry.advertisement.inviteToken != advertisement.inviteToken) {
        throw StateError('同一局域网发现 instance 不能绑定不同分享通道');
      }
      entry.references += 1;
      return LanGameRegistrationLease._(this, advertisement.instanceId);
    } finally {
      if (identical(
        _registrationOperations[advertisement.instanceId],
        operation,
      )) {
        _registrationOperations.remove(advertisement.instanceId);
      }
      _retireLocalInstanceIfInactive(advertisement.instanceId);
    }
  }

  Future<LanGameDiscoveryLease> startDiscovery() async {
    _ensureActive();
    _discoveryUsers += 1;
    final operation = _discoveryStartOperation ??= _startDiscoveryPlatform();
    try {
      await operation;
    } finally {
      if (identical(_discoveryStartOperation, operation)) {
        _discoveryStartOperation = null;
      }
    }
    if (_disposed) throw StateError('局域网发现服务已经关闭');
    return LanGameDiscoveryLease._(this);
  }

  Future<LanGameDiscoverySnapshot> scan({
    Duration duration = const Duration(seconds: 2),
  }) async {
    final lease = await startDiscovery();
    try {
      await Future<void>.delayed(duration);
      return lease.current;
    } finally {
      await lease.close();
    }
  }

  Future<void> _startDiscoveryPlatform() async {
    if (_discovery != null) return;
    final generation = ++_discoveryGeneration;
    _platformRecords.clear();
    _emit(LanGameDiscoveryState.scanning, const []);
    try {
      final discovery = await _platform.startDiscovery();
      if (_disposed ||
          _discoveryUsers == 0 ||
          generation != _discoveryGeneration) {
        await discovery.close();
        return;
      }
      _discovery = discovery;
      _discoverySubscription = discovery.events.listen(
        (event) {
          if (generation == _discoveryGeneration) {
            _handlePlatformEvent(event);
          }
        },
        onError: (_) {
          if (generation == _discoveryGeneration) {
            _emit(LanGameDiscoveryState.failed, _snapshot.games);
          }
        },
      );
      _emit(LanGameDiscoveryState.ready, const []);
    } on UnsupportedError {
      _emit(LanGameDiscoveryState.unsupported, const []);
    } on LanGamePlatformException catch (error) {
      _emit(
        error.kind == LanGamePlatformFailureKind.permissionDenied
            ? LanGameDiscoveryState.permissionDenied
            : LanGameDiscoveryState.failed,
        const [],
      );
    } on Object {
      _emit(LanGameDiscoveryState.failed, const []);
    }
  }

  void _handlePlatformEvent(LanGamePlatformEvent event) {
    switch (event) {
      case LanGamePlatformResolved():
        if (_isLocalInstance(event.instanceId)) {
          final removed = _removePlatformRecordsForInstance(event.instanceId);
          if (removed) {
            _rebuildSnapshot(
              markReady: !_isDiscoveryFailureState(_snapshot.state),
            );
          }
          return;
        }
        if (!_platformRecords.containsKey(event.platformId) &&
            _platformRecords.length >= maxLanGameMulticastRecords) {
          _platformRecords.remove(_platformRecords.keys.first);
        } else {
          _platformRecords.remove(event.platformId);
        }
        _platformRecords[event.platformId] = event;
        _rebuildSnapshot(markReady: !_isDiscoveryFailureState(_snapshot.state));
        return;
      case LanGamePlatformLost():
        _platformRecords.remove(event.platformId);
        _rebuildSnapshot(markReady: !_isDiscoveryFailureState(_snapshot.state));
        return;
      case LanGamePlatformReady():
        _rebuildSnapshot();
        return;
      case LanGamePlatformFailure():
        _emit(
          event.kind == LanGamePlatformFailureKind.permissionDenied
              ? LanGameDiscoveryState.permissionDenied
              : LanGameDiscoveryState.failed,
          _snapshot.games,
        );
        return;
    }
  }

  void _rebuildSnapshot({bool markReady = true}) {
    final byInstance = <String, _DiscoveredGameBuilder>{};
    for (final record in _platformRecords.values) {
      try {
        if (_isLocalInstance(record.instanceId)) continue;
        if (record.port < 1 || record.port > 65535) continue;
        final advertisement = LanGameAdvertisement.fromPayload(
          instanceId: record.instanceId,
          payload: record.payload,
        );
        final builder = byInstance.putIfAbsent(
          advertisement.instanceId,
          () => _DiscoveredGameBuilder(advertisement, record.revision),
        );
        builder.add(record);
      } on Object {
        // 坏 payload、记录或地址只丢弃该项，不影响其他发现结果。
      }
    }
    final available =
        <({DiscoveredLanGame game, _DiscoveredGameBuilder builder})>[];
    for (final builder in byInstance.values) {
      final game = builder.build();
      if (game != null) available.add((game: game, builder: builder));
    }
    available.sort((left, right) {
      final name = left.game.name.toLowerCase().compareTo(
        right.game.name.toLowerCase(),
      );
      return name != 0
          ? name
          : left.game.instanceId.compareTo(right.game.instanceId);
    });
    final visible = available
        .take(maxDiscoveredLanGames)
        .toList(growable: false);
    final games = visible.map((item) => item.game).toList(growable: false);
    _joinCandidates
      ..clear()
      ..addEntries(
        visible.map(
          (item) => MapEntry(
            item.game.instanceId,
            LanGameJoinCandidateSet(
              instanceId: item.game.instanceId,
              advertisedGameId: item.game.gameId,
              candidates: item.builder.endpointCandidates,
            ),
          ),
        ),
      );
    _emit(markReady ? LanGameDiscoveryState.ready : _snapshot.state, games);
  }

  void _emit(LanGameDiscoveryState state, Iterable<DiscoveredLanGame> games) {
    if (_disposed) return;
    _snapshot = LanGameDiscoverySnapshot(state: state, games: games);
    _snapshotController.add(_snapshot);
  }

  Future<void> _releaseDiscovery() async {
    if (_discoveryUsers == 0) return;
    _discoveryUsers -= 1;
    if (_discoveryUsers != 0) return;
    _discoveryGeneration += 1;
    final subscription = _discoverySubscription;
    _discoverySubscription = null;
    final discovery = _discovery;
    _discovery = null;
    _platformRecords.clear();
    _joinCandidates.clear();
    try {
      try {
        await subscription?.cancel();
      } finally {
        await discovery?.close();
      }
    } finally {
      if (!_disposed && _discoveryUsers == 0 && _discovery == null) {
        _emit(LanGameDiscoveryState.scanning, const []);
      }
    }
  }

  Future<void> _releaseRegistration(String instanceId) async {
    final entry = _registrations[instanceId];
    if (entry == null) return;
    entry.references -= 1;
    if (entry.references > 0) return;
    _registrations.remove(instanceId);
    _incrementClosingRegistration(instanceId);
    final previousClose = _registrationCloseOperations[instanceId];
    final closeOperation = previousClose == null
        ? entry.close()
        : previousClose.then<void>(
            (_) => entry.close(),
            onError: (Object _, StackTrace _) => entry.close(),
          );
    _registrationCloseOperations[instanceId] = closeOperation;
    try {
      await closeOperation;
    } finally {
      if (identical(_registrationCloseOperations[instanceId], closeOperation)) {
        _registrationCloseOperations.remove(instanceId);
      }
      _decrementClosingRegistration(instanceId);
      _retireLocalInstanceIfInactive(instanceId);
    }
  }

  Future<void> _updateRegistrationPresence(
    String instanceId,
    LanGamePresence presence,
  ) async {
    _ensureActive();
    presence.validated();
    final entry = _registrations[instanceId];
    if (entry == null) throw StateError('局域网发现注册已经关闭');
    await entry.updatePresence(presence);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _discoveryUsers = 0;
    _discoveryGeneration += 1;
    final subscription = _discoverySubscription;
    _discoverySubscription = null;
    final discovery = _discovery;
    _discovery = null;
    _platformRecords.clear();
    _joinCandidates.clear();
    _retiredLocalInstanceIds.clear();
    _closingRegistrationCounts.clear();
    _registrationCloseOperations.clear();
    try {
      try {
        await subscription?.cancel();
      } finally {
        await discovery?.close();
      }
    } finally {
      final registrations = _registrations.values.toList(growable: false);
      _registrations.clear();
      for (final entry in registrations) {
        try {
          await entry.close();
        } on Object {
          // 进程退出时单个注销失败不能阻断其他资源清理。
        }
      }
      await _snapshotController.close();
    }
  }

  void _ensureActive() {
    if (_disposed) throw StateError('局域网发现服务已经关闭');
  }

  void _prepareLocalRegistration(String instanceId) {
    if (!_isLocalInstance(instanceId)) {
      _rememberRetiredLocalInstance(instanceId);
    }
    if (_removePlatformRecordsForInstance(instanceId) && _discovery != null) {
      _rebuildSnapshot(markReady: !_isDiscoveryFailureState(_snapshot.state));
    }
  }

  bool _isLocalInstance(String instanceId) =>
      _registrations.containsKey(instanceId) ||
      _registrationOperations.containsKey(instanceId) ||
      _registrationCloseOperations.containsKey(instanceId) ||
      _closingRegistrationCounts.containsKey(instanceId) ||
      _retiredLocalInstanceIds.contains(instanceId);

  void _retireLocalInstanceIfInactive(String instanceId) {
    if (_disposed ||
        _registrations.containsKey(instanceId) ||
        _registrationOperations.containsKey(instanceId) ||
        _registrationCloseOperations.containsKey(instanceId) ||
        _closingRegistrationCounts.containsKey(instanceId)) {
      return;
    }
    _rememberRetiredLocalInstance(instanceId);
  }

  void _rememberRetiredLocalInstance(String instanceId) {
    _retiredLocalInstanceIds
      ..remove(instanceId)
      ..add(instanceId);
    while (_retiredLocalInstanceIds.length > _maxRetiredLocalLanGameInstances) {
      _retiredLocalInstanceIds.remove(_retiredLocalInstanceIds.first);
    }
  }

  void _incrementClosingRegistration(String instanceId) {
    _closingRegistrationCounts.update(
      instanceId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  void _decrementClosingRegistration(String instanceId) {
    final count = _closingRegistrationCounts[instanceId];
    if (count == null || count <= 1) {
      _closingRegistrationCounts.remove(instanceId);
    } else {
      _closingRegistrationCounts[instanceId] = count - 1;
    }
  }

  bool _removePlatformRecordsForInstance(String instanceId) {
    var removed = false;
    _platformRecords.removeWhere((_, record) {
      final matches = record.instanceId == instanceId;
      removed = removed || matches;
      return matches;
    });
    return removed;
  }
}

bool _isDiscoveryFailureState(LanGameDiscoveryState state) => switch (state) {
  LanGameDiscoveryState.permissionDenied ||
  LanGameDiscoveryState.unsupported ||
  LanGameDiscoveryState.failed => true,
  LanGameDiscoveryState.scanning || LanGameDiscoveryState.ready => false,
};

class _RegistrationEntry {
  _RegistrationEntry({
    required this.advertisement,
    required this.port,
    required this.handle,
  });

  LanGameAdvertisement advertisement;
  final int port;
  final LanGamePlatformRegistration handle;
  int references = 0;
  Future<void> _operationTail = Future<void>.value();
  bool _closing = false;

  Future<void> updatePresence(LanGamePresence presence) {
    if (_closing) {
      return Future<void>.error(StateError('局域网发现注册已经关闭'));
    }
    if (advertisement.presence == presence) return Future<void>.value();
    return _serialize(() async {
      if (advertisement.presence == presence) return;
      final next = advertisement.withPresence(presence);
      final updater = handle;
      if (updater is! LanGamePlatformRegistrationUpdater) {
        throw StateError('局域网发现平台不支持原位更新');
      }
      await (updater as LanGamePlatformRegistrationUpdater).update(next);
      advertisement = next;
    });
  }

  Future<void> close() {
    if (_closing) return _operationTail;
    _closing = true;
    return _serialize(handle.close);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final current = _operationTail.then((_) => operation());
    _operationTail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return current;
  }
}

class _DiscoveredGameBuilder {
  _DiscoveredGameBuilder(this.advertisement, this._presenceRevision);

  LanGameAdvertisement advertisement;
  final Map<String, LanEndpointCandidate> _candidates = {};
  int? _port;
  int _presenceRevision;
  bool invalid = false;

  void add(LanGamePlatformResolved record) {
    if (invalid) return;
    final recordAdvertisement = LanGameAdvertisement.fromPayload(
      instanceId: record.instanceId,
      payload: record.payload,
    );
    if (recordAdvertisement.gameId != advertisement.gameId ||
        recordAdvertisement.name != advertisement.name ||
        recordAdvertisement.inviteToken != advertisement.inviteToken ||
        (_port != null && _port != record.port)) {
      invalid = true;
      _candidates.clear();
      return;
    }
    if (record.revision >= _presenceRevision) {
      advertisement = recordAdvertisement;
      _presenceRevision = record.revision;
    }
    _port = record.port;
    for (final rawAddress in record.hostAddresses) {
      final bytes = _parseIpv4(rawAddress);
      if (bytes == null ||
          bytes[0] == 0 ||
          bytes[0] == 127 ||
          bytes[0] >= 224) {
        continue;
      }
      final address = bytes.join('.');
      final classification = classifyLanAddress(bytes);
      final url = Uri(
        scheme: 'http',
        host: address,
        port: record.port,
        path: playmeshGameInvitationPath,
        fragment: Uri(
          queryParameters: {
            playmeshGameInvitationTokenParameter: advertisement.inviteToken,
          },
        ).query,
      );
      _candidates.putIfAbsent(
        address,
        () => LanEndpointCandidate(
          uri: url,
          interfaceName: '',
          interfaceIndex: 0,
          addressType: classification.type,
          risk: classification.risk,
        ),
      );
    }
  }

  List<LanEndpointCandidate> get endpointCandidates =>
      invalid ? const [] : sortLanEndpointCandidates(_candidates.values);

  DiscoveredLanGame? build() {
    final candidates = endpointCandidates;
    if (candidates.isEmpty) return null;
    return DiscoveredLanGame(
      instanceId: advertisement.instanceId,
      gameId: advertisement.gameId,
      name: advertisement.name,
      host: candidates.first.uri.authority,
      hostAddress: candidates.first.uri.host,
      presence: advertisement.presence,
    );
  }
}

List<int>? _parseIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return null;
    final byte = int.tryParse(part);
    if (byte == null || byte < 0 || byte > 255) return null;
    bytes.add(byte);
  }
  return bytes;
}
