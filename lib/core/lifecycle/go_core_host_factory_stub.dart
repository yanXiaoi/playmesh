import 'go_core_host_contract.dart';

GoCoreHost createBundledGoCoreHost({required String address}) {
  return _UnsupportedGoCoreHost(address);
}

class _UnsupportedGoCoreHost implements GoCoreHost {
  const _UnsupportedGoCoreHost(this.address);

  final String address;

  @override
  Uri get endpoint => Uri.parse('http://$address/health');

  @override
  Future<void> start() {
    throw const GoCoreHostException(
      code: 'unsupported_platform',
      userMessage: '当前平台暂不支持内置 Go Core。',
      diagnostic: 'dart.library.io is unavailable',
    );
  }

  @override
  Future<void> stop() async {}
}
