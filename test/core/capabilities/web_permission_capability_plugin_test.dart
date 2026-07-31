import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/audio/audio_capability_plugin.dart';
import 'package:playmesh/core/capabilities/camera/camera_capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_registry.dart';
import 'package:playmesh/core/capabilities/midi/midi_capability_plugin.dart';
import 'package:playmesh/core/capabilities/web_permission/capability_web_permission.dart';
import 'package:playmesh/core/capabilities/web_permission/web_permission_platform_authorizer.dart';

void main() {
  test('权限型能力复用能力 code 注册唯一执行器与 WebView 资源映射', () async {
    final authorizer = _RecordingPlatformAuthorizer();
    final camera = CameraCapabilityPlugin(webPermissionAuthorizer: authorizer);
    final microphone = AudioCapabilityPlugin(
      webPermissionAuthorizer: authorizer,
    );
    final midi = MidiCapabilityPlugin(webPermissionAuthorizer: authorizer);
    final registry = CapabilityRegistry([
      camera,
      microphone,
      midi,
    ], platform: CapabilityPlatform.ANDROID);
    addTearDown(registry.dispose);

    expect(
      registry.webPermissionCapabilityCode('camera'),
      CameraCapabilityPlugin.code,
    );
    expect(
      registry.webPermissionCapabilityCode('microphone'),
      AudioCapabilityPlugin.code,
    );
    expect(
      registry.webPermissionCapabilityCode('midiSysex'),
      MidiCapabilityPlugin.code,
    );
    expect(
      identical(camera.webPermissionExecutor, camera.webPermissionExecutor),
      isTrue,
    );
    expect(
      identical(
        microphone.webPermissionExecutor,
        microphone.webPermissionExecutor,
      ),
      isTrue,
    );
    expect(
      identical(midi.webPermissionExecutor, midi.webPermissionExecutor),
      isTrue,
    );

    final context = CapabilityWebPermissionContext(
      role: AppWebPermissionRole.authority,
      requestedResources: const ['camera'],
      declaredCapabilities: const ['media.camera'],
    );
    await camera.webPermissionExecutor.authorize(context);
    await microphone.webPermissionExecutor.authorize(context);
    await midi.webPermissionExecutor.authorize(context);
    expect(authorizer.requests.map((request) => request.androidPermissions), [
      ['android.permission.CAMERA'],
      ['android.permission.RECORD_AUDIO'],
      <String>[],
    ]);
  });

  test('统一注册表按当前角色声明解析 code 并按能力执行一次', () async {
    var cameraAuthorizations = 0;
    var microphoneAuthorizations = 0;
    CapabilityWebPermissionContext? cameraContext;
    final registry = CapabilityRegistry([
      _FakePermissionPlugin(
        code: 'media.camera',
        resources: const ['camera', 'cameraPanTiltZoom'],
        authorize: (context) async {
          cameraAuthorizations += 1;
          cameraContext = context;
          return true;
        },
      ),
      _FakePermissionPlugin(
        code: 'media.microphone',
        resources: const ['microphone'],
        authorize: (_) async {
          microphoneAuthorizations += 1;
          return true;
        },
      ),
    ], platform: CapabilityPlatform.ANDROID);
    addTearDown(registry.dispose);

    expect(
      await registry.authorizeWebPermissions(
        resources: ['camera'],
        declaredCapabilities: ['media.camera'],
        role: AppWebPermissionRole.joiner,
        sourceUri: Uri.parse('http://127.0.0.1/controller/'),
        isUserInitiated: true,
      ),
      isTrue,
    );
    expect(cameraAuthorizations, 1);
    expect(cameraContext?.role, AppWebPermissionRole.joiner);
    expect(cameraContext?.requestedResources, ['camera']);
    expect(cameraContext?.declaredCapabilities, ['media.camera']);
    expect(cameraContext?.sourceUri?.path, '/controller/');
    expect(cameraContext?.isUserInitiated, isTrue);

    expect(
      await registry.authorizeWebPermissions(
        resources: ['camera', 'microphone'],
        declaredCapabilities: ['media.camera'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
    expect(cameraAuthorizations, 1);
    expect(microphoneAuthorizations, 0);

    expect(
      await registry.authorizeWebPermissions(
        resources: ['camera', 'cameraPanTiltZoom', 'microphone'],
        declaredCapabilities: ['media.camera', 'media.microphone'],
        role: AppWebPermissionRole.authority,
      ),
      isTrue,
    );
    expect(cameraAuthorizations, 2);
    expect(microphoneAuthorizations, 1);
  });

  test('统一层对空、未知、不可用和执行器拒绝的权限默认拒绝', () async {
    final registry = CapabilityRegistry([
      _FakePermissionPlugin(
        code: 'media.camera',
        resources: const ['camera'],
        authorize: (_) async => false,
      ),
      _FakePermissionPlugin(
        code: 'device.midi',
        resources: const ['midiSysex'],
        available: false,
      ),
    ], platform: CapabilityPlatform.ANDROID);
    addTearDown(registry.dispose);

    expect(
      await registry.authorizeWebPermissions(
        resources: const [],
        declaredCapabilities: const ['media.camera'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
    expect(
      await registry.authorizeWebPermissions(
        resources: const ['protectedMediaId'],
        declaredCapabilities: const ['media.camera'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
    expect(
      await registry.authorizeWebPermissions(
        resources: const ['midiSysex'],
        declaredCapabilities: const ['device.midi'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
    expect(
      await registry.authorizeWebPermissions(
        resources: const ['camera'],
        declaredCapabilities: const ['media.camera'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
  });

  test('注册表先按 supportedPlatforms 判断当前平台', () async {
    var authorizations = 0;
    final plugin = _FakePermissionPlugin(
      code: 'android.only',
      resources: const ['camera'],
      authorize: (_) async {
        authorizations += 1;
        return true;
      },
    );
    final registry = CapabilityRegistry([
      plugin,
    ], platform: CapabilityPlatform.WINDOWS);
    addTearDown(registry.dispose);

    expect(plugin.isAvailable, isTrue);
    expect(registry.isPlatformSupported(plugin.descriptor), isFalse);
    expect(registry.isPluginAvailable(plugin), isFalse);
    expect(registry.isAvailable(plugin.descriptor.code), isFalse);
    expect(
      await registry.authorizeWebPermissions(
        resources: const ['camera'],
        declaredCapabilities: const ['android.only'],
        role: AppWebPermissionRole.authority,
      ),
      isFalse,
    );
    expect(authorizations, 0);
  });

  test('注册表拒绝空或重复的平台列表', () {
    expect(
      () => CapabilityRegistry([
        _FakePermissionPlugin(
          code: 'empty-platforms',
          resources: const ['camera'],
          supportedPlatforms: const [],
        ),
      ]),
      throwsArgumentError,
    );
    expect(
      () => CapabilityRegistry([
        _FakePermissionPlugin(
          code: 'duplicate-platforms',
          resources: const ['camera'],
          supportedPlatforms: const [
            CapabilityPlatform.ANDROID,
            CapabilityPlatform.ANDROID,
          ],
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('重复注册同一个 WebView 权限资源会被拒绝', () {
    expect(
      () => CapabilityRegistry([
        _FakePermissionPlugin(code: 'one', resources: const ['camera']),
        _FakePermissionPlugin(code: 'two', resources: const ['camera']),
      ]),
      throwsArgumentError,
    );
  });

  test('单个能力不能注册空资源或重复资源', () {
    expect(
      () => CapabilityRegistry([
        _FakePermissionPlugin(code: 'empty', resources: const []),
      ]),
      throwsArgumentError,
    );
    expect(
      () => CapabilityRegistry([
        _FakePermissionPlugin(
          code: 'duplicate',
          resources: const ['camera', 'camera'],
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('权限声明型插件没有实例方法和事件', () async {
    final plugin = CameraCapabilityPlugin();
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

class _RecordingPlatformAuthorizer implements WebPermissionPlatformAuthorizer {
  final List<WebPermissionPlatformRequest> requests = [];

  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async {
    requests.add(request);
    return true;
  }
}

class _FakePermissionPlugin
    implements CapabilityPlugin, CapabilityWebPermissionPlugin {
  _FakePermissionPlugin({
    required String code,
    required List<String> resources,
    this.available = true,
    List<CapabilityPlatform> supportedPlatforms = const [
      CapabilityPlatform.ANDROID,
    ],
    CapabilityWebPermissionAuthorize? authorize,
  }) : descriptor = CapabilityDescriptor(
         code: code,
         name: code,
         description: code,
         apiVersion: '1.0.0',
         supportedPlatforms: supportedPlatforms,
         methods: const [],
         events: const [],
       ),
       webPermissionResources = resources,
       webPermissionExecutor = CapabilityWebPermissionExecutor(
         authorize: authorize ?? _allow,
       );

  @override
  final CapabilityDescriptor descriptor;

  @override
  final List<String> webPermissionResources;

  @override
  final CapabilityWebPermissionExecutor webPermissionExecutor;

  final bool available;

  @override
  bool get isAvailable => available;

  @override
  Future<CapabilityInstance> create(CapabilityJson options) async =>
      _FakeCapabilityInstance();

  @override
  Future<void> dispose() async {}

  static Future<bool> _allow(CapabilityWebPermissionContext _) async => true;
}

class _FakeCapabilityInstance implements CapabilityInstance {
  @override
  Stream<CapabilityInstanceEvent> get events => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<Object?> invoke(String method, CapabilityJson arguments) async => null;
}
