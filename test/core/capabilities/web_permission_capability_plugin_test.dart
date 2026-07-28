import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/audio/audio_capability_plugin.dart';
import 'package:playmesh/core/capabilities/camera/camera_capability_plugin.dart';
import 'package:playmesh/core/capabilities/midi/midi_capability_plugin.dart';
import 'package:playmesh/core/capabilities/web_permission/web_permission_gate.dart';

void main() {
  test('权限资源和能力 code 使用插件内的唯一映射', () {
    expect(
      WebPermissionResource.camera.capabilityCode,
      CameraCapabilityPlugin.code,
    );
    expect(
      WebPermissionResource.microphone.capabilityCode,
      AudioCapabilityPlugin.code,
    );
    expect(
      WebPermissionResource.midiSysex.capabilityCode,
      MidiCapabilityPlugin.code,
    );
  });

  test('已声明的 WebView 权限才交给平台授权', () async {
    Set<WebPermissionResource>? requested;
    final gate = WebPermissionGate(
      declaredCapabilities: const ['media.camera', 'device.midi'],
      authorizePlatform: (resources) async {
        requested = resources;
        return true;
      },
    );

    expect(await gate.authorizePlatformNames(['camera']), isTrue);
    expect(requested, {WebPermissionResource.camera});

    requested = null;
    expect(await gate.authorizePlatformNames(['microphone']), isFalse);
    expect(requested, isNull);

    expect(
      await gate.authorizePlatformNames(['camera', 'microphone']),
      isFalse,
    );
    expect(await gate.authorizePlatformNames(['midiSysex']), isTrue);
    expect(requested, {WebPermissionResource.midiSysex});
  });

  test('未知或空的 WebView 权限请求默认拒绝', () async {
    final gate = WebPermissionGate(
      declaredCapabilities: const [
        'media.camera',
        'media.microphone',
        'device.midi',
      ],
      authorizePlatform: (_) async => true,
    );

    expect(await gate.authorizePlatformNames(const []), isFalse);
    expect(await gate.authorizePlatformNames(['protectedMediaId']), isFalse);
  });

  test('权限声明型插件没有方法和事件', () async {
    const plugin = CameraCapabilityPlugin();
    final instance = await plugin.create(const {});
    addTearDown(instance.dispose);

    expect(plugin.descriptor.methods, isEmpty);
    expect(plugin.descriptor.events, isEmpty);
    expect(
      () => instance.invoke('capture', const {}),
      throwsA(isA<FormatException>()),
    );
  });
}
