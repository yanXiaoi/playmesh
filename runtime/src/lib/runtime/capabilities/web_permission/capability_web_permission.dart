enum AppWebPermissionRole { authority, joiner }

class CapabilityWebPermissionContext {
  CapabilityWebPermissionContext({
    required this.role,
    required Iterable<String> requestedResources,
    required Iterable<String> declaredCapabilities,
    this.sourceUri,
    this.isUserInitiated,
  }) : requestedResources = List.unmodifiable(requestedResources),
       declaredCapabilities = List.unmodifiable(declaredCapabilities);

  final AppWebPermissionRole role;
  final List<String> requestedResources;
  final List<String> declaredCapabilities;
  final Uri? sourceUri;
  final bool? isUserInitiated;
}

typedef CapabilityWebPermissionAuthorize =
    Future<bool> Function(CapabilityWebPermissionContext context);

class CapabilityWebPermissionExecutor {
  const CapabilityWebPermissionExecutor({required this.authorize});

  final CapabilityWebPermissionAuthorize authorize;
}

abstract interface class CapabilityWebPermissionPlugin {
  List<String> get webPermissionResources;

  CapabilityWebPermissionExecutor get webPermissionExecutor;
}
