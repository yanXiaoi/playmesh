import 'dart:io';

final class BindableLanIpv4InterfaceAddress {
  const BindableLanIpv4InterfaceAddress({
    required this.network,
    required this.address,
  });

  final NetworkInterface network;
  final InternetAddress address;
}

typedef LanIpv4AddressBindProbe =
    Future<bool> Function(InternetAddress address);

/// 枚举当前系统实际可绑定的 IPv4 地址。
///
/// Windows 可能把 Tentative/Disconnected 适配器上的自动私有地址继续返回给
/// [NetworkInterface.list]。临时绑定端口 0 是跨平台且不依赖接口名称的可用性门禁；
/// 它不会排除能够真实绑定的物理、虚拟或 link-local 地址。该门禁只证明地址仍配置在
/// 本机且可创建 socket，不探测链路对端、路由、防火墙或远端可达性。
Future<List<BindableLanIpv4InterfaceAddress>>
resolveBindableLanIpv4InterfaceAddresses({
  required bool includeLinkLocal,
}) async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: includeLinkLocal,
  );
  return filterBindableLanIpv4InterfaceAddresses(
    interfaces,
    includeLinkLocal: includeLinkLocal,
    bindProbe: _canBindLanIpv4Address,
  );
}

Future<List<BindableLanIpv4InterfaceAddress>>
filterBindableLanIpv4InterfaceAddresses(
  Iterable<NetworkInterface> interfaces, {
  required bool includeLinkLocal,
  required LanIpv4AddressBindProbe bindProbe,
}) async {
  final resolved = <BindableLanIpv4InterfaceAddress>[];
  final seen = <String>{};
  for (final network in interfaces) {
    for (final address in network.addresses) {
      if (!_isStructurallyUsableLanIpv4(address) ||
          (!includeLinkLocal && address.isLinkLocal)) {
        continue;
      }
      final key = '${network.index}\u0000${address.address}';
      if (!seen.add(key)) continue;
      var bindable = false;
      try {
        bindable = await bindProbe(address);
      } on Object {
        // 单个消失中的网卡地址不能阻断其他物理或虚拟局域网。
      }
      if (bindable) {
        resolved.add(
          BindableLanIpv4InterfaceAddress(network: network, address: address),
        );
      }
    }
  }
  return List<BindableLanIpv4InterfaceAddress>.unmodifiable(resolved);
}

Future<bool> _canBindLanIpv4Address(InternetAddress address) async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(address, 0);
    return true;
  } on Object {
    return false;
  } finally {
    socket?.close();
  }
}

bool _isStructurallyUsableLanIpv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
    return false;
  }
  final bytes = address.rawAddress;
  return bytes.length == 4 &&
      bytes.first != 0 &&
      bytes.first != 127 &&
      bytes.first < 224;
}
