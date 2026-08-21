import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/network/lan_ipv4_interface_resolver_io.dart';

void main() {
  test('可绑定门禁过滤 tentative APIPA 且保留真实 link-local 与虚拟地址', () async {
    final probed = <String>[];
    final resolved = await filterBindableLanIpv4InterfaceAddresses(
      <NetworkInterface>[
        _FakeNetworkInterface(6, 'Ethernet', <String>['10.31.2.222']),
        _FakeNetworkInterface(14, 'WLAN', <String>['169.254.10.20']),
        _FakeNetworkInterface(17, 'Wi-Fi Direct', <String>['169.254.20.30']),
        _FakeNetworkInterface(33, 'Clash', <String>['198.18.0.1']),
        _FakeNetworkInterface(90, 'Invalid', <String>[
          '127.0.0.1',
          '224.0.0.1',
        ]),
      ],
      includeLinkLocal: true,
      bindProbe: (address) async {
        probed.add(address.address);
        if (address.address == '169.254.20.30') {
          throw const SocketException('Address not available');
        }
        return true;
      },
    );

    expect(resolved.map((entry) => entry.address.address), <String>[
      '10.31.2.222',
      '169.254.10.20',
      '198.18.0.1',
    ]);
    expect(probed, <String>[
      '10.31.2.222',
      '169.254.10.20',
      '169.254.20.30',
      '198.18.0.1',
    ]);
  });

  test('未显式启用 link-local 时不会探测或返回 APIPA', () async {
    final probed = <String>[];
    final resolved = await filterBindableLanIpv4InterfaceAddresses(
      <NetworkInterface>[
        _FakeNetworkInterface(6, 'Ethernet', <String>[
          '10.31.2.222',
          '169.254.10.20',
        ]),
      ],
      includeLinkLocal: false,
      bindProbe: (address) async {
        probed.add(address.address);
        return true;
      },
    );

    expect(resolved.map((entry) => entry.address.address), <String>[
      '10.31.2.222',
    ]);
    expect(probed, <String>['10.31.2.222']);
  });

  test('分享链接与 UDP 收发共用唯一可绑定地址解析器', () {
    final endpointSource = File(
      'lib/core/network/lan_endpoint_resolver_io.dart',
    ).readAsStringSync();
    final multicastSource = File(
      'lib/core/network/lan_game_discovery_platform_io.dart',
    ).readAsStringSync();
    final gatewaySource = File(
      'lib/core/game_web/game_web_gateway_io.dart',
    ).readAsStringSync();

    expect(
      endpointSource,
      contains('resolveBindableLanIpv4InterfaceAddresses'),
    );
    expect(
      _occurrences(multicastSource, 'resolveBindableLanIpv4InterfaceAddresses'),
      2,
    );
    expect(endpointSource, isNot(contains('NetworkInterface.list')));
    expect(multicastSource, isNot(contains('NetworkInterface.list')));
    expect(gatewaySource, contains('includeLinkLocal: true'));
  });
}

int _occurrences(String source, String value) =>
    value.allMatches(source).length;

final class _FakeNetworkInterface implements NetworkInterface {
  _FakeNetworkInterface(this.index, this.name, Iterable<String> addresses)
    : addresses = List<InternetAddress>.unmodifiable(
        addresses.map(InternetAddress.new),
      );

  @override
  final int index;

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;
}
