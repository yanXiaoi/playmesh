import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/audio_capability_plugin.dart';
import '../camera/camera_capability_plugin.dart';
import '../midi/midi_capability_plugin.dart';

enum WebPermissionResource {
  camera(platformName: 'camera', capabilityCode: CameraCapabilityPlugin.code),
  microphone(
    platformName: 'microphone',
    capabilityCode: AudioCapabilityPlugin.code,
  ),
  midiSysex(
    platformName: 'midiSysex',
    capabilityCode: MidiCapabilityPlugin.code,
  );

  const WebPermissionResource({
    required this.platformName,
    required this.capabilityCode,
  });

  final String platformName;
  final String capabilityCode;

  static WebPermissionResource? fromPlatformName(String name) {
    for (final resource in values) {
      if (resource.platformName == name) return resource;
    }
    return null;
  }
}

typedef WebPermissionPlatformAuthorizer =
    Future<bool> Function(Set<WebPermissionResource> resources);

class WebPermissionGate {
  WebPermissionGate({
    required Iterable<String> declaredCapabilities,
    WebPermissionPlatformAuthorizer? authorizePlatform,
  }) : _declaredCapabilities = Set.unmodifiable(declaredCapabilities),
       _authorizePlatform = authorizePlatform ?? _authorizeDefaultPlatform;

  static const MethodChannel _channel = MethodChannel(
    'playmesh/webview_permission',
  );

  final Set<String> _declaredCapabilities;
  final WebPermissionPlatformAuthorizer _authorizePlatform;

  Future<bool> authorizePlatformNames(Iterable<String> platformNames) async {
    final resources = <WebPermissionResource>{};
    for (final name in platformNames) {
      final resource = WebPermissionResource.fromPlatformName(name);
      if (resource == null ||
          !_declaredCapabilities.contains(resource.capabilityCode)) {
        return false;
      }
      resources.add(resource);
    }
    if (resources.isEmpty) return false;
    return _authorizePlatform(resources);
  }

  static Future<bool> _authorizeDefaultPlatform(
    Set<WebPermissionResource> resources,
  ) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final nativeResources = resources
        .where(
          (resource) =>
              resource == WebPermissionResource.camera ||
              resource == WebPermissionResource.microphone,
        )
        .map((resource) => resource.platformName)
        .toList(growable: false);
    if (nativeResources.isEmpty) return true;
    return await _channel.invokeMethod<bool>('request', {
          'resources': nativeResources,
        }) ??
        false;
  }
}
