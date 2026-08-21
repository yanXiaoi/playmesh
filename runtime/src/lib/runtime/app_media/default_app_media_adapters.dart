import 'app_media_adapter.dart';
import 'app_media_adapter_registry.dart';
import 'app_media_runtime.dart';
import 'webrtc/webrtc_app_media_adapter.dart';

typedef DefaultAppMediaAdapterFactory =
    AppMediaAdapter Function(DefaultAppMediaAdapterDependencies dependencies);

final class DefaultAppMediaAdapterDependencies {
  const DefaultAppMediaAdapterDependencies({this.webRtcDriver});

  final WebRtcAppMediaDriver? webRtcDriver;
}

final class DefaultAppMediaAdapterRegistration {
  const DefaultAppMediaAdapterRegistration({
    required this.protocol,
    required this.create,
  });

  final String protocol;
  final DefaultAppMediaAdapterFactory create;
}

final defaultAppMediaAdapterRegistrations =
    List<DefaultAppMediaAdapterRegistration>.unmodifiable([
      DefaultAppMediaAdapterRegistration(
        protocol: 'webrtc',
        create: (dependencies) =>
            WebRtcAppMediaAdapter(driver: dependencies.webRtcDriver),
      ),
    ]);

AppMediaRuntime createDefaultAppMediaRuntime({
  WebRtcAppMediaDriver? webRtcDriver,
  Set<String>? enabledProtocols,
}) {
  final dependencies = DefaultAppMediaAdapterDependencies(
    webRtcDriver: webRtcDriver,
  );
  final adapters = [
    for (final registration in defaultAppMediaAdapterRegistrations)
      if (enabledProtocols == null ||
          enabledProtocols.contains(registration.protocol))
        registration.create(dependencies),
  ];
  for (final adapter in adapters) {
    final actual = adapter.protocol;
    final expected = defaultAppMediaAdapterRegistrations
        .singleWhere((registration) => registration.protocol == actual)
        .protocol;
    if (expected != actual) {
      throw StateError('默认媒体适配器注册协议不一致：$expected != $actual');
    }
  }
  return AppMediaRuntime.withRegistry(AppMediaAdapterRegistry(adapters));
}
