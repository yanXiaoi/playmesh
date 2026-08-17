// @flow

export const PLAYMESH_AI_APPROVAL_TIMEOUT_MS = 30000;

/*::
export type PlaymeshAiApproval = {
  approvalId: string,
  operationId: string,
  scopeKind: string,
  gameId: string,
  editorSessionId: string,
  channel: string,
  callId: string,
  timeoutSeconds: number,
  createdAt: number,
  expiresAt: number,
  ...,
};
export type PlaymeshAiApprovalPresentation = {|
  approvalId: string,
  operationId: string,
  toolName: string,
  risk: string,
  riskReason: string,
  affectedSceneIds: Array<string>,
  affectedObjectIds: Array<string>,
  affectedResourceIds: Array<string>,
  arguments: Array<{| name: string, value: string |}>,
  argumentsTruncated: boolean,
  modifiesProject: boolean,
|};

type FilterPlaymeshAiApprovalsOptions = {|
  approvals: $ReadOnlyArray<{ +[key: string]: mixed }>,
  gameId: string,
  editorSessionId: string,
  mode: 'chat' | 'agent',
  now?: number,
|};
type BuildPlaymeshAiApprovalPresentationsOptions = {|
  approvals: $ReadOnlyArray<PlaymeshAiApproval>,
  calls: $ReadOnlyArray<{ +[key: string]: mixed }>,
  tools: $ReadOnlyArray<{ +[key: string]: mixed }>,
|};
type PlaymeshAiSanitizedArguments = {|
  arguments: Array<{| name: string, value: string |}>,
  truncated: boolean,
  scenes: Array<string>,
  objects: Array<string>,
  resources: Array<string>,
|};
type PlaymeshAiEventPayloadApprovalSummary = {|
  arguments: Array<{| name: string, value: string |}>,
  scene: ?string,
  truncated: boolean,
|};
*/

const MAX_ARGUMENTS = 8;
const MAX_AFFECTED_IDS = 6;
const MAX_ARGUMENT_KEY_LENGTH = 64;
const MAX_ARGUMENT_VALUE_LENGTH = 160;
const MAX_RISK_REASON_LENGTH = 240;
const SENSITIVE_KEY = /(?:^|_)(?:authorization|bearer|token|secret|password|credential|cookie|session_key|api_key|access_key|private_key)(?:_|$)/i;
const BULK_VALUE_KEY = /(?:project|project_json|full_context|source_code|event_payload|binary|blob|base64|data_url)/i;

const normalizeKey = (key /*: string */) /*: string */ =>
  key
    .replace(/([a-z0-9])([A-Z])/g, '$1_$2')
    .replace(/[^a-zA-Z0-9_-]/g, '_')
    .toLowerCase();

const boundedText = (value /*: string */, maxLength /*: number */) /*: string */ => {
  const cleaned = value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  if (cleaned.length <= maxLength) return cleaned;
  return `${cleaned.slice(0, Math.max(0, maxLength - 1))}…`;
};

const redactSensitiveText = (value /*: string */) /*: string */ =>
  value.replace(
    /\b(?:bearer\s+[^\s,;]+|(?:authorization|api[_ -]?key|token|secret|password)\s*[:=]\s*[^\s,;]+)/gi,
    '[hidden]'
  );

const sanitizeIdentifier = (value /*: mixed */) /*: ?string */ => {
  if (typeof value !== 'string') return null;
  const normalized = boundedText(value, 96);
  if (
    normalized.length === 0 ||
    /^(?:https?:|data:|blob:|file:)/i.test(normalized) ||
    /[{}<>]/.test(normalized)
  ) {
    return null;
  }
  return normalized;
};

const sanitizeArgumentValue = (value /*: mixed */) /*: ?string */ => {
  if (typeof value === 'string') {
    if (/^(?:https?:|data:|blob:|file:)/i.test(value.trim())) return null;
    return boundedText(redactSensitiveText(value), MAX_ARGUMENT_VALUE_LENGTH);
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  if (value == null) return 'null';
  if (Array.isArray(value)) {
    const items /*: Array<string> */ = [];
    value.slice(0, 4).forEach(item => {
      const sanitized = sanitizeArgumentValue(item);
      if (sanitized) items.push(sanitized);
    });
    if (items.length === 0) return null;
    const suffix = value.length > 4 ? ', …' : '';
    return boundedText(items.join(', ') + suffix, MAX_ARGUMENT_VALUE_LENGTH);
  }
  // Structured values may contain a full project/events dump. Never stringify them.
  return null;
};

const appendAffectedIds = ({
  key,
  value,
  scenes,
  objects,
  resources,
} /*: {|
  key: string,
  value: mixed,
  scenes: Array<string>,
  objects: Array<string>,
  resources: Array<string>,
|} */) /*: void */ => {
  const normalizedKey = normalizeKey(key);
  let destination /*: ?Array<string> */ = null;
  if (/(?:^|_)(?:scene|layout)(?:_|$)/.test(normalizedKey)) {
    destination = scenes;
  } else if (/(?:^|_)object(?:_|$)/.test(normalizedKey)) {
    destination = objects;
  } else if (/(?:^|_)(?:resource|asset)(?:_|$)/.test(normalizedKey)) {
    destination = resources;
  }
  if (!destination) return;
  const target = destination;
  const candidates = Array.isArray(value) ? value : [value];
  candidates.slice(0, MAX_AFFECTED_IDS).forEach(candidate => {
    const identifier = sanitizeIdentifier(candidate);
    if (
      identifier &&
      target.length < MAX_AFFECTED_IDS &&
      !target.includes(identifier)
    ) {
      target.push(identifier);
    }
  });
};

const buildSanitizedArguments = (
  rawArguments /*: { +[key: string]: mixed } */
) /*: PlaymeshAiSanitizedArguments */ => {
  const entries = Object.keys(rawArguments);
  const result /*: Array<{| name: string, value: string |}> */ = [];
  const scenes /*: Array<string> */ = [];
  const objects /*: Array<string> */ = [];
  const resources /*: Array<string> */ = [];
  entries.slice(0, 32).forEach(rawKey => {
    const key = normalizeKey(rawKey).slice(0, MAX_ARGUMENT_KEY_LENGTH);
    if (!key || SENSITIVE_KEY.test(key) || BULK_VALUE_KEY.test(key)) return;
    const value = rawArguments[rawKey];
    appendAffectedIds({ key, value, scenes, objects, resources });
    if (result.length >= MAX_ARGUMENTS) return;
    const sanitized = sanitizeArgumentValue(value);
    if (sanitized == null || sanitized.length === 0) return;
    result.push({ name: key, value: sanitized });
  });
  return {
    arguments: result,
    truncated: entries.length > MAX_ARGUMENTS || result.length < entries.length,
    scenes,
    objects,
    resources,
  };
};

const summarizeLockedEventPayload = (
  rawInput /*: mixed */
) /*: PlaymeshAiEventPayloadApprovalSummary */ => {
  if (!rawInput || typeof rawInput !== 'object' || Array.isArray(rawInput)) {
    return { arguments: [], scene: null, truncated: false };
  }
  const eventPayload = rawInput.eventPayload;
  if (
    !eventPayload ||
    typeof eventPayload !== 'object' ||
    Array.isArray(eventPayload)
  ) {
    return { arguments: [], scene: null, truncated: false };
  }
  const scene = sanitizeIdentifier(eventPayload.sceneName);
  const changes = Array.isArray(eventPayload.changes)
    ? eventPayload.changes
    : [];
  const operations /*: Array<string> */ = [];
  changes.slice(0, 4).forEach(change => {
    const operation =
      change && typeof change === 'object' && !Array.isArray(change)
        ? sanitizeIdentifier(change.operationName)
        : null;
    if (operation && !operations.includes(operation)) operations.push(operation);
  });
  const argumentsSummary = [
    ...(scene ? [{ name: 'event_scene', value: scene }] : []),
    { name: 'event_changes', value: String(changes.length) },
    ...(operations.length
      ? [
          {
            name: 'event_operations',
            value: boundedText(
              `${operations.join(', ')}${changes.length > 4 ? ', …' : ''}`,
              MAX_ARGUMENT_VALUE_LENGTH
            ),
          },
        ]
      : []),
  ];
  return {
    arguments: argumentsSummary,
    scene,
    truncated: changes.length > 4,
  };
};

export const filterPlaymeshAiApprovals = ({
  approvals,
  gameId,
  editorSessionId,
  mode,
  now = Date.now(),
} /*: FilterPlaymeshAiApprovalsOptions */) /*: Array<PlaymeshAiApproval> */ => {
  const channel = `gdevelop-${mode}`;
  return approvals.reduce((accepted /*: Array<PlaymeshAiApproval> */, approval) => {
    const approvalId = approval && approval.approvalId;
    const operationId = approval && approval.operationId;
    const callId = approval && approval.callId;
    const createdAt = approval && approval.createdAt;
    const expiresAt = approval && approval.expiresAt;
    if (
      approval &&
      typeof approvalId === 'string' &&
      approval.scopeKind === 'gdevelop' &&
      approval.gameId === gameId &&
      approval.editorSessionId === editorSessionId &&
      approval.channel === channel &&
      approval.timeoutSeconds === PLAYMESH_AI_APPROVAL_TIMEOUT_MS / 1000 &&
      typeof operationId === 'string' &&
      operationId.startsWith('gdevelop.tool.') &&
      typeof callId === 'string' &&
      callId.length > 0 &&
      typeof createdAt === 'number' &&
      typeof expiresAt === 'number' &&
      Number.isSafeInteger(createdAt) &&
      Number.isSafeInteger(expiresAt) &&
      expiresAt - createdAt === PLAYMESH_AI_APPROVAL_TIMEOUT_MS &&
      now < expiresAt
    ) {
      accepted.push({
        ...approval,
        approvalId,
        operationId,
        scopeKind: 'gdevelop',
        gameId,
        editorSessionId,
        channel,
        callId,
        timeoutSeconds: PLAYMESH_AI_APPROVAL_TIMEOUT_MS / 1000,
        createdAt: Number(createdAt),
        expiresAt: Number(expiresAt),
      });
    }
    return accepted;
  }, []);
};

/**
 * 审批 DTO 只能和同一会话的 canonical call + tools contract 联结后展示。
 * UI 得到的是有界摘要，不会接触 raw arguments、Token 或完整工程内容。
 */
export const buildPlaymeshAiApprovalPresentations = ({
  approvals,
  calls,
  tools,
} /*: BuildPlaymeshAiApprovalPresentationsOptions */) /*: Array<PlaymeshAiApprovalPresentation> */ =>
  approvals.reduce(
    (presentations /*: Array<PlaymeshAiApprovalPresentation> */, approval) => {
      const toolName = approval.operationId.slice('gdevelop.tool.'.length);
      if (!toolName) return presentations;
      const call = calls.find(
        item =>
          item.callId === approval.callId &&
          item.editorSessionId === approval.editorSessionId &&
          item.toolName === toolName
      );
      const definition = tools.find(item => item.name === toolName);
      if (!call || !definition) return presentations;
      const rawArguments = call.arguments;
      if (
        !rawArguments ||
        typeof rawArguments !== 'object' ||
        Array.isArray(rawArguments)
      ) {
        return presentations;
      }
      const risk = definition.risk;
      const modifiesProject = definition.modifiesProject;
      if (
        typeof risk !== 'string' ||
        !risk.trim() ||
        typeof modifiesProject !== 'boolean'
      ) {
        return presentations;
      }
      const summarized = buildSanitizedArguments(rawArguments);
      const eventPayloadSummary = summarizeLockedEventPayload(call.input);
      const presentationArguments = [
        ...summarized.arguments,
        ...eventPayloadSummary.arguments,
      ].slice(0, MAX_ARGUMENTS);
      const affectedSceneIds = [...summarized.scenes];
      const eventPayloadScene = eventPayloadSummary.scene;
      if (
        typeof eventPayloadScene === 'string' &&
        !affectedSceneIds.includes(eventPayloadScene) &&
        affectedSceneIds.length < MAX_AFFECTED_IDS
      ) {
        affectedSceneIds.push(eventPayloadScene);
      }
      const summary = definition.summary;
      presentations.push({
        approvalId: approval.approvalId,
        operationId: approval.operationId,
        toolName,
        risk: boundedText(risk, MAX_ARGUMENT_VALUE_LENGTH),
        riskReason:
          typeof summary === 'string'
            ? boundedText(
                redactSensitiveText(summary),
                MAX_RISK_REASON_LENGTH
              )
            : '',
        affectedSceneIds,
        affectedObjectIds: summarized.objects,
        affectedResourceIds: summarized.resources,
        arguments: presentationArguments,
        argumentsTruncated:
          summarized.truncated ||
          eventPayloadSummary.truncated ||
          summarized.arguments.length + eventPayloadSummary.arguments.length >
            MAX_ARGUMENTS,
        modifiesProject,
      });
      return presentations;
    },
    []
  );

export default filterPlaymeshAiApprovals;
