enum GDevelopAiSensitiveContentKind { sensitiveField, urlOrToken, bridge }

class GDevelopAiSensitiveContentViolation {
  const GDevelopAiSensitiveContentViolation({
    required this.kind,
    required this.path,
  });

  final GDevelopAiSensitiveContentKind kind;
  final String path;
}

/// Shared sensitive-content policy for all model-controlled GDevelop payloads.
abstract final class GDevelopAiContentPolicy {
  static final RegExp _nonIdentifier = RegExp(r'[^a-z0-9]');
  static final RegExp _url = RegExp(
    r'\b(?:https?|wss?|file|data|blob):',
    caseSensitive: false,
  );
  static final RegExp _bearer = RegExp(r'\bbearer\s+\S+', caseSensitive: false);
  static final RegExp _queryToken = RegExp(
    r'[?&](?:access_)?token=[^\s&#]*',
    caseSensitive: false,
  );

  static GDevelopAiSensitiveContentViolation? inspectKey(
    String key,
    String path,
  ) {
    final normalized = key.toLowerCase().replaceAll(_nonIdentifier, '');
    if (normalized.contains('authorization') ||
        normalized.contains('credential') ||
        normalized.contains('password') ||
        normalized.contains('secret') ||
        normalized.contains('token') ||
        normalized.contains('bridge')) {
      return GDevelopAiSensitiveContentViolation(
        kind: GDevelopAiSensitiveContentKind.sensitiveField,
        path: path,
      );
    }
    return null;
  }

  static GDevelopAiSensitiveContentViolation? inspectString(
    String value,
    String path,
  ) {
    if (_url.hasMatch(value) ||
        _bearer.hasMatch(value) ||
        _queryToken.hasMatch(value)) {
      return GDevelopAiSensitiveContentViolation(
        kind: GDevelopAiSensitiveContentKind.urlOrToken,
        path: path,
      );
    }
    final lower = value.toLowerCase();
    if (lower.contains('__playmesh') ||
        lower.contains('/playmesh/') ||
        (lower.contains('playmesh') && lower.contains('bridge'))) {
      return GDevelopAiSensitiveContentViolation(
        kind: GDevelopAiSensitiveContentKind.bridge,
        path: path,
      );
    }
    return null;
  }
}
