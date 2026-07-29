import 'capability_plugin.dart';
import 'web_permission/capability_web_permission.dart';

class CapabilityRegistry {
  factory CapabilityRegistry(Iterable<CapabilityPlugin> plugins) {
    final pluginList = List<CapabilityPlugin>.of(plugins);
    final pluginMap = <String, CapabilityPlugin>{};
    final webPermissionCodeByResource = <String, String>{};
    final webPermissionExecutorByCode =
        <String, CapabilityWebPermissionExecutor>{};
    for (final plugin in pluginList) {
      final code = plugin.descriptor.code;
      if (code.isEmpty || pluginMap.containsKey(code)) {
        throw ArgumentError('能力插件 code 不能为空或重复');
      }
      pluginMap[code] = plugin;
      if (plugin case final CapabilityWebPermissionPlugin permissionPlugin) {
        final resources = permissionPlugin.webPermissionResources.toSet();
        if (resources.isEmpty ||
            resources.length !=
                permissionPlugin.webPermissionResources.length) {
          throw ArgumentError('能力 $code 的 WebView 权限资源不能为空或重复');
        }
        webPermissionExecutorByCode[code] =
            permissionPlugin.webPermissionExecutor;
        for (final resource in resources) {
          if (resource.isEmpty ||
              webPermissionCodeByResource.containsKey(resource)) {
            throw ArgumentError('WebView 权限资源不能为空或重复：$resource');
          }
          webPermissionCodeByResource[resource] = code;
        }
      }
    }
    return CapabilityRegistry._(
      pluginMap: pluginMap,
      webPermissionCodeByResource: webPermissionCodeByResource,
      webPermissionExecutorByCode: webPermissionExecutorByCode,
    );
  }

  CapabilityRegistry._({
    required Map<String, CapabilityPlugin> pluginMap,
    required Map<String, String> webPermissionCodeByResource,
    required Map<String, CapabilityWebPermissionExecutor>
    webPermissionExecutorByCode,
  }) : _plugins = Map.unmodifiable(pluginMap),
       _webPermissionCodeByResource = Map.unmodifiable(
         webPermissionCodeByResource,
       ),
       _webPermissionExecutorByCode = Map.unmodifiable(
         webPermissionExecutorByCode,
       );

  final Map<String, CapabilityPlugin> _plugins;
  final Map<String, String> _webPermissionCodeByResource;
  final Map<String, CapabilityWebPermissionExecutor>
  _webPermissionExecutorByCode;

  List<CapabilityPlugin> get plugins => List.unmodifiable(_plugins.values);

  List<CapabilityDescriptor> get descriptors =>
      List.unmodifiable(_plugins.values.map((plugin) => plugin.descriptor));

  CapabilityPlugin? plugin(String code) => _plugins[code];

  CapabilityDescriptor? descriptor(String code) => _plugins[code]?.descriptor;

  bool contains(String code) => _plugins.containsKey(code);

  String? webPermissionCapabilityCode(String resource) =>
      _webPermissionCodeByResource[resource];

  Future<bool> authorizeWebPermissions({
    required Iterable<String> resources,
    required Iterable<String> declaredCapabilities,
    required AppWebPermissionRole role,
    Uri? sourceUri,
    bool? isUserInitiated,
  }) async {
    final requestedResources = resources.toSet();
    if (requestedResources.isEmpty) return false;
    final declared = declaredCapabilities.toSet();
    final resourcesByCode = <String, Set<String>>{};
    for (final resource in requestedResources) {
      final code = _webPermissionCodeByResource[resource];
      final plugin = code == null ? null : _plugins[code];
      if (code == null ||
          plugin == null ||
          !plugin.isAvailable ||
          !declared.contains(code)) {
        return false;
      }
      (resourcesByCode[code] ??= <String>{}).add(resource);
    }
    for (final entry in resourcesByCode.entries) {
      final executor = _webPermissionExecutorByCode[entry.key];
      if (executor == null) return false;
      final allowed = await executor.authorize(
        CapabilityWebPermissionContext(
          role: role,
          requestedResources: entry.value,
          declaredCapabilities: declared,
          sourceUri: sourceUri,
          isUserInitiated: isUserInitiated,
        ),
      );
      if (!allowed) return false;
    }
    return true;
  }

  Future<void> dispose() async {
    await Future.wait(_plugins.values.map((plugin) => plugin.dispose()));
  }
}
