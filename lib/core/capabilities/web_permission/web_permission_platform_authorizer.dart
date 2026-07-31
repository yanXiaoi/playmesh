import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WebPermissionPlatformRequest {
  const WebPermissionPlatformRequest({
    this.androidPermissions = const <String>[],
  });

  final List<String> androidPermissions;
}

abstract interface class WebPermissionPlatformAuthorizer {
  Future<bool> authorize(WebPermissionPlatformRequest request);
}

class DefaultWebPermissionPlatformAuthorizer
    implements WebPermissionPlatformAuthorizer {
  const DefaultWebPermissionPlatformAuthorizer();

  static const MethodChannel _channel = MethodChannel(
    'playmesh/webview_permission',
  );

  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android ||
        request.androidPermissions.isEmpty) {
      return true;
    }
    return await _channel.invokeMethod<bool>('request', {
          'permissions': request.androidPermissions,
        }) ??
        false;
  }
}
