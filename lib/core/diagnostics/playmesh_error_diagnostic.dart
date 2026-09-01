/// 可由统一诊断格式化器展开的结构化错误。
///
/// [cause] 和 [causeStackTrace] 始终成对描述下一层底层错误；[context] 只能
/// 放置请求 ID、会话 ID、操作名等非敏感标识，不能放邀请链接或凭据。
abstract interface class PlaymeshDiagnosticError {
  String get code;

  String get message;

  Object? get cause;

  StackTrace? get causeStackTrace;

  Map<String, String> get context;
}

/// 完整展开错误类型、稳定 code、原始消息、上下文、cause 链和可用堆栈。
///
/// 展示和日志共用这一个出口，确保邀请 URL、内部 URL 与凭据在任何一层都被
/// 明确标记为已脱敏，而不是用概括性文案替换其余业务原因。
String formatPlaymeshDiagnosticError(Object error, {StackTrace? stackTrace}) {
  final lines = <String>[];
  final seen = <Object>{};
  Object? current = error;
  StackTrace? currentStackTrace = stackTrace;
  var depth = 0;
  while (current != null && depth < 16 && seen.add(current)) {
    if (depth > 0) lines.add('caused by:');
    final diagnostic = current is PlaymeshDiagnosticError ? current : null;
    if (diagnostic == null) {
      lines.add(
        '${current.runtimeType}: '
        '${redactPlaymeshDiagnosticText(current.toString())}',
      );
    } else {
      final message = redactPlaymeshDiagnosticText(
        diagnostic.message,
      ).replaceAll('"', '\\"');
      lines.add(
        '${current.runtimeType}: '
        'code=${redactPlaymeshDiagnosticText(diagnostic.code)} '
        'message="$message"',
      );
      final entries = diagnostic.context.entries.toList(growable: false)
        ..sort((left, right) => left.key.compareTo(right.key));
      for (final entry in entries) {
        lines.add(
          '${redactPlaymeshDiagnosticText(entry.key)}='
          '${redactPlaymeshDiagnosticText(entry.value)}',
        );
      }
    }
    final renderedStack = currentStackTrace?.toString().trim();
    if (renderedStack != null && renderedStack.isNotEmpty) {
      lines
        ..add('stack:')
        ..add(redactPlaymeshDiagnosticText(renderedStack));
    }
    if (diagnostic == null) {
      current = null;
      break;
    }
    current = diagnostic.cause;
    currentStackTrace = diagnostic.causeStackTrace;
    depth += 1;
  }
  if (current != null && (depth >= 16 || seen.contains(current))) {
    lines.add('caused by: [cycle or depth limit reached]');
  }
  return lines.join('\n');
}

String redactPlaymeshDiagnosticText(String value) {
  var result = value;
  result = result.replaceAll(
    RegExp(r'data:image/[^;\s]+;base64,[^\s]+', caseSensitive: false),
    '[REDACTED IMAGE DATA]',
  );
  result = result.replaceAll(
    RegExp(r'\b(?:https?|wss?)://[^\s"<>]+', caseSensitive: false),
    '[REDACTED URL]',
  );
  result = result.replaceAll(
    RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  final credentialPattern = RegExp(
    r'''((?:inviteToken|shareToken|sharedSecret|credentialToken|authorization|accessToken|refreshToken|token)\s*["']?\s*[:=]\s*["']?)([^"'\s,;&}\]]+)''',
    caseSensitive: false,
  );
  result = result.replaceAllMapped(
    credentialPattern,
    (match) => '${match.group(1)}[REDACTED]',
  );
  return result;
}
