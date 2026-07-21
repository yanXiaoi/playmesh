import 'go_core_host_contract.dart';
import 'go_core_host_factory_stub.dart'
    if (dart.library.io) 'go_core_host_factory_io.dart'
    as host_factory;

export 'go_core_host_contract.dart';

GoCoreHost createBundledGoCoreHost({String address = '0.0.0.0:0'}) {
  return host_factory.createBundledGoCoreHost(address: address);
}
