// @flow

/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiObject,
  PlaymeshAiSession,
} from './PlaymeshAiProtocol';
import type { PlaymeshAiFailureDiagnostic } from './PlaymeshAiDiagnostics';

type PlaymeshAiApprovalStatus = {
  approvalId: string,
  toolName: string,
  +risk: string,
  ...,
};
type PlaymeshAiReturnStatusOptions = {|
  mode: 'chat' | 'agent',
  session: ?PlaymeshAiSession,
  chatOperation?: ?{|
    echo: number,
    turnId: ?string,
  |},
  calls: $ReadOnlyArray<PlaymeshAiCall>,
  approvals: $ReadOnlyArray<PlaymeshAiApprovalStatus>,
  failure: ?PlaymeshAiFailureDiagnostic,
  connectionStatus: string,
|};
*/

const REDACTED = '[REDACTED]';
const OMITTED = '[OMITTED]';

const sanitizeString = (input /*: mixed */) /*: string */ => {
  let value = String(input == null ? '' : input);
  value = value.replace(/Bearer\s+[^\s,;]+/gi, `Bearer ${REDACTED}`);
  value = value.replace(
    /([?&](?:access_token|auth|authorization|cookie|key|password|secret|token)=)[^&#\s]*/gi,
    `$1${REDACTED}`
  );
  value = value.replace(
    /((?:access_token|authorization|cookie|password|secret|token)\s*[:=]\s*)[^\s,;]+/gi,
    `$1${REDACTED}`
  );
  value = value.replace(/\b[a-f0-9]{48,}\b/gi, REDACTED);
  return value;
};

// Tool outputs have already crossed the Gateway JSON boundary. Preserve every
// field and string byte-for-byte for the next model turn. The cycle marker is
// only defensive for synthetic in-memory callers; a Gateway JSON response
// cannot contain a cycle.
const copyToolOutputValue = (
  value /*: mixed */,
  depth /*: number */ = 0,
  seen /*: WeakSet<Object> */ = new WeakSet()
) /*: mixed */ => {
  if (value == null || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    if (seen.has(value)) return OMITTED;
    seen.add(value);
    const result = value.map(item =>
      copyToolOutputValue(item, depth + 1, seen)
    );
    seen.delete(value);
    return result;
  }
  if (typeof value !== 'object') return value;
  if (seen.has((value /*: Object */))) return OMITTED;
  seen.add((value /*: Object */));
  const source = (value /*: { +[key: string]: mixed } */);
  const result /*: { [key: string]: mixed } */ = {};
  Object.keys(source).forEach(key => {
    result[key] = copyToolOutputValue(source[key], depth + 1, seen);
  });
  seen.delete((value /*: Object */));
  return result;
};

const safeInteger = (value /*: mixed */) /*: ?number */ =>
  Number.isSafeInteger(value) && value >= 0 ? Number(value) : null;

const safeEcho = (value /*: mixed */) /*: ?number */ =>
  Number.isSafeInteger(value) && value > 0 ? Number(value) : null;

const safeField = (value /*: mixed */, fallback /*: string */) /*: string */ => {
  const sanitized = sanitizeString(value);
  return sanitized.trim() ? sanitized : fallback;
};

const asPlaymeshAiObject = (
  value /*: mixed */
) /*: ?PlaymeshAiObject */ => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return (value /*: PlaymeshAiObject */);
};

const callFailure = (call /*: PlaymeshAiCall */) /*: ?Object */ => {
  const rawError = asPlaymeshAiObject(call.error);
  const output = asPlaymeshAiObject(call.output);
  if (!rawError && !['failed', 'cancelled', 'timed_out'].includes(call.state)) {
    return null;
  }
  return {
    stage: 'tool_execution',
    operation: safeField(call.toolName, 'unknown_tool'),
    status: 0,
    code: safeField(rawError && rawError.code, call.state),
    reason: safeField(
      rawError && rawError.message,
      output && typeof output.reason === 'string' ? output.reason : call.state
    ),
    requestId: null,
    errorType: 'GDevelopAiCallFailure',
  };
};

const summarizeOutput = (call /*: PlaymeshAiCall */) /*: mixed */ => {
  const source = asPlaymeshAiObject(call.output);
  if (!source) return null;
  return copyToolOutputValue(source);
};

const latestTurnCalls = (
  calls /*: $ReadOnlyArray<PlaymeshAiCall> */,
  turnId /*: ?string */ = null
) /*: Array<PlaymeshAiCall> */ => {
  if (turnId) {
    return calls
      .filter(call => call.turnId === turnId)
      .sort((left, right) => left.sequence - right.sequence);
  }
  if (!calls.length) return [];
  const latest = [...calls].sort(
    (left, right) => right.sequence - left.sequence
  )[0];
  return calls
    .filter(call => call.turnId === latest.turnId)
    .sort((left, right) => left.sequence - right.sequence);
};

const workflowDecision = ({
  calls,
  approvals,
  failure,
  connectionStatus,
} /*: {|
  calls: $ReadOnlyArray<PlaymeshAiCall>,
  approvals: $ReadOnlyArray<PlaymeshAiApprovalStatus>,
  failure: ?PlaymeshAiFailureDiagnostic,
  connectionStatus: string,
|} */) /*: {| shouldContinuePolling: boolean, nextAction: string |} */ => {
  if (connectionStatus === 'offline') {
    return { shouldContinuePolling: false, nextAction: 'restore_connection_then_retry' };
  }
  if (approvals.length || calls.some(call => call.state === 'awaiting_approval')) {
    return { shouldContinuePolling: true, nextAction: 'wait_for_user_approval' };
  }
  if (calls.some(call => !['finished', 'failed', 'cancelled', 'timed_out'].includes(call.state))) {
    return { shouldContinuePolling: true, nextAction: 'continue_polling' };
  }
  if (
    failure ||
    calls.some(call => ['failed', 'cancelled', 'timed_out'].includes(call.state))
  ) {
    return { shouldContinuePolling: false, nextAction: 'copy_status_to_ai_and_replan' };
  }
  if (calls.length) {
    return { shouldContinuePolling: false, nextAction: 'copy_status_to_ai_for_next_turn' };
  }
  return { shouldContinuePolling: false, nextAction: 'send_prompt_or_tool_calls' };
};

export const buildPlaymeshAiReturnStatus = ({
  mode,
  session,
  chatOperation,
  calls,
  approvals,
  failure,
  connectionStatus,
} /*: PlaymeshAiReturnStatusOptions */) /*: Object */ => {
  const chatEcho = safeEcho(chatOperation && chatOperation.echo);
  const turnCalls =
    mode === 'chat' && chatEcho != null
      ? chatOperation && chatOperation.turnId
        ? latestTurnCalls(calls, chatOperation.turnId)
        : []
      : latestTurnCalls(calls);
  const decision = workflowDecision({
    calls: turnCalls,
    approvals,
    failure,
    connectionStatus,
  });
  const summarizedCalls = turnCalls.map(call => ({
    callId: safeField(call.callId, 'unavailable'),
    toolName: safeField(call.toolName, 'unknown_tool'),
    state: call.state,
    sequence: safeInteger(call.sequence),
    approvalStatus:
      call.state === 'awaiting_approval'
        ? 'waiting'
        : call.state === 'cancelled' && call.error
        ? 'rejected_or_cancelled'
        : 'not_waiting',
    result: summarizeOutput(call),
    failure: callFailure(call),
  }));
  const summarizedApprovals = approvals.map(approval => ({
    approvalId: safeField(approval.approvalId, 'unavailable'),
    toolName: safeField(approval.toolName, 'unknown_tool'),
    status: 'waiting',
    risk: safeField(approval.risk, 'unknown'),
  }));
  const summarizedFailure = failure
    ? {
        stage: safeField(failure.stage, 'pre_request'),
        operation: safeField(failure.operation, 'gdevelop.ai.unknown'),
        status: safeInteger(failure.status) || 0,
        code: safeField(failure.code, 'ai_client_unhandled_error'),
        reason: safeField(
          failure.reason,
          'No additional reason was supplied.'
        ),
        requestId: safeField(failure.requestId, 'unavailable'),
        errorType: safeField(failure.errorType, 'Error'),
      }
    : null;

  if (mode === 'chat') {
    return {
      schemaVersion: 'playmesh.gdevelop.ai.return-status.v3',
      echo: chatEcho,
      connectionStatus: safeField(connectionStatus, 'unknown'),
      latestTurn:
        summarizedCalls.length > 0
          ? {
              calls: summarizedCalls.map(call => ({
                toolName: call.toolName,
                state: call.state,
                result: call.result,
                failure: call.failure
                  ? {
                      stage: call.failure.stage,
                      operation: call.failure.operation,
                      status: call.failure.status,
                      code: call.failure.code,
                      reason: call.failure.reason,
                      errorType: call.failure.errorType,
                    }
                  : null,
              })),
            }
          : null,
      pendingApprovals: summarizedApprovals.map(approval => ({
        toolName: approval.toolName,
        status: approval.status,
        risk: approval.risk,
      })),
      failure: summarizedFailure
        ? {
            stage: summarizedFailure.stage,
            operation: summarizedFailure.operation,
            status: summarizedFailure.status,
            code: summarizedFailure.code,
            reason: summarizedFailure.reason,
            errorType: summarizedFailure.errorType,
          }
        : null,
      shouldContinuePolling: decision.shouldContinuePolling,
      nextAction: decision.nextAction,
    };
  }

  return {
    schemaVersion: 'playmesh.gdevelop.ai.return-status.v1',
    editorSession: session
      ? {
          editorSessionId: safeField(session.editorSessionId, 'unavailable'),
          gameId: safeField(session.gameId, 'unavailable'),
          channelMode: session.mode,
          visibleMode: mode,
          state: session.closed ? 'closed' : 'open',
          sequence: safeInteger(session.sequence),
        }
      : null,
    connectionStatus: safeField(connectionStatus, 'unknown'),
    latestTurn:
      turnCalls.length > 0
        ? {
            turnId: safeField(turnCalls[0].turnId, 'unavailable'),
            calls: summarizedCalls,
          }
        : null,
    pendingApprovals: summarizedApprovals,
    failure: summarizedFailure,
    shouldContinuePolling: decision.shouldContinuePolling,
    nextAction: decision.nextAction,
  };
};

export const serializePlaymeshAiReturnStatus = (
  options /*: PlaymeshAiReturnStatusOptions */
) /*: string */ => JSON.stringify(buildPlaymeshAiReturnStatus(options), null, 2);

export default serializePlaymeshAiReturnStatus;
