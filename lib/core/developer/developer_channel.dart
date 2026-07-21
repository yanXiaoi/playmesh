class DeveloperSession {
  const DeveloperSession({
    required this.enabled,
    this.port,
    this.path,
    this.token,
    this.tokenHint,
    this.workspacePath,
    this.docsPath,
    this.openApiPath,
    this.sdkManifestPath,
    this.createdAt,
  });

  final bool enabled;
  final int? port;
  final String? path;
  final String? token;
  final String? tokenHint;
  final String? workspacePath;
  final String? docsPath;
  final String? openApiPath;
  final String? sdkManifestPath;
  final DateTime? createdAt;

  factory DeveloperSession.fromJson(Map<String, Object?> json) {
    final createdAtMs = json['createdAt'];
    return DeveloperSession(
      enabled: json['enabled'] == true,
      port: json['port'] as int?,
      path: json['path'] as String?,
      token: json['token'] as String?,
      tokenHint: json['tokenHint'] as String?,
      workspacePath: json['workspacePath'] as String?,
      docsPath: json['docsPath'] as String?,
      openApiPath: json['openApiPath'] as String?,
      sdkManifestPath: json['sdkManifestPath'] as String?,
      createdAt: createdAtMs is int
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true)
          : null,
    );
  }
}

abstract interface class DeveloperModeProvider {
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  });

  Future<DeveloperSession> developerModeStatus();

  Future<void> disableDeveloperMode();

  Future<List<Uri>> developerWorkspaceLinks(DeveloperSession session);
}

class DeveloperWorkspacePreference {
  const DeveloperWorkspacePreference({
    required this.port,
    required this.token,
    required this.path,
  });

  final int port;
  final String token;
  final String path;
}

abstract interface class DeveloperWorkspacePreferenceProvider {
  Future<DeveloperWorkspacePreference> loadDeveloperWorkspacePreference();
}

const defaultDeveloperPort = 16666;
