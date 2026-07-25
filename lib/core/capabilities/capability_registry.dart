import 'capability_plugin.dart';

class CapabilityRegistry {
  factory CapabilityRegistry(Iterable<CapabilityPlugin> plugins) =>
      CapabilityRegistry._(List<CapabilityPlugin>.of(plugins));

  CapabilityRegistry._(List<CapabilityPlugin> plugins)
    : _plugins = Map.unmodifiable({
        for (final plugin in plugins) plugin.descriptor.code: plugin,
      }) {
    if (_plugins.length != plugins.length) {
      throw ArgumentError('能力插件 code 不能重复');
    }
  }

  final Map<String, CapabilityPlugin> _plugins;

  List<CapabilityPlugin> get plugins => List.unmodifiable(_plugins.values);

  List<CapabilityDescriptor> get descriptors =>
      List.unmodifiable(_plugins.values.map((plugin) => plugin.descriptor));

  CapabilityPlugin? plugin(String code) => _plugins[code];

  CapabilityDescriptor? descriptor(String code) => _plugins[code]?.descriptor;

  bool contains(String code) => _plugins.containsKey(code);

  Future<void> dispose() async {
    await Future.wait(_plugins.values.map((plugin) => plugin.dispose()));
  }
}
