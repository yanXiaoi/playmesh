import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/diagnostics/playmesh_error_diagnostic.dart';

void main() {
  test('完整诊断保留业务原因并脱敏邀请 URL 和凭据', () {
    final error = _TestDiagnosticError(
      cause: UnsupportedError(
        'relay failed: '
        'http://relay.internal/j/room#inviteToken=invite-secret '
        'shareToken=share-secret sharedSecret=shared-secret',
      ),
      causeStackTrace: StackTrace.fromString(
        'request http://127.0.0.1:16667/v1/relay/client '
        'authorization=Bearer-secret',
      ),
    );

    final details = formatPlaymeshDiagnosticError(error);

    expect(details, contains('_TestDiagnosticError'));
    expect(details, contains('code=test_failure'));
    expect(details, contains('relay failed'));
    expect(details, contains('caused by:'));
    expect(details, contains('UnsupportedError'));
    expect(details, contains('[REDACTED]'));
    expect(details, isNot(contains('invite-secret')));
    expect(details, isNot(contains('share-secret')));
    expect(details, isNot(contains('shared-secret')));
    expect(details, isNot(contains('Bearer-secret')));
    expect(details, isNot(contains('relay.internal')));
    expect(details, isNot(contains('127.0.0.1')));
  });
}

final class _TestDiagnosticError implements PlaymeshDiagnosticError {
  const _TestDiagnosticError({
    required this.cause,
    required this.causeStackTrace,
  });

  @override
  String get code => 'test_failure';

  @override
  String get message => 'relay failed';

  @override
  final Object cause;

  @override
  final StackTrace causeStackTrace;

  @override
  Map<String, String> get context => const {'operation': 'join'};
}
