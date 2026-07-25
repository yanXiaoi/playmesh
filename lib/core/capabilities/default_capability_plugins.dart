import 'accelerometer/accelerometer_capability_plugin.dart';
import 'capability_plugin.dart';
import 'capability_registry.dart';
import 'gyroscope/gyroscope_capability_plugin.dart';
import 'support/motion_sensor_source.dart';
import 'vibration/vibration_capability_plugin.dart';
import '../platform/app_device_service.dart';

typedef DefaultCapabilityPluginFactory =
    CapabilityPlugin Function(DefaultCapabilityDependencies dependencies);

class DefaultCapabilityDependencies {
  const DefaultCapabilityDependencies({
    required this.motionSource,
    required this.deviceService,
  });

  final MotionSensorSource motionSource;
  final AppDeviceService deviceService;
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
        descriptor: AccelerometerCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) =>
            AccelerometerCapabilityPlugin(source: dependencies.motionSource),
      ),
      DefaultCapabilityRegistration(
        descriptor: GyroscopeCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) =>
            GyroscopeCapabilityPlugin(source: dependencies.motionSource),
      ),
      DefaultCapabilityRegistration(
        descriptor: VibrationCapabilityPlugin.capabilityDescriptor,
        create: (dependencies) => VibrationCapabilityPlugin(
          deviceService: dependencies.deviceService,
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
  MotionSensorSource? motionSource,
  AppDeviceService? deviceService,
}) {
  final dependencies = DefaultCapabilityDependencies(
    motionSource: motionSource ?? const NativeMotionSensorSource(),
    deviceService: deviceService ?? const AppDeviceService(),
  );
  return CapabilityRegistry(
    defaultCapabilityRegistrations.map(
      (registration) => registration.create(dependencies),
    ),
  );
}
