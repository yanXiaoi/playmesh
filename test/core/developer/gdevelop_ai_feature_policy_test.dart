import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_ai_feature_policy.dart';

void main() {
  test('late verified workspace activates the shared production policy', () {
    final policy = GDevelopAiFeaturePolicy.forDeveloperSession(
      developerModeEnabled: true,
      gdevelopWorkspaceAvailable: false,
    );

    expect(policy.enabled, isFalse);
    expect(policy.toUiBootstrapJson()['enabled'], isFalse);
    expect(policy.exposesOperationId('gdevelop.ai.session.create'), isFalse);

    policy.markWorkspaceVerified();

    expect(policy.enabled, isTrue);
    expect(policy.toUiBootstrapJson()['enabled'], isTrue);
    expect(policy.exposesOperationId('gdevelop.ai.session.create'), isTrue);

    // Activation is monotonic and idempotent for the lifetime of the gateway.
    policy.markWorkspaceVerified();
    expect(policy.enabled, isTrue);
  });

  test('late workspace verification cannot bypass Developer Mode', () {
    final policy = GDevelopAiFeaturePolicy.forDeveloperSession(
      developerModeEnabled: false,
      gdevelopWorkspaceAvailable: false,
    );

    policy.markWorkspaceVerified();

    expect(policy.enabled, isFalse);
    expect(
      policy.allowsRequest(
        operationId: 'gdevelop.ai.session.create',
        pathParameters: const {},
        queryParameters: const {},
      ),
      isFalse,
    );
  });

  test('disabled and explicit test policies are immutable', () {
    const disabled = GDevelopAiFeaturePolicy.disabled();
    const testDisabled = GDevelopAiFeaturePolicy.testOverride(enabled: false);

    disabled.markWorkspaceVerified();
    testDisabled.markWorkspaceVerified();

    expect(disabled.enabled, isFalse);
    expect(testDisabled.enabled, isFalse);
  });
}
