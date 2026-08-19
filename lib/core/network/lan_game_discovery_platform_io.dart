import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'lan_game_advertisement.dart';
import 'lan_game_discovery_platform.dart';
import 'lan_game_multicast_protocol.dart';
import 'lan_ipv4_interface_resolver_io.dart';

LanGameDiscoveryPlatform createLanGameDiscoveryPlatform() => Platform.isIOS
    ? const _UnsupportedIosLanGameDiscoveryPlatform()
    : const _UdpMulticastLanGameDiscoveryPlatform();

final class _UnsupportedIosLanGameDiscoveryPlatform
    implements LanGameDiscoveryPlatform {
  const _UnsupportedIosLanGameDiscoveryPlatform();

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) => throw UnsupportedError('iOS 不支持局域网自动发现');

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() =>
      throw UnsupportedError('iOS 不支持局域网自动发现');
}

final class _UdpMulticastLanGameDiscoveryPlatform
    implements LanGameDiscoveryPlatform {
  const _UdpMulticastLanGameDiscoveryPlatform();

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) async {
    advertisement.validated();
    if (port < 1 || port > 65535) {
      throw RangeError.range(port, 1, 65535, 'port');
    }
    _AndroidMulticastLock? lock;
    try {
      lock = await _AndroidMulticastLock.acquire();
      return await _UdpMulticastRegistration.open(
        advertisement: advertisement,
        port: port,
        androidLock: lock,
      );
    } on Object catch (error) {
      await lock?.close();
      if (error is LanGamePlatformException) rethrow;
      throw LanGamePlatformException(_failureKind(error));
    }
  }

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() async {
    _AndroidMulticastLock? lock;
    try {
      lock = await _AndroidMulticastLock.acquire();
      return await _UdpMulticastDiscovery.open(androidLock: lock);
    } on Object catch (error) {
      await lock?.close();
      if (error is LanGamePlatformException) rethrow;
      throw LanGamePlatformException(_failureKind(error));
    }
  }
}

final class _UdpMulticastRegistration
    implements LanGamePlatformRegistration, LanGamePlatformRegistrationUpdater {
  _UdpMulticastRegistration._(this._advertisement, this.port, this._androidLock)
    : _revision = _issueRevision();

  static Future<_UdpMulticastRegistration> open({
    required LanGameAdvertisement advertisement,
    required int port,
    required _AndroidMulticastLock androidLock,
  }) async {
    final registration = _UdpMulticastRegistration._(
      advertisement,
      port,
      androidLock,
    );
    try {
      await registration._announce(requireOne: true);
      registration._scheduleHeartbeat();
      return registration;
    } on Object {
      await registration._closeSockets();
      rethrow;
    }
  }

  final int port;
  final _AndroidMulticastLock _androidLock;
  final Map<String, _UdpMulticastSender> _senders = {};
  final Random _random = Random.secure();
  LanGameAdvertisement _advertisement;
  int _revision;
  Timer? _heartbeatTimer;
  Future<void> _operationTail = Future<void>.value();
  bool _closing = false;
  bool _closed = false;

  @override
  Future<void> update(LanGameAdvertisement advertisement) {
    if (_closing || _closed) {
      return Future<void>.error(StateError('局域网发现注册已经关闭'));
    }
    advertisement.validated();
    if (!_sameStableAdvertisement(_advertisement, advertisement)) {
      return Future<void>.error(StateError('局域网发现注册不能修改稳定分享标识'));
    }
    if (_samePayload(_advertisement.toPayload(), advertisement.toPayload())) {
      return Future<void>.value();
    }
    return _serialize(() async {
      if (_samePayload(_advertisement.toPayload(), advertisement.toPayload())) {
        return;
      }
      final revision = _issueRevision();
      await _announce(
        requireOne: true,
        advertisement: advertisement,
        revision: revision,
      );
      _advertisement = advertisement;
      _revision = revision;
    });
  }

  void _scheduleHeartbeat() {
    if (_closing || _closed) return;
    final base = lanGameMulticastAnnouncementInterval.inMilliseconds;
    final jitter = lanGameMulticastAnnouncementJitter.inMilliseconds;
    final delay = Duration(
      milliseconds: base - jitter + _random.nextInt(jitter * 2 + 1),
    );
    _heartbeatTimer = Timer(delay, () {
      unawaited(
        _serialize(
          () => _announce(requireOne: false),
        ).whenComplete(_scheduleHeartbeat).catchError((_) {
          // 周期公告失败由后续网卡 reconcile 自愈，不记录包含凭据的数据报。
        }),
      );
    });
  }

  Future<void> _announce({
    required bool requireOne,
    LanGameAdvertisement? advertisement,
    int? revision,
  }) async {
    await _reconcileSenders();
    final effectiveAdvertisement = advertisement ?? _advertisement;
    final message = LanGameMulticastMessage(
      kind: LanGameMulticastMessageKind.announcement,
      instanceId: effectiveAdvertisement.instanceId,
      revision: revision ?? _revision,
      gatewayPort: port,
      payload: effectiveAdvertisement.toPayload(),
    ).encode();
    var successes = 0;
    final failedSenders = <String>[];
    for (final entry in _senders.entries.toList(growable: false)) {
      try {
        if (entry.value.send(message)) {
          successes += 1;
        } else {
          failedSenders.add(entry.key);
        }
      } on Object {
        // 单个网卡失败不能阻断其他物理或虚拟局域网。
        failedSenders.add(entry.key);
      }
    }
    for (final key in failedSenders) {
      _senders.remove(key)?.close();
    }
    if (requireOne && successes == 0) {
      throw const LanGamePlatformException(
        LanGamePlatformFailureKind.unavailable,
      );
    }
  }

  Future<void> _reconcileSenders() async {
    final addresses = await resolveBindableLanIpv4InterfaceAddresses(
      includeLinkLocal: true,
    );
    final desired =
        <String, ({NetworkInterface network, InternetAddress address})>{};
    for (final entry in addresses) {
      desired['${entry.network.index}\u0000${entry.address.address}'] = (
        network: entry.network,
        address: entry.address,
      );
    }
    for (final key in _senders.keys.toList(growable: false)) {
      if (!desired.containsKey(key) || !_senders[key]!.healthy) {
        _senders.remove(key)?.close();
      }
    }
    for (final entry in desired.entries) {
      if (_senders.containsKey(entry.key)) continue;
      try {
        _senders[entry.key] = await _UdpMulticastSender.open(
          network: entry.value.network,
          address: entry.value.address,
        );
      } on Object {
        // Dart 没有 multicast-capable 标志，只能逐接口尝试并隔离失败。
      }
    }
  }

  Future<void> _closeSockets() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    for (final sender in _senders.values.toList(growable: false)) {
      sender.close();
    }
    _senders.clear();
  }

  Future<void> _sendGoodbye() async {
    try {
      await _reconcileSenders();
      final bytes = LanGameMulticastMessage(
        kind: LanGameMulticastMessageKind.goodbye,
        instanceId: _advertisement.instanceId,
        revision: _revision,
      ).encode();
      for (final sender in _senders.values.toList(growable: false)) {
        try {
          sender.send(bytes);
        } on Object {
          // goodbye 只优化立即移除，TTL 仍是最终兜底。
        }
      }
    } on Object {
      // 关闭必须继续释放 socket 与 Android MulticastLock。
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _operationTail.then((_) => action());
    _operationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    if (_closing) return _operationTail;
    _closing = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    return _serialize(() async {
      try {
        await _sendGoodbye();
      } finally {
        try {
          await _closeSockets();
        } finally {
          _closed = true;
          await _androidLock.close();
        }
      }
    });
  }
}

final class _UdpMulticastSender {
  _UdpMulticastSender._(this._socket);

  static Future<_UdpMulticastSender> open({
    required NetworkInterface network,
    required InternetAddress address,
  }) async {
    final socket = await RawDatagramSocket.bind(address, 0);
    try {
      socket
        ..readEventsEnabled = false
        ..writeEventsEnabled = false
        ..broadcastEnabled = false
        // 允许同一 OS 上的其他 Playmesh 进程接收；Service 按本机 instance
        // 过滤自身公告，不能用 socket 级 loopback 一并屏蔽其他进程。
        ..multicastLoopback = true
        ..multicastHops = 1;
      socket.setRawOption(
        RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          Uint8List.fromList(address.rawAddress),
        ),
      );
      return _UdpMulticastSender._(socket)..listenForErrors();
    } on Object {
      socket.close();
      rethrow;
    }
  }

  final RawDatagramSocket _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  bool _healthy = true;

  bool get healthy => _healthy;

  void listenForErrors() {
    _subscription = _socket.listen(
      (_) {},
      onError: (Object _) {
        // send() 只表示数据已交给 OS；异步本地错误会在下一轮公告前标记重建。
        _healthy = false;
      },
      onDone: () => _healthy = false,
    );
  }

  bool send(List<int> bytes) =>
      _healthy &&
      _socket.send(
            bytes,
            InternetAddress(lanGameMulticastAddress),
            lanGameMulticastPort,
          ) ==
          bytes.length;

  void close() {
    _healthy = false;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _socket.close();
  }
}

final class _UdpMulticastDiscovery implements LanGamePlatformDiscovery {
  _UdpMulticastDiscovery._({required this._socket, required this._androidLock});

  static Future<_UdpMulticastDiscovery> open({
    required _AndroidMulticastLock androidLock,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      lanGameMulticastPort,
      reuseAddress: true,
      reusePort: Platform.isMacOS,
    );
    final discovery = _UdpMulticastDiscovery._(
      socket: socket,
      androidLock: androidLock,
    );
    try {
      await discovery._start();
      return discovery;
    } on Object {
      try {
        await discovery._closeResources();
      } finally {
        await discovery._events.close();
      }
      rethrow;
    }
  }

  final RawDatagramSocket _socket;
  final _AndroidMulticastLock _androidLock;
  final StreamController<LanGamePlatformEvent> _events =
      StreamController<LanGamePlatformEvent>();
  final LanGameMulticastCache _cache = LanGameMulticastCache();
  final Stopwatch _clock = Stopwatch()..start();
  final Map<String, NetworkInterface> _joinedInterfaces = {};
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _maintenanceTimer;
  int _generation = 0;
  bool _closing = false;
  bool _closed = false;
  bool _reportedUnavailable = false;
  bool _draining = false;
  Future<void>? _closeOperation;

  @override
  Stream<LanGamePlatformEvent> get events => _events.stream;

  Future<void> _start() async {
    _socket
      ..writeEventsEnabled = false
      ..broadcastEnabled = false
      // Winsock 将 IP_MULTICAST_LOOP 应用于接收 socket；保持开启才能让同一
      // Windows 主机上的其他进程互相发现。Service 仅过滤本进程 instance。
      ..multicastLoopback = true;
    _socketSubscription = _socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          _drainDatagrams();
        } else if (event == RawSocketEvent.closed &&
            !_closing &&
            !_events.isClosed) {
          _events.add(
            const LanGamePlatformFailure(
              LanGamePlatformFailureKind.unavailable,
            ),
          );
        }
      },
      onError: (Object error) {
        if (!_closing && !_events.isClosed) {
          _events.add(LanGamePlatformFailure(_failureKind(error)));
        }
      },
    );
    await _reconcileInterfaces(generation: _generation);
    _scheduleMaintenance();
  }

  void _drainDatagrams() {
    if (_closing || _draining) return;
    _draining = true;
    try {
      var handled = 0;
      Datagram? datagram;
      while (handled < 64 && (datagram = _socket.receive()) != null) {
        handled += 1;
        for (final event in _cache.accept(
          datagram: datagram!.data,
          sourceAddress: datagram.address.address,
          now: _clock.elapsed,
        )) {
          _emitCacheEvent(event);
        }
      }
      if (handled == 64) Timer.run(_drainDatagrams);
    } finally {
      _draining = false;
    }
  }

  void _emitCacheEvent(LanGameMulticastCacheEvent event) {
    if (_closing || _events.isClosed) return;
    switch (event) {
      case LanGameMulticastCacheResolved():
        _events.add(
          LanGamePlatformResolved(
            platformId: event.platformId,
            instanceId: event.instanceId,
            revision: event.revision,
            port: event.gatewayPort,
            hostAddresses: <String>[event.sourceAddress],
            payload: event.payload,
          ),
        );
      case LanGameMulticastCacheLost():
        _events.add(LanGamePlatformLost(event.platformId));
    }
  }

  void _scheduleMaintenance() {
    if (_closing) return;
    final generation = _generation;
    _maintenanceTimer = Timer(lanGameMulticastInterfaceReconcileInterval, () {
      unawaited(_maintain(generation));
    });
  }

  Future<void> _maintain(int generation) async {
    if (_closing || generation != _generation) return;
    var recovered = false;
    try {
      recovered = await _reconcileInterfaces(generation: generation);
    } on Object {
      if (!_reportedUnavailable && !_events.isClosed) {
        _reportedUnavailable = true;
        _events.add(
          const LanGamePlatformFailure(LanGamePlatformFailureKind.unavailable),
        );
      }
    }
    if (_closing || generation != _generation) return;
    for (final lost in _cache.expire(_clock.elapsed)) {
      _emitCacheEvent(lost);
    }
    if (recovered && !_events.isClosed) {
      _events.add(const LanGamePlatformReady());
    }
    _scheduleMaintenance();
  }

  Future<bool> _reconcileInterfaces({required int generation}) async {
    final addresses = await resolveBindableLanIpv4InterfaceAddresses(
      includeLinkLocal: true,
    );
    if (_closing || generation != _generation) return false;
    final desired = _desiredIpv4Memberships(addresses);
    for (final key in _joinedInterfaces.keys.toList(growable: false)) {
      final previous = _joinedInterfaces[key]!;
      final next = desired[key];
      if (next == null || !_sameInterfaceAddresses(previous, next)) {
        try {
          _socket.leaveMulticast(
            InternetAddress(lanGameMulticastAddress),
            previous,
          );
        } on Object {
          // 网卡已消失时 leave 失败不影响其他成员关系和 socket 关闭。
        }
        _joinedInterfaces.remove(key);
      }
    }
    for (final entry in desired.entries) {
      if (_joinedInterfaces.containsKey(entry.key)) continue;
      try {
        _socket.joinMulticast(
          InternetAddress(lanGameMulticastAddress),
          entry.value,
        );
        _joinedInterfaces[entry.key] = entry.value;
      } on Object {
        // 无 capability 标志，单网卡 join 失败必须隔离并在下轮重试。
      }
    }
    if (_joinedInterfaces.isNotEmpty) {
      final recovered = _reportedUnavailable;
      _reportedUnavailable = false;
      return recovered;
    }
    throw const LanGamePlatformException(
      LanGamePlatformFailureKind.unavailable,
    );
  }

  Future<void> _closeResources() async {
    _generation += 1;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    for (final network in _joinedInterfaces.values.toList(growable: false)) {
      try {
        _socket.leaveMulticast(
          InternetAddress(lanGameMulticastAddress),
          network,
        );
      } on Object {
        // socket close 会最终释放仍存在的成员关系。
      }
    }
    _joinedInterfaces.clear();
    _cache.clear();
    _socket.close();
  }

  @override
  Future<void> close() => _closeOperation ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    try {
      await _closeResources();
    } finally {
      _closed = true;
      try {
        await _events.close();
      } finally {
        await _androidLock.close();
      }
    }
  }
}

Map<String, NetworkInterface> _desiredIpv4Memberships(
  List<BindableLanIpv4InterfaceAddress> entries,
) {
  final desired = <String, NetworkInterface>{};
  if (Platform.isMacOS) {
    // Dart VM 在 macOS 的 IPv4 joinMulticast 只读取 NetworkInterface 中的
    // 第一个 IPv4 地址，因此多地址网卡必须按地址建立独立 membership view。
    for (final entry in entries) {
      desired['${entry.network.index}\u0000${entry.address.address}'] =
          _Ipv4InterfaceView(entry.network, <InternetAddress>[entry.address]);
    }
    return desired;
  }
  final grouped = <int, _Ipv4InterfaceGroup>{};
  for (final entry in entries) {
    final group = grouped.putIfAbsent(
      entry.network.index,
      () => _Ipv4InterfaceGroup(entry.network),
    );
    group.addresses.add(entry.address);
  }
  for (final entry in grouped.entries) {
    desired[entry.key.toString()] = _Ipv4InterfaceView(
      entry.value.network,
      entry.value.addresses,
    );
  }
  return desired;
}

final class _Ipv4InterfaceGroup {
  _Ipv4InterfaceGroup(this.network);

  final NetworkInterface network;
  final List<InternetAddress> addresses = <InternetAddress>[];
}

final class _Ipv4InterfaceView implements NetworkInterface {
  _Ipv4InterfaceView(
    NetworkInterface source,
    Iterable<InternetAddress> addresses,
  ) : name = source.name,
      index = source.index,
      addresses = List<InternetAddress>.unmodifiable(addresses);

  @override
  final String name;

  @override
  final int index;

  @override
  final List<InternetAddress> addresses;
}

bool _sameInterfaceAddresses(NetworkInterface left, NetworkInterface right) {
  final leftAddresses =
      left.addresses
          .where((address) => address.type == InternetAddressType.IPv4)
          .map((address) => address.address)
          .toList(growable: false)
        ..sort();
  final rightAddresses =
      right.addresses
          .where((address) => address.type == InternetAddressType.IPv4)
          .map((address) => address.address)
          .toList(growable: false)
        ..sort();
  if (leftAddresses.length != rightAddresses.length) return false;
  for (var index = 0; index < leftAddresses.length; index += 1) {
    if (leftAddresses[index] != rightAddresses[index]) return false;
  }
  return true;
}

bool _sameStableAdvertisement(
  LanGameAdvertisement left,
  LanGameAdvertisement right,
) =>
    left.instanceId == right.instanceId &&
    left.gameId == right.gameId &&
    left.name == right.name &&
    left.inviteToken == right.inviteToken;

bool _samePayload(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

int _lastIssuedRevision = 0;

int _issueRevision() {
  final wallClock = DateTime.now().microsecondsSinceEpoch;
  final next = max(wallClock, _lastIssuedRevision + 1);
  if (next > maxLanGameMulticastRevision) {
    throw StateError('局域网发现 revision 已耗尽');
  }
  _lastIssuedRevision = next;
  return next;
}

LanGamePlatformFailureKind _failureKind(Object error) {
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return LanGamePlatformFailureKind.permissionDenied;
    }
  }
  if (error is SocketException) {
    final message = error.message.toLowerCase();
    final code = error.osError?.errorCode;
    if (code == 1 || code == 13 || message.contains('permission')) {
      return LanGamePlatformFailureKind.permissionDenied;
    }
  }
  return LanGamePlatformFailureKind.unavailable;
}

final class _AndroidMulticastLock {
  _AndroidMulticastLock._(this._holderId);

  static const MethodChannel _channel = MethodChannel(
    'playmesh/lan_multicast_lock',
  );

  static int _nextHolderId = 0;
  static final Set<String> _pendingReleases = <String>{};

  String? _holderId;

  static Future<_AndroidMulticastLock> acquire() async {
    if (!Platform.isAndroid) return _AndroidMulticastLock._(null);
    if (_pendingReleases.isNotEmpty) {
      await _channel.invokeMethod<void>(
        'releaseMany',
        _pendingReleases.toList(growable: false),
      );
      _pendingReleases.clear();
    }
    final holderId = 'dart-${_nextHolderId++}';
    try {
      await _channel.invokeMethod<void>('acquire', holderId);
    } on Object {
      // Native 可能已成功持锁、但结果回包在通道中断时丢失。release 是幂等的，
      // 因此把这个 ID 纳入补偿队列，避免下一次 Activity 连接后永久泄漏。
      _pendingReleases.add(holderId);
      rethrow;
    }
    return _AndroidMulticastLock._(holderId);
  }

  Future<void> close() async {
    final holderId = _holderId;
    if (holderId == null) return;
    _holderId = null;
    try {
      await _channel.invokeMethod<void>('release', holderId);
    } on Object {
      // Activity 空窗期间保留 holder，下一次 acquire 会先幂等补偿释放。
      _pendingReleases.add(holderId);
    }
  }
}
