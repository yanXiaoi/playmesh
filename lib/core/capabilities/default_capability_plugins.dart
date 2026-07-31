import '../app_media/app_media_runtime.dart';
import 'audio/audio_capability_plugin.dart';
import 'camera/camera_capability_plugin.dart';
import 'capability_plugin.dart';
import 'capability_registry.dart';
import 'midi/midi_capability_plugin.dart';
import 'pose6d/pose6d_capability_plugin.dart';
import 'vibration/vibration_capability_plugin.dart';
import 'web_permission/web_permission_platform_authorizer.dart';

typedef DefaultCapabilityPluginFactory =
    CapabilityPlugin Function(DefaultCapabilityDependencies dependencies);

class DefaultCapabilityDependencies {
  const DefaultCapabilityDependencies({
    required this.vibrationDriver,
    required this.webPermissionAuthorizer,
    required this.pose6dHub,
    required this.mediaSourceBroker,
  });

  final VibrationDriver vibrationDriver;
  final WebPermissionPlatformAuthorizer webPermissionAuthorizer;
  final Pose6dHub pose6dHub;
  final AppMediaSourceBroker mediaSourceBroker;
}

class DefaultCapabilityRegistration {
  const DefaultCapabilityRegistration({
    required this.descriptor,
    required this.create,
  });

  final CapabilityDescriptor descriptor;
  final DefaultCapabilityPluginFactory create;
}

final defaultCapabilityRegistrations =
    List<DefaultCapabilityRegistration>.unmodifiable([
      DefaultCapabilityRegistration(
        descriptor: CameraCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) => CameraCapabilityPlugin(
          webPermissionAuthorizer: dependencies.webPermissionAuthorizer,
        ),
      ),
      DefaultCapabilityRegistration(
        descriptor: AudioCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) => AudioCapabilityPlugin(
          webPermissionAuthorizer: dependencies.webPermissionAuthorizer,
        ),
      ),
      DefaultCapabilityRegistration(
        descriptor: MidiCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) => MidiCapabilityPlugin(
          webPermissionAuthorizer: dependencies.webPermissionAuthorizer,
        ),
      ),
      DefaultCapabilityRegistration(
        descriptor: VibrationCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) =>
            VibrationCapabilityPlugin(driver: dependencies.vibrationDriver),
      ),
      DefaultCapabilityRegistration(
        descriptor: Pose6dCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) => Pose6dCapabilityPlugin(
          hub: dependencies.pose6dHub,
          mediaSourceBroker: dependencies.mediaSourceBroker,
          permissionAuthorizer: dependencies.webPermissionAuthorizer,
        ),
      ),
    ]);

final defaultCapabilityDescriptors = List<CapabilityDescriptor>.unmodifiable(
  defaultCapabilityRegistrations.map((registration) => registration.descriptor),
);

final defaultCapabilityDescriptorRegistry =
    Map<String, CapabilityDescriptor>.unmodifiable({
      for (final descriptor in defaultCapabilityDescriptors)
        descriptor.code: descriptor,
    });

CapabilityRegistry createDefaultCapabilityRegistry({
  required AppMediaSourceBroker mediaSourceBroker,
  VibrationDriver? vibrationDriver,
  WebPermissionPlatformAuthorizer? webPermissionAuthorizer,
  Pose6dPlatformDriver? pose6dDriver,
}) {
  final dependencies = DefaultCapabilityDependencies(
    vibrationDriver: vibrationDriver ?? const NativeVibrationDriver(),
    webPermissionAuthorizer:
        webPermissionAuthorizer ??
        const DefaultWebPermissionPlatformAuthorizer(),
    pose6dHub: Pose6dHub(pose6dDriver ?? NativePose6dPlatformDriver()),
    mediaSourceBroker: mediaSourceBroker,
  );
  return CapabilityRegistry(
    defaultCapabilityRegistrations.map(
      (registration) => registration.create(dependencies),
    ),
  );
}
