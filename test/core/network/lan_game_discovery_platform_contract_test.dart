import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('生产发现只有自定义 UDP multicast 且不依赖默认多播网卡', () {
    final source = File(
      'lib/core/network/lan_game_discovery_platform_io.dart',
    ).readAsStringSync();
    final interfaceResolver = File(
      'lib/core/network/lan_ipv4_interface_resolver_io.dart',
    ).readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(source, contains('RawDatagramSocket.bind'));
    expect(source, contains('reuseAddress: true'));
    expect(source, contains('reusePort: Platform.isMacOS'));
    expect(source, isNot(contains('reusePort: !Platform.isWindows')));
    expect(source, contains('joinMulticast'));
    expect(interfaceResolver, contains('NetworkInterface.list'));
    expect(interfaceResolver, contains('RawDatagramSocket.bind(address, 0)'));
    expect(source, contains('includeLinkLocal: true'));
    expect(source, contains('RawSocketOption.IPv4MulticastInterface'));
    expect(source, contains('Uint8List.fromList(address.rawAddress)'));
    expect(source, contains('multicastHops = 1'));
    expect(_occurrences(source, 'multicastLoopback = true'), 2);
    expect(source, isNot(contains('multicastLoopback = false')));
    expect(source, contains('_Ipv4InterfaceView('));
    expect(source, contains('Platform.isMacOS'));
    expect(source, contains('LanGamePlatformReady'));
    expect(source, contains('Timer.run(_drainDatagrams)'));
    expect(source, isNot(contains('scheduleMicrotask(_drainDatagrams)')));
    expect(source, contains('_socket.listen('));
    expect(source, contains('_healthy = false'));
    expect(source, contains('!_senders[key]!.healthy'));
    expect(
      _occurrences(source, '_pendingReleases.add(holderId)'),
      greaterThanOrEqualTo(2),
    );
    expect(source, isNot(contains('.multicastInterface =')));
    expect(source.toLowerCase(), isNot(contains('bonsoir')));
    expect(pubspec.toLowerCase(), isNot(contains('bonsoir')));
  });

  test('iOS 在打开 socket 或 Android lock 前明确返回 unsupported', () {
    final source = File(
      'lib/core/network/lan_game_discovery_platform_io.dart',
    ).readAsStringSync();
    final factoryIndex = source.indexOf(
      'createLanGameDiscoveryPlatform() => Platform.isIOS',
    );
    final socketIndex = source.indexOf('RawDatagramSocket.bind');

    expect(factoryIndex, greaterThanOrEqualTo(0));
    expect(socketIndex, greaterThan(factoryIndex));
    expect(source, contains("throw UnsupportedError('iOS 不支持局域网自动发现')"));
  });

  test('平台只使用 Datagram source address 构造发现地址且不记录原始包', () {
    final source = File(
      'lib/core/network/lan_game_discovery_platform_io.dart',
    ).readAsStringSync();

    expect(source, contains('sourceAddress: datagram.address.address'));
    expect(source, contains('hostAddresses: <String>[event.sourceAddress]'));
    expect(source, isNot(matches(RegExp(r'print\s*\('))));
    expect(source, isNot(contains('debugPrint')));
  });

  test('主 App 与 Runtime 复用可绑定 IPv4 解析结果启动 Core TURN', () {
    final appHost = File(
      'lib/core/lifecycle/go_core_host_factory_io.dart',
    ).readAsStringSync();
    final runtimeHost = File(
      'runtime/src/lib/runtime/runtime_go_core.dart',
    ).readAsStringSync();
    final appAndroid = File(
      'android/app/src/main/java/top/zfjmm/playmesh/MainActivity.java',
    ).readAsStringSync();
    final runtimeAndroid = File(
      'runtime/src/android/app/src/main/java/top/zfjmm/playmesh_runtime/MainActivity.java',
    ).readAsStringSync();

    for (final source in [appHost, runtimeHost]) {
      expect(source, contains('resolveBindableLanIpv4InterfaceAddresses('));
      expect(source, contains('includeLinkLocal: false'));
      expect(source, contains("'localTurnAddresses'"));
      expect(source, contains("'-local-turn-addresses'"));
      expect(source, isNot(contains('NetworkInterface.list(')));
    }
    for (final source in [appAndroid, runtimeAndroid]) {
      expect(source, contains('Mobile.startWithLocalTURNAddresses('));
      expect(source, contains('localTurnAddresses'));
    }
  });
}

int _occurrences(String source, String value) =>
    value.allMatches(source).length;
