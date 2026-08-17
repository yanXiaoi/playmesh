// @flow

/*::
export type PlaymeshAiFailureDiagnostic = {|
  stage: string,
  operation: string,
  status: number,
  code: string,
  reason: string,
  requestId: string,
  errorType: string,
|};
*/

const sanitizeDiagnosticField = (
  value /*: mixed */,
  fallback /*: string */,
  maxLength /*: number */ = 512
) /*: string */ => {
  if (typeof value !== 'string' || !value.trim()) return fallback;
  let sanitized = value.trim().slice(0, maxLength);
  sanitized = sanitized.replace(/Bearer\s+[^\s,;]+/gi, 'Bearer [REDACTED]');
  sanitized = sanitized.replace(
    /([?&](?:access_token|auth|authorization|cookie|key|password|secret|token)=)[^&#\s]*/gi,
    '$1[REDACTED]'
  );
  sanitized = sanitized.replace(
    /((?:access_token|authorization|cookie|password|secret|token)\s*[:=]\s*)[^\s,;]+/gi,
    '$1[REDACTED]'
  );
  sanitized = sanitized.replace(/\b[a-f0-9]{48,}\b/gi, '[REDACTED]');
  return sanitized || fallback;
};

let localRequestSequence = 0;
export const createPlaymeshAiLocalRequestId = () /*: string */ => {
  localRequestSequence = (localRequestSequence + 1) % 0x100000;
  return `web-${Date.now().toString(36)}-${localRequestSequence.toString(36)}`;
};

const stableErrorType = (error /*: mixed */) /*: string */ => {
  const failure = error && typeof error === 'object' ? (error /*: any */) : {};
  const declaredType =
    typeof failure.errorType === 'string' ? failure.errorType.trim() : '';
  const name = typeof failure.name === 'string' ? failure.name.trim() : '';
  const allowedTypes = [
      'AbortError',
      'DeveloperGatewayError',
      'Error',
      'EvalError',
      'NetworkError',
      'PlaymeshAiProtocolError',
      'PlaymeshAiRequestError',
      'RangeError',
      'ReferenceError',
      'SyntaxError',
      'TimeoutError',
      'TypeError',
      'URIError',
    ];
  if (allowedTypes.includes(declaredType)) return declaredType;
  if (allowedTypes.includes(name)) return name;
  // $FlowFixMe[method-unbinding] Intentional intrinsic call with an explicit receiver.
  const tag = Object.prototype.toString.call(error);
  return tag === '[object DOMException]' ? 'DOMException' : 'Error';
};

/**
 * Completes diagnostics without copying an exception message or response
 * body. This is used at orchestration boundaries that need to relabel a local
 * fallback but must preserve a structured Gateway failure verbatim.
 */
export const completePlaymeshAiFailureDiagnostics = (
  error /*: mixed */,
  defaults /*: {|
    code: string,
    operation: string,
    requestId: string,
    status?: number,
    stage?: string,
    reason?: string,
  |} */
) /*: Error */ => {
  const failure = error && typeof error === 'object' ? (error /*: any */) : {};
  if (
    typeof failure.requestId === 'string' &&
    failure.requestId &&
    typeof failure.operation === 'string' &&
    failure.operation &&
    typeof failure.stage === 'string' &&
    failure.stage &&
    typeof failure.reason === 'string' &&
    failure.reason
  ) {
    return failure;
  }
  const completed = new Error('The local GDevelop AI operation failed.');
  (completed /*: any */).code =
    typeof failure.code === 'string' && failure.code
      ? failure.code
      : defaults.code;
  (completed /*: any */).status = Number.isSafeInteger(failure.status)
    ? failure.status
    : Number.isSafeInteger(defaults.status)
    ? defaults.status
    : 0;
  (completed /*: any */).requestId =
    typeof failure.requestId === 'string' && failure.requestId
      ? failure.requestId
      : defaults.requestId;
  (completed /*: any */).operation =
    typeof failure.operation === 'string' && failure.operation
      ? failure.operation
      : defaults.operation;
  (completed /*: any */).stage =
    typeof failure.stage === 'string' && failure.stage
      ? failure.stage
      : defaults.stage ||
        ((completed /*: any */).status > 0 ? 'response' : 'pre_request');
  (completed /*: any */).reason =
    typeof failure.reason === 'string' && failure.reason
      ? failure.reason
      : defaults.reason || (completed /*: any */).code;
  (completed /*: any */).errorType = stableErrorType(error);
  return completed;
};

export const toPlaymeshAiFailureDiagnostic = (
  operation /*: string */,
  error /*: mixed */
) /*: PlaymeshAiFailureDiagnostic */ => {
  const failure = error && typeof error === 'object' ? (error /*: any */) : {};
  const localRequestId = createPlaymeshAiLocalRequestId();
  const status =
    Number.isSafeInteger(failure.status) && failure.status >= 0
      ? failure.status
      : 0;
  const errorType = stableErrorType(error);
  return {
    stage: sanitizeDiagnosticField(
      failure.stage,
      status > 0 ? 'response' : 'pre_request'
    ),
    operation: sanitizeDiagnosticField(
      failure.operation,
      sanitizeDiagnosticField(operation, 'gdevelop.ai.unknown')
    ),
    status,
    code: sanitizeDiagnosticField(failure.code, 'ai_client_unhandled_error'),
    reason: sanitizeDiagnosticField(
      failure.reason,
      `${errorType} failed before a structured reason was returned.`
    ),
    requestId: sanitizeDiagnosticField(failure.requestId, localRequestId),
    errorType: sanitizeDiagnosticField(errorType, 'Error'),
  };
};

export const isPlaymeshAiConnectionFailure = (
  error /*: mixed */
) /*: boolean */ => {
  const failure = error && typeof error === 'object' ? (error /*: any */) : {};
  const code = typeof failure.code === 'string' ? failure.code : '';
  return ['ai_unavailable', 'ai_request_timeout', 'ai_network_error'].includes(
    code
  );
};

export const reportPlaymeshAiFailure = (
  operation /*: string */,
  error /*: mixed */
) /*: PlaymeshAiFailureDiagnostic */ => {
  const diagnostic = toPlaymeshAiFailureDiagnostic(operation, error);
  // Only bounded diagnostic fields are emitted. Never log error.message,
  // request bodies, response bodies, prompts, project content, or tokens.
  global.console.error(
    `[PlayMesh AI] requestId=${diagnostic.requestId} ` +
      `stage=${diagnostic.stage} operation=${diagnostic.operation} ` +
      `status=${diagnostic.status} code=${diagnostic.code} ` +
      `reason=${diagnostic.reason} type=${diagnostic.errorType}`
  );
  return diagnostic;
};

export default reportPlaymeshAiFailure;
