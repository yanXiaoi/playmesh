import 'local_app_sdk_server_contract.dart';
import 'local_app_sdk_server_stub.dart'
    if (dart.library.io) 'local_app_sdk_server_io.dart'
    as implementation;

export 'local_app_sdk_server_contract.dart';

Future<LocalAppSdkServer> startLocalAppSdkServer({String? scriptSource}) {
  return implementation.startLocalAppSdkServer(scriptSource: scriptSource);
}
