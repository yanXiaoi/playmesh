import 'lan_game_advertisement.dart';
import 'lan_game_discovery_platform_stub.dart'
    if (dart.library.io) 'lan_game_discovery_platform_io.dart'
    as implementation;

abstract interface class LanGameDiscoveryPlatform {
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  });

  Future<LanGamePlatformDiscovery> startDiscovery();
}

abstract interface class LanGamePlatformRegistration {
  Future<void> close();
}

/// 只有支持原位更新的数据报注册句柄实现此窄接口。
abstract interface class LanGamePlatformRegistrationUpdater {
  Future<void> update(LanGameAdvertisement advertisement);
}

abstract interface class LanGamePlatformDiscovery {
  Stream<LanGamePlatformEvent> get events;

  Future<void> close();
}

sealed class LanGamePlatformEvent {
  const LanGamePlatformEvent();
}

/// 运行中的接收器曾失去全部可用 multicast membership，现已至少恢复一个。
class LanGamePlatformReady extends LanGamePlatformEvent {
  const LanGamePlatformReady();
}

enum LanGamePlatformFailureKind { permissionDenied, unavailable }

class LanGamePlatformFailure extends LanGamePlatformEvent {
  const LanGamePlatformFailure(this.kind);

  final LanGamePlatformFailureKind kind;
}

class LanGamePlatformException implements Exception {
  const LanGamePlatformException(this.kind);

  final LanGamePlatformFailureKind kind;
}

class LanGamePlatformResolved extends LanGamePlatformEvent {
  const LanGamePlatformResolved({
    required this.platformId,
    required this.instanceId,
    this.revision = 1,
    required this.port,
    required this.hostAddresses,
    required this.payload,
  });

  final String platformId;
  final String instanceId;
  final int revision;
  final int port;
  final List<String> hostAddresses;
  final Map<String, String> payload;
}

class LanGamePlatformLost extends LanGamePlatformEvent {
  const LanGamePlatformLost(this.platformId);

  final String platformId;
}

LanGameDiscoveryPlatform createLanGameDiscoveryPlatform() =>
    implementation.createLanGameDiscoveryPlatform();
