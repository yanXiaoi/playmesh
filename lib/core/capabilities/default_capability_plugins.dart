import 'audio/audio_capability_plugin.dart';
import 'camera/camera_capability_plugin.dart';
import 'capability_plugin.dart';
import 'capability_registry.dart';
import 'midi/midi_capability_plugin.dart';
import 'vibration/vibration_capability_plugin.dart';

typedef DefaultCapabilityPluginFactory =
    CapabilityPlugin Function(DefaultCapabilityDependencies dependencies);

class DefaultCapabilityDependencies {
  const DefaultCapabilityDependencies({required this.vibrationDriver});

  final VibrationDriver vibrationDriver;
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
        create: (_) => const CameraCapabilityPlugin(),
      ),
      DefaultCapabilityRegistration(
        descriptor: AudioCapabilityPlugin.capabilityDescriptor,
        create: (_) => AudioCapabilityPlugin(),
      ),
      DefaultCapabilityRegistration(
        descriptor: MidiCapabilityPlugin.capabilityDescriptor,
        create: (_) => const MidiCapabilityPlugin(),
      ),
      DefaultCapabilityRegistration(
        descriptor: VibrationCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) =>
            VibrationCapabilityPlugin(driver: dependencies.vibrationDriver),
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
  VibrationDriver? vibrationDriver,
}) {
  final dependencies = DefaultCapabilityDependencies(
    vibrationDriver: vibrationDriver ?? const NativeVibrationDriver(),
  );
  return CapabilityRegistry(
    defaultCapabilityRegistrations.map(
      (registration) => registration.create(dependencies),
    ),
  );
}
