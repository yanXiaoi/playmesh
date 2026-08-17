/// Authoritative lifecycle policy shared by the Developer Gateway and the
/// embedded GDevelop UI.
///
/// A production policy is enabled only for an active Developer Mode session
/// whose GDevelop workspace has been verified. The verification may happen
/// when the gateway starts or later, when an installed/repaired WebIDE is first
/// served. The same policy instance gates the WebIDE bootstrap and every
/// backend operation, so there is no independent browser/build-time switch.
final class GDevelopAiFeaturePolicy {
  factory GDevelopAiFeaturePolicy.forDeveloperSession({
    required bool developerModeEnabled,
    required bool gdevelopWorkspaceAvailable,
  }) => GDevelopAiFeaturePolicy._(
    initialEnabled: developerModeEnabled && gdevelopWorkspaceAvailable,
    activationState: _GDevelopAiFeatureActivationState(
      developerModeEnabled: developerModeEnabled,
      workspaceVerified: gdevelopWorkspaceAvailable,
    ),
    isTestOverride: false,
  );

  const GDevelopAiFeaturePolicy.disabled()
    : _initialEnabled = false,
      _activationState = null,
      isTestOverride = false;

  const GDevelopAiFeaturePolicy.testOverride({required bool enabled})
    : _initialEnabled = enabled,
      _activationState = null,
      isTestOverride = true;

  const GDevelopAiFeaturePolicy._({
    required this._initialEnabled,
    required this._activationState,
    required this.isTestOverride,
  });

  static const bootstrapFormatVersion = '1.0.0';
  static const eventsPathTemplate =
      '/dev/api/gdevelop/projects/{gameId}/ai/editor-sessions/'
      '{editorSessionId}/events';

  final bool _initialEnabled;
  final _GDevelopAiFeatureActivationState? _activationState;
  final bool isTestOverride;

  bool get enabled => _activationState?.enabled ?? _initialEnabled;

  /// Enables GDevelop AI after the authenticated gateway has successfully
  /// served a verified WebIDE installation. This is intentionally monotonic:
  /// a transient later read failure must not split the UI and backend policy.
  /// Disabled policies and explicit test overrides cannot be changed here.
  void markWorkspaceVerified() {
    _activationState?.markWorkspaceVerified();
  }

  /// Operation definitions wholly owned by GDevelop AI are hidden when the
  /// rollout is disabled. Shared source/GDevelop prompt-template operations
  /// require request-level filtering in [allowsRequest].
  bool exposesOperationId(String operationId) =>
      enabled || !operationId.startsWith('gdevelop.ai.');

  bool allowsRequest({
    required String operationId,
    required Map<String, String> pathParameters,
    required Map<String, String> queryParameters,
  }) {
    if (enabled) return true;
    if (operationId.startsWith('gdevelop.ai.')) return false;
    if (operationId == 'prompts.templates.list') {
      return queryParameters['surface'] != 'gdevelop';
    }
    if (operationId == 'prompts.templates.save' ||
        operationId == 'prompts.templates.reset') {
      return !const {
        'gdevelop-chat',
        'gdevelop-agent',
      }.contains(pathParameters['templateId']);
    }
    return true;
  }

  Map<String, Object?> toUiBootstrapJson() => {
    'formatVersion': bootstrapFormatVersion,
    'enabled': enabled,
    'eventsPathTemplate': eventsPathTemplate,
  };
}

final class _GDevelopAiFeatureActivationState {
  _GDevelopAiFeatureActivationState({
    required this.developerModeEnabled,
    required this._workspaceVerified,
  });

  final bool developerModeEnabled;
  bool _workspaceVerified;

  bool get enabled => developerModeEnabled && _workspaceVerified;

  void markWorkspaceVerified() {
    if (developerModeEnabled) _workspaceVerified = true;
  }
}
