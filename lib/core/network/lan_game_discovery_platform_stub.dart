import 'lan_game_advertisement.dart';
import 'lan_game_discovery_platform.dart';

LanGameDiscoveryPlatform createLanGameDiscoveryPlatform() =>
    const _UnsupportedLanGameDiscoveryPlatform();

class _UnsupportedLanGameDiscoveryPlatform implements LanGameDiscoveryPlatform {
  const _UnsupportedLanGameDiscoveryPlatform();

  @override
  Future<LanGamePlatformRegistration> register({
    required LanGameAdvertisement advertisement,
    required int port,
  }) => throw UnsupportedError('当前平台不支持局域网发现');

  @override
  Future<LanGamePlatformDiscovery> startDiscovery() =>
      throw UnsupportedError('当前平台不支持局域网发现');
}
