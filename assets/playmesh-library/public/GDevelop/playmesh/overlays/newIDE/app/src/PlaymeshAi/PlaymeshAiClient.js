// @flow

import {
  PLAYMESH_AI_SESSION_PROTOCOL_VERSION,
  PlaymeshAiProtocolError,
  validatePlaymeshAiCall,
  validatePlaymeshAiCapabilitiesReference,
  validatePlaymeshAiClientId,
  validatePlaymeshAiSession,
  validatePlaymeshAiTurn,
} from './PlaymeshAiProtocol';
import { copyPlaymeshText } from './PlaymeshAiClipboard';
import { sha256Hex } from '../PlaymeshCrypto/PlaymeshSha256';

/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiCapabilitiesReference,
  PlaymeshAiEnqueueRequest,
  PlaymeshAiObject,
  PlaymeshAiSession,
  PlaymeshAiTurn,
} from './PlaymeshAiProtocol';
import type { PlaymeshAiToolDefinition } from './PlaymeshAiEditorFunctionTypes';
import type {
  PlaymeshClipboard,
  PlaymeshLegacyCopy,
} from './PlaymeshAiClipboard';

export type PlaymeshAiApprovalGrant = {|
  grantId: string,
  scopeKind: string,
  scopeId: string,
  operationId: string,
  gameId?: string,
  projectId?: string,
|};
export type PlaymeshAiPromptTemplate = {|
  id: string,
  category: string,
  surface: 'gdevelop',
  mode: 'chat' | 'agent',
  name: string,
  content: string,
  defaultContent: string,
  customized: boolean,
  locale: string,
|};
type PlaymeshAiPromptTemplateContentValidation = {|
  bytes: number,
  error: ?('empty' | 'too_large'),
|};
type PlaymeshAiRequestErrorOptions = {|
  code: string,
  status?: number,
  requestId?: ?string,
  operation?: ?string,
  stage?: ?string,
  reason?: ?string,
  errorType?: ?string,
|};
type PlaymeshAiFetchOptions = {
  method?: string,
  headers?: { [name: string]: string },
  body?: string | Blob,
  signal?: ?AbortSignal,
  credentials?: 'same-origin',
  cache?: 'no-store',
  ...,
};
type PlaymeshAiFetch = (
  url: string,
  options?: PlaymeshAiFetchOptions
) => Promise<Response>;
type PlaymeshAiJsonOptions = {|
  expect?: 'json' | 'text' | 'blob',
  operation?: string,
|};
type PlaymeshAiClientOptions = {|
  fetchImplementation?: PlaymeshAiFetch,
  timeoutMs?: number,
|};
type PlaymeshAiMutableObject = { [key: string]: mixed };
export type PlaymeshAiToolsEnvelope = {
  protocolVersion: string,
  toolsVersion: string,
  gdevelopVersion: string,
  upstreamCommit: string,
  storeNetworkEnabled: boolean,
  toolCount: number,
  +tools: $ReadOnlyArray<PlaymeshAiToolDefinition>,
  contractHash: string,
  capabilitiesReference: PlaymeshAiCapabilitiesReference,
  ...,
};
type PlaymeshAiOpenSessionEnvelope = {
  protocolVersion: string,
  session: PlaymeshAiSession,
  ...,
};
export type PlaymeshAiExecutionRequest = {|
  +success: boolean,
  +output: PlaymeshAiObject,
  +errorCode?: string,
  +errorMessage?: string,
|};
export type PlaymeshAiExecutionEnvelope = {
  call: PlaymeshAiCall,
  ...,
};
*/

const DEFAULT_TIMEOUT_MS = 30000;
const VALID_GAME_ID = /^[A-Za-z0-9._-]{1,128}$/;
export const PLAYMESH_AI_PROMPT_TEMPLATE_MAX_BYTES = 512 * 1024;
const EXPECTED_GDEVELOP_PROMPT_TEMPLATES = Object.freeze({
  chat: 'gdevelop-chat',
  agent: 'gdevelop-agent',
});

const utf8ByteLength = (value /*: string */) /*: number */ =>
  new TextEncoder().encode(value).byteLength;

export const validatePlaymeshAiPromptTemplateContent = (
  content /*: mixed */
) /*: PlaymeshAiPromptTemplateContentValidation */ => {
  if (typeof content !== 'string') return { bytes: 0, error: 'empty' };
  const bytes = utf8ByteLength(content);
  return {
    bytes,
    error:
      !content.trim()
        ? 'empty'
        : bytes > PLAYMESH_AI_PROMPT_TEMPLATE_MAX_BYTES
        ? 'too_large'
        : null,
  };
};

const normalizePlaymeshAiToolRisk = (
  value /*: mixed */
) /*: string */ => {
  if (typeof value !== 'string' || !value.trim()) {
    throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
  }
  return value;
};

const normalizePlaymeshAiToolImplementation = (
  value /*: mixed */
) /*: string */ => {
  if (typeof value !== 'string' || !value.trim()) {
    throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
  }
  return value;
};

const normalizePlaymeshAiToolExecutionKind = (
  value /*: mixed */
) /*: 'editor_function' | 'event_payload' | 'agent_resource_cas' */ => {
  switch (value) {
    case 'editor_function':
    case 'event_payload':
    case 'agent_resource_cas':
      return value;
    default:
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
  }
};

const canonicalizeJson = (value /*: mixed */) /*: mixed */ => {
  if (Array.isArray(value)) return value.map(canonicalizeJson);
  if (value && typeof value === 'object') {
    return Object.keys(value)
      .sort()
      .reduce((canonical /*: { [key: string]: mixed } */, key /*: string */) => {
        canonical[key] = canonicalizeJson(value[key]);
        return canonical;
      }, {});
  }
  return value;
};

const hashCanonicalContract = async (
  contract /*: mixed */
) /*: Promise<string> */ => {
  const bytes = new TextEncoder().encode(
    (() => {
      const serialized = JSON.stringify(canonicalizeJson(contract));
      if (typeof serialized !== 'string') {
        throw new PlaymeshAiRequestError({ code: 'invalid_ai_contract' });
      }
      return serialized;
    })()
  );
  return sha256Hex(bytes, global.crypto);
};

export class PlaymeshAiRequestError extends Error {
  /*:: code: string; status: number; requestId: ?string; operation: ?string; stage: ?string; reason: ?string; errorType: ?string; */

  constructor({
    code,
    status = 0,
    requestId = null,
    operation = null,
    stage = null,
    reason = null,
    errorType = null,
  } /*: PlaymeshAiRequestErrorOptions */) {
    super(reason || 'The local GDevelop AI service is unavailable.');
    this.name = 'PlaymeshAiRequestError';
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.operation = operation;
    this.stage = stage;
    this.reason = reason;
    this.errorType = errorType;
  }
}

const validateGameId = (gameId /*: mixed */) /*: string */ => {
  if (typeof gameId !== 'string' || !VALID_GAME_ID.test(gameId)) {
    throw new PlaymeshAiRequestError({ code: 'invalid_game_id' });
  }
  return gameId;
};

const validateSessionId = (sessionId /*: mixed */) /*: string */ => {
  try {
    return validatePlaymeshAiClientId(sessionId, 'editor session id');
  } catch (_) {
    throw new PlaymeshAiRequestError({ code: 'invalid_editor_session_id' });
  }
};

const normalizeAgentBaseUrl = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !value) {
    throw new PlaymeshAiRequestError({ code: 'invalid_agent_base_url' });
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch (_) {
    throw new PlaymeshAiRequestError({ code: 'invalid_agent_base_url' });
  }
  if (
    parsed.protocol !== 'http:' ||
    parsed.username ||
    parsed.password ||
    parsed.pathname !== '/' ||
    parsed.search ||
    parsed.hash
  ) {
    throw new PlaymeshAiRequestError({ code: 'invalid_agent_base_url' });
  }
  return parsed.origin;
};

const validatePathId = (
  value /*: mixed */,
  code /*: string */
) /*: string */ => {
  try {
    return validatePlaymeshAiClientId(value, 'path identifier');
  } catch (_) {
    throw new PlaymeshAiRequestError({ code });
  }
};

const requireResponseObject = (
  value /*: mixed */
) /*: PlaymeshAiObject */ => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  return value;
};

const validateApprovalGrant = (
  value /*: mixed */
) /*: PlaymeshAiApprovalGrant */ => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  const grant = requireResponseObject(value);
  const grantId = validatePathId(grant.grantId, 'invalid_ai_response');
  const scopeKind = validatePathId(grant.scopeKind, 'invalid_ai_response');
  const scopeId = validatePathId(grant.scopeId, 'invalid_ai_response');
  const operationId = validatePathId(
    grant.operationId,
    'invalid_ai_response'
  );
  const gameId =
    grant.gameId == null
      ? null
      : validateGameId(grant.gameId);
  const projectId =
    grant.projectId == null
      ? null
      : validatePathId(grant.projectId, 'invalid_ai_response');
  const validated /*: PlaymeshAiApprovalGrant */ = {
    grantId,
    scopeKind,
    scopeId,
    operationId,
  };
  if (gameId) validated.gameId = gameId;
  if (projectId) validated.projectId = projectId;
  return validated;
};

const validatePromptLocale = (value /*: mixed */) /*: string */ => {
  if (
    typeof value !== 'string' ||
    !value ||
    value.length > 64 ||
    !/^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/.test(value)
  ) {
    throw new PlaymeshAiRequestError({ code: 'invalid_prompt_locale' });
  }
  return value;
};

const validatePromptTemplate = (
  value /*: mixed */
) /*: PlaymeshAiPromptTemplate */ => {
  const template = requireResponseObject(value);
  const mode = template.mode;
  if (mode !== 'chat' && mode !== 'agent') {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  const id = validatePathId(template.id, 'invalid_ai_response');
  const contentValidation = validatePlaymeshAiPromptTemplateContent(
    template.content
  );
  const defaultValidation = validatePlaymeshAiPromptTemplateContent(
    template.defaultContent
  );
  if (
    id !== EXPECTED_GDEVELOP_PROMPT_TEMPLATES[mode] ||
    typeof template.category !== 'string' ||
    !template.category ||
    template.surface !== 'gdevelop' ||
    typeof template.name !== 'string' ||
    !template.name ||
    typeof template.content !== 'string' ||
    typeof template.defaultContent !== 'string' ||
    contentValidation.error ||
    defaultValidation.error ||
    typeof template.customized !== 'boolean'
  ) {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  return {
    id,
    category: template.category,
    surface: 'gdevelop',
    mode,
    name: template.name,
    content: template.content,
    defaultContent: template.defaultContent,
    customized: template.customized,
    locale: validatePromptLocale(template.locale),
  };
};

const validatePromptTemplateList = (
  value /*: mixed */
) /*: Array<PlaymeshAiPromptTemplate> */ => {
  const envelope = requireResponseObject(value);
  if (!Array.isArray(envelope.categories)) {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  const templates = [];
  envelope.categories.forEach(rawCategory => {
    const category = requireResponseObject(rawCategory);
    if (
      typeof category.id !== 'string' ||
      !category.id ||
      typeof category.name !== 'string' ||
      !Array.isArray(category.items)
    ) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    category.items.forEach(rawTemplate => {
      const template = validatePromptTemplate(rawTemplate);
      if (template.category !== category.id) {
        throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
      }
      templates.push(template);
    });
  });
  const modes = new Set(templates.map(template => template.mode));
  const locales = new Set(templates.map(template => template.locale));
  if (
    templates.length !== 2 ||
    modes.size !== 2 ||
    !modes.has('chat') ||
    !modes.has('agent') ||
    locales.size !== 1
  ) {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
  }
  return templates;
};

const projectBase = (gameId /*: string */) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(validateGameId(gameId))}/ai`;

const sessionBase = (
  gameId /*: string */,
  sessionId /*: string */
) /*: string */ =>
  `${projectBase(gameId)}/editor-sessions/${encodeURIComponent(
    validateSessionId(sessionId)
  )}`;

const promptUrl = (
  gameId /*: string */,
  sessionId /*: string */,
  mode /*: 'chat' | 'agent' */,
  agentBaseUrl /*: ?string */ = null
) /*: string */ => {
  if (mode !== 'chat' && mode !== 'agent') {
    throw new PlaymeshAiRequestError({ code: 'invalid_ai_mode' });
  }
  const parameters = new URLSearchParams({ mode });
  if (mode === 'agent' && agentBaseUrl) {
    parameters.set('baseUrl', normalizeAgentBaseUrl(agentBaseUrl));
  }
  return `${sessionBase(gameId, sessionId)}/prompt.txt?${parameters.toString()}`;
};

const callsBase = (
  gameId /*: string */,
  sessionId /*: string */
) /*: string */ =>
  `${sessionBase(gameId, sessionId)}/calls`;

const parseResponseJson = async (
  response /*: Response */,
  operation /*: string */,
  requestId /*: ?string */
) /*: Promise<mixed> */ => {
  try {
    return await response.json();
  } catch (_) {
    throw new PlaymeshAiRequestError({
      code: 'invalid_ai_response',
      status: response.status,
      operation,
      requestId,
    });
  }
};

const responseHeader = (
  response /*: Response */,
  name /*: string */
) /*: ?string */ => {
  try {
    const headers /*: any */ = response.headers;
    if (!headers || typeof headers.get !== 'function') return null;
    const value = headers.get(name);
    return typeof value === 'string' && value ? value : null;
  } catch (_) {
    return null;
  }
};

const requestOperation = (
  url /*: string */,
  options /*: PlaymeshAiFetchOptions */,
  operation /*: ?string */
) /*: string */ =>
  operation ||
  `${options.method || 'GET'} ${String(url).split(/[?#]/, 1)[0]}`;

const getEnvelopeError = (
  details /*: mixed */,
  status /*: number */,
  operation /*: string */,
  responseRequestId /*: ?string */
) /*: PlaymeshAiRequestError */ => {
  const detailsObject =
    details && typeof details === 'object' && !Array.isArray(details)
      ? requireResponseObject(details)
      : null;
  const envelope =
    detailsObject &&
    detailsObject.error &&
    typeof detailsObject.error === 'object' &&
    !Array.isArray(detailsObject.error)
      ? requireResponseObject(detailsObject.error)
      : null;
  return new PlaymeshAiRequestError({
    code:
      (envelope && typeof envelope.code === 'string' && envelope.code) ||
      (status === 401
        ? 'unauthorized'
        : status === 404
        ? 'not_found'
        : status === 409
        ? 'ai_conflict'
        : status === 413
        ? 'project_too_large'
        : 'ai_request_failed'),
    status,
    requestId:
      detailsObject && typeof detailsObject.requestId === 'string'
        ? detailsObject.requestId
        : responseRequestId,
    operation,
    stage:
      (envelope && typeof envelope.stage === 'string' && envelope.stage) ||
      'response',
    reason:
      (envelope &&
        typeof envelope.reason === 'string' &&
        envelope.reason) ||
      (envelope && typeof envelope.code === 'string' && envelope.code) ||
      `http_${status}`,
    errorType:
      (envelope &&
        typeof envelope.type === 'string' &&
        envelope.type) ||
      'PlaymeshAiRequestError',
  });
};

export class PlaymeshAiClient {
  /*:: _fetch: PlaymeshAiFetch; _timeoutMs: number; */

  constructor({
    fetchImplementation = global.fetch,
    timeoutMs = DEFAULT_TIMEOUT_MS,
  } /*: PlaymeshAiClientOptions */ = {}) {
    this._fetch = fetchImplementation;
    this._timeoutMs = timeoutMs;
  }

  async _request(
    url /*: string */,
    options /*: PlaymeshAiFetchOptions */ = {},
    { expect = 'json', operation = '' } /*: PlaymeshAiJsonOptions */ = {}
  ) /*: Promise<mixed> */ {
    const fallbackOperation = requestOperation(url, options, operation);
    const controller = new AbortController();
    const externalSignal = options.signal;
    const timeoutId = global.setTimeout(
      () => controller.abort(),
      this._timeoutMs
    );
    const abortFromExternal = () => controller.abort();
    if (externalSignal) {
      if (externalSignal.aborted) controller.abort();
      else externalSignal.addEventListener('abort', abortFromExternal, {
        once: true,
      });
    }
    try {
      const response = await this._fetch(url, {
        ...options,
        signal: controller.signal,
        credentials: 'same-origin',
        cache: 'no-store',
      });
      const responseOperation =
        responseHeader(response, 'X-Playmesh-Operation-ID') ||
        fallbackOperation;
      const responseRequestId = responseHeader(response, 'X-Request-ID');
      if (!response.ok) {
        let details = null;
        try {
          details = await response.json();
        } catch (_) {}
        throw getEnvelopeError(
          details,
          response.status,
          responseOperation,
          responseRequestId
        );
      }
      if (expect === 'text') return response.text();
      if (expect === 'blob') return response.blob();
      return parseResponseJson(response, responseOperation, responseRequestId);
    } catch (error) {
      if (
        error instanceof PlaymeshAiRequestError ||
        error instanceof PlaymeshAiProtocolError
      ) {
        throw error;
      }
      if (externalSignal && externalSignal.aborted) {
        throw new PlaymeshAiRequestError({
          code: 'cancelled',
          operation: fallbackOperation,
          stage: 'pre_request',
          reason: 'The local request was cancelled before completion.',
          errorType: error && error.name ? String(error.name) : 'AbortError',
        });
      }
      if (controller.signal.aborted) {
        throw new PlaymeshAiRequestError({
          code: 'ai_request_timeout',
          operation: fallbackOperation,
          stage: 'request',
          reason: `The local request exceeded ${this._timeoutMs} ms.`,
          errorType: error && error.name ? String(error.name) : 'TimeoutError',
        });
      }
      throw new PlaymeshAiRequestError({
        code: 'ai_unavailable',
        operation: fallbackOperation,
        stage: 'request',
        reason: 'The local request failed before a response was received.',
        errorType: error && error.name ? String(error.name) : 'Error',
      });
    } finally {
      global.clearTimeout(timeoutId);
      if (externalSignal) {
        externalSignal.removeEventListener('abort', abortFromExternal);
      }
    }
  }

  _json(
    method /*: string */,
    body /*: ?PlaymeshAiObject */ = null,
    signal /*: ?AbortSignal */
  ) /*: PlaymeshAiFetchOptions */ {
    return {
      method,
      headers: { 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal,
    };
  }

  async getTools(
    signal /*: ?AbortSignal */,
    requestPath /*: string */ = '/dev/api/gdevelop/ai/tools'
  ) /*: Promise<PlaymeshAiToolsEnvelope> */ {
    const result = requireResponseObject(
      await this._request(requestPath, { signal })
    );
    const rawTools = Array.isArray(result.tools) ? result.tools : [];
    const tools /*: Array<PlaymeshAiToolDefinition> */ = rawTools.map(tool => {
      const definition = requireResponseObject(tool);
      const name = definition.name;
      const summary = definition.summary;
      const risk = normalizePlaymeshAiToolRisk(definition.risk);
      const modifiesProject = definition.modifiesProject;
      const approvalRequired = definition.approvalRequired;
      const implementation = normalizePlaymeshAiToolImplementation(
        definition.implementation
      );
      const officialImplementationName = definition.officialImplementationName;
      const officialArguments = requireResponseObject(
        definition.officialArguments
      );
      const chatEnabled = definition.chatEnabled;
      const agentEnabled = definition.agentEnabled;
      const timeoutMs = definition.timeoutMs;
      const executionKind = normalizePlaymeshAiToolExecutionKind(
        definition.executionKind
      );
      const executionConfig =
        definition.executionConfig == null
          ? {}
          : requireResponseObject(definition.executionConfig);
      if (
        typeof name !== 'string' ||
        !name ||
        typeof summary !== 'string' ||
        typeof modifiesProject !== 'boolean' ||
        typeof approvalRequired !== 'boolean' ||
        typeof officialImplementationName !== 'string' ||
        !officialImplementationName ||
        typeof chatEnabled !== 'boolean' ||
        typeof agentEnabled !== 'boolean' ||
        !Number.isSafeInteger(timeoutMs) ||
        timeoutMs < 1
      ) {
        throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
      }
      const argumentsSchema = requireResponseObject(
        definition.argumentsSchema
      );
      return {
        ...definition,
        name,
        summary,
        argumentsSchema,
        risk,
        modifiesProject,
        approvalRequired,
        implementation,
        officialImplementationName,
        officialArguments,
        chatEnabled,
        agentEnabled,
        timeoutMs,
        executionKind,
        executionConfig,
      };
    });
    const actualNames = tools.map(tool => tool.name);
    const protocolVersion = result.protocolVersion;
    const toolsVersion = result.toolsVersion;
    const gdevelopVersion = result.gdevelopVersion;
    const upstreamCommit = result.upstreamCommit;
    const storeNetworkEnabled = result.storeNetworkEnabled;
    if (
      typeof protocolVersion !== 'string' ||
      !protocolVersion ||
      typeof toolsVersion !== 'string' ||
      !toolsVersion ||
      typeof gdevelopVersion !== 'string' ||
      !gdevelopVersion ||
      typeof upstreamCommit !== 'string' ||
      !upstreamCommit ||
      typeof storeNetworkEnabled !== 'boolean' ||
      !Array.isArray(result.tools) ||
      !Number.isSafeInteger(result.toolCount) ||
      result.toolCount < 0 ||
      result.toolCount !== tools.length ||
      new Set(actualNames).size !== tools.length ||
      !result.capabilitiesReference
    ) {
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
    }
    const capabilitiesReference = validatePlaymeshAiCapabilitiesReference(
      result.capabilitiesReference
    );
    if (
      capabilitiesReference.protocolVersion !== protocolVersion ||
      capabilitiesReference.toolsVersion !== toolsVersion ||
      capabilitiesReference.gdevelopVersion !== gdevelopVersion ||
      capabilitiesReference.upstreamCommit !== upstreamCommit ||
      capabilitiesReference.storeNetworkEnabled !== storeNetworkEnabled ||
      capabilitiesReference.toolCount !== result.toolCount ||
      result.contractHash !== capabilitiesReference.contractHash
    ) {
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
    }
    // The Gateway owns the complete contract. Hash every current or future
    // contract field verbatim and remove only HTTP-envelope metadata that the
    // Gateway adds after computing contractHash.
    const canonicalContract = Object.keys(result).reduce(
      (contract /*: PlaymeshAiMutableObject */, key /*: string */) => {
        if (
          key !== 'requestId' &&
          key !== 'contractHash' &&
          key !== 'capabilitiesReference'
        ) {
          contract[key] = result[key];
        }
        return contract;
      },
      {}
    );
    if ((await hashCanonicalContract(canonicalContract)) !== result.contractHash) {
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_tools' });
    }
    return {
      ...result,
      protocolVersion,
      toolsVersion,
      gdevelopVersion,
      upstreamCommit,
      storeNetworkEnabled,
      toolCount: tools.length,
      tools,
      contractHash: capabilitiesReference.contractHash,
      capabilitiesReference,
    };
  }

  async getSessionTools(
    gameId /*: string */,
    sessionId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiToolsEnvelope> */ {
    return this.getTools(signal, `${sessionBase(gameId, sessionId)}/tools`);
  }

  async listAgentBaseUrls(
    signal /*: ?AbortSignal */
  ) /*: Promise<Array<string>> */ {
    const status = requireResponseObject(
      await this._request(
        '/dev/api/status',
        { signal },
        { operation: 'workspace.status' }
      )
    );
    if (!Array.isArray(status.baseUrls) || status.baseUrls.length > 32) {
      throw new PlaymeshAiRequestError({ code: 'invalid_agent_base_urls' });
    }
    const baseUrls = Array.from(
      new Set(status.baseUrls.map(normalizeAgentBaseUrl))
    );
    if (!baseUrls.length) {
      throw new PlaymeshAiRequestError({ code: 'no_agent_base_url' });
    }
    return baseUrls;
  }

  async getSessionStagedResource(
    gameId /*: string */,
    sessionId /*: string */,
    contentHash /*: string */,
    size /*: number */,
    signal /*: ?AbortSignal */
  ) /*: Promise<Blob> */ {
    if (
      !/^[a-f0-9]{64}$/.test(contentHash) ||
      !Number.isSafeInteger(size) ||
      size < 1
    ) {
      throw new PlaymeshAiRequestError({ code: 'invalid_staged_resource' });
    }
    const body = await this._request(
      `${sessionBase(gameId, sessionId)}/resource-staging/${
        contentHash
      }?size=${encodeURIComponent(String(size))}`,
      { signal },
      { expect: 'blob' }
    );
    if (!(body instanceof Blob)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return body;
  }

  /** The versioned context DTO is owned by the Gateway contract. */
  async openSession(
    gameId /*: string */,
    sessionRequest /*: PlaymeshAiObject */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiOpenSessionEnvelope> */ {
    const result = requireResponseObject(
      await this._request(
        `${projectBase(gameId)}/editor-sessions`,
        this._json('POST', sessionRequest, signal)
      )
    );
    if (result.protocolVersion !== PLAYMESH_AI_SESSION_PROTOCOL_VERSION) {
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_session' });
    }
    return {
      protocolVersion: PLAYMESH_AI_SESSION_PROTOCOL_VERSION,
      session: validatePlaymeshAiSession(result.session),
    };
  }

  async getSession(
    gameId /*: string */,
    sessionId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiSession> */ {
    const result = requireResponseObject(
      await this._request(sessionBase(gameId, sessionId), { signal })
    );
    if (result.protocolVersion !== PLAYMESH_AI_SESSION_PROTOCOL_VERSION) {
      throw new PlaymeshAiRequestError({ code: 'incompatible_ai_session' });
    }
    return validatePlaymeshAiSession(result.session);
  }

  async updateSession(
    gameId /*: string */,
    sessionId /*: string */,
    update /*: PlaymeshAiObject */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiSession> */ {
    if (
      !update ||
      typeof update !== 'object' ||
      Array.isArray(update) ||
      (!('locale' in update) && !('context' in update)) ||
      Object.keys(update).some(key => !['locale', 'context'].includes(key))
    ) {
      throw new PlaymeshAiRequestError({ code: 'invalid_session_update' });
    }
    const result = requireResponseObject(
      await this._request(
        sessionBase(gameId, sessionId),
        this._json('PATCH', update, signal)
      )
    );
    return validatePlaymeshAiSession(result.session);
  }

  async updateSessionLocale(
    gameId /*: string */,
    sessionId /*: string */,
    locale /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiSession> */ {
    return this.updateSession(gameId, sessionId, { locale }, signal);
  }

  async closeSession(
    gameId /*: string */,
    sessionId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiObject> */ {
    return requireResponseObject(
      await this._request(
        sessionBase(gameId, sessionId),
        this._json('DELETE', null, signal)
      )
    );
  }

  async readAppClipboardText(
    signal /*: ?AbortSignal */
  ) /*: Promise<string> */ {
    const result = requireResponseObject(
      await this._request(
        '/dev/api/clipboard',
        { signal },
        { operation: 'workspace.clipboard_read' }
      )
    );
    if (typeof result.text !== 'string') {
      throw new PlaymeshAiRequestError({
        code: 'invalid_ai_response',
        operation: 'workspace.clipboard_read',
      });
    }
    return result.text;
  }

  async copyPromptToClipboard({
    gameId,
    sessionId,
    mode,
    agentBaseUrl = null,
    clipboard = global.navigator && global.navigator.clipboard,
    legacyCopy,
    signal,
  } /*: {|
    gameId: string,
    sessionId: string,
    mode: 'chat' | 'agent',
    agentBaseUrl?: ?string,
    clipboard?: ?PlaymeshClipboard,
    legacyCopy?: PlaymeshLegacyCopy,
    signal?: AbortSignal,
  |} */) /*: Promise<void> */ {
    // The Agent prompt contains the persistent root Developer Token. Keep it
    // out of React state. The shared clipboard helper clears and removes its
    // temporary DOM node synchronously when a WebView needs legacy copying.
    const prompt = await this._request(
      promptUrl(gameId, sessionId, mode, agentBaseUrl),
      { signal },
      {
        expect: 'text',
        operation: 'gdevelop.ai.session.prompt',
      }
    );
    if (typeof prompt !== 'string') {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    const copied = await copyPlaymeshText({
      value: prompt,
      clipboard,
      ...(legacyCopy ? { legacyCopy } : {}),
    });
    if (!copied) {
      throw new PlaymeshAiRequestError({
        code: 'clipboard_unavailable',
        operation: 'gdevelop.ai.session.prompt.copy',
      });
    }
  }

  async downloadPrompt({
    gameId,
    sessionId,
    mode,
    agentBaseUrl = null,
    signal,
  } /*: {|
    gameId: string,
    sessionId: string,
    mode: 'chat' | 'agent',
    agentBaseUrl?: ?string,
    signal?: AbortSignal,
  |} */) /*: Promise<void> */ {
    const promptBody = await this._request(
      promptUrl(gameId, sessionId, mode, agentBaseUrl),
      { signal },
      { expect: 'blob' }
    );
    if (!(promptBody instanceof Blob)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    const promptBlob = promptBody;
    const url = URL.createObjectURL(promptBlob);
    try {
      const anchor = document.createElement('a');
      anchor.href = url;
      anchor.download = `${validateGameId(gameId)}-gdevelop-ai-prompt.txt`;
      anchor.hidden = true;
      const body = document.body;
      if (!body) {
        throw new PlaymeshAiRequestError({ code: 'document_unavailable' });
      }
      body.appendChild(anchor);
      anchor.click();
      anchor.remove();
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  async createTurn(
    gameId /*: string */,
    sessionId /*: string */,
    clientMessageId /*: ?string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiTurn> */ {
    const result = requireResponseObject(
      await this._request(
        `${sessionBase(gameId, sessionId)}/turns`,
        this._json(
          'POST',
          clientMessageId ? { clientMessageId } : {},
          signal
        )
      )
    );
    return validatePlaymeshAiTurn(result.turn);
  }

  async cancelTurn(
    gameId /*: string */,
    sessionId /*: string */,
    turnId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiObject> */ {
    return requireResponseObject(
      await this._request(
        `${sessionBase(gameId, sessionId)}/turns/${encodeURIComponent(
          validatePathId(turnId, 'invalid_turn_id')
        )}/cancel`,
        this._json('POST', {}, signal)
      )
    );
  }

  async enqueueCall(
    gameId /*: string */,
    sessionId /*: string */,
    callRequest /*: PlaymeshAiEnqueueRequest */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiCall> */ {
    const result = requireResponseObject(
      await this._request(
        callsBase(gameId, sessionId),
        this._json('POST', callRequest, signal)
      )
    );
    return validatePlaymeshAiCall(result.call);
  }

  async listCalls(
    gameId /*: string */,
    sessionId /*: string */,
    afterSequence /*: number */ = 0,
    signal /*: ?AbortSignal */
  ) /*: Promise<Array<PlaymeshAiCall>> */ {
    if (!Number.isSafeInteger(afterSequence) || afterSequence < 0) {
      throw new PlaymeshAiRequestError({ code: 'invalid_call_sequence' });
    }
    const result = requireResponseObject(
      await this._request(
        `${callsBase(gameId, sessionId)}?afterSequence=${encodeURIComponent(
        String(afterSequence)
        )}`,
        { signal }
      )
    );
    if (!Array.isArray(result.calls)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return result.calls.map(validatePlaymeshAiCall);
  }

  async leaseNextCall(
    gameId /*: string */,
    sessionId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<?PlaymeshAiCall> */ {
    const result = requireResponseObject(
      await this._request(
        `${callsBase(gameId, sessionId)}/next`,
        this._json('POST', {}, signal)
      )
    );
    return result.call == null ? null : validatePlaymeshAiCall(result.call);
  }

  async finishExecution(
    gameId /*: string */,
    sessionId /*: string */,
    callId /*: string */,
    execution /*: PlaymeshAiExecutionRequest */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiExecutionEnvelope> */ {
    const keys = Object.keys(execution || {}).sort();
    const success = execution && execution.success;
    const validKeys =
      success === true
        ? ['output', 'success']
        : ['errorCode', 'errorMessage', 'output', 'success'];
    if (
      (success !== true && success !== false) ||
      JSON.stringify(keys) !== JSON.stringify(validKeys) ||
      !execution.output ||
      typeof execution.output !== 'object' ||
      Array.isArray(execution.output) ||
      (success === false &&
        (typeof execution.errorCode !== 'string' ||
          typeof execution.errorMessage !== 'string'))
    ) {
      throw new PlaymeshAiRequestError({ code: 'invalid_execution_result' });
    }
    const result = requireResponseObject(
      await this._request(
        `${callsBase(gameId, sessionId)}/${encodeURIComponent(
          validatePathId(callId, 'invalid_call_id')
        )}/execution`,
        this._json('POST', execution, signal)
      )
    );
    const call = validatePlaymeshAiCall(result.call);
    return { call };
  }

  async cancelCall(
    gameId /*: string */,
    sessionId /*: string */,
    callId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiCall> */ {
    const result = requireResponseObject(
      await this._request(
        `${callsBase(gameId, sessionId)}/${encodeURIComponent(
          validatePathId(callId, 'invalid_call_id')
        )}/cancel`,
        this._json('POST', {}, signal)
      )
    );
    return validatePlaymeshAiCall(result.call);
  }

  async listApprovals(
    signal /*: ?AbortSignal */
  ) /*: Promise<Array<PlaymeshAiObject>> */ {
    const result = requireResponseObject(
      await this._request('/dev/api/ai-approvals', {
        signal,
      })
    );
    if (!Array.isArray(result.approvals)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return result.approvals.map(requireResponseObject);
  }

  async decideApproval(
    approvalId /*: string */,
    decision /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiObject> */ {
    if (!['once', 'project', 'always', 'reject'].includes(decision)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_approval_decision' });
    }
    return requireResponseObject(
      await this._request(
        `/dev/api/ai-approvals/${encodeURIComponent(
          validatePathId(approvalId, 'invalid_approval_id')
        )}`,
        this._json('POST', { decision }, signal)
      )
    );
  }

  async listApprovalGrants(
    signal /*: ?AbortSignal */
  ) /*: Promise<Array<PlaymeshAiApprovalGrant>> */ {
    const result = requireResponseObject(
      await this._request('/dev/api/ai-approval-grants', { signal })
    );
    if (!Array.isArray(result.grants)) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return result.grants.map(validateApprovalGrant);
  }

  async revokeApprovalGrant(
    grantId /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<{| grantId: string, revoked: boolean |}> */ {
    const validatedGrantId = validatePathId(
      grantId,
      'invalid_ai_approval_grant_id'
    );
    try {
      const result = requireResponseObject(
        await this._request(
          `/dev/api/ai-approval-grants/${encodeURIComponent(validatedGrantId)}`,
          { method: 'DELETE', signal }
        )
      );
      if (result.grantId !== validatedGrantId || result.revoked !== true) {
        throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
      }
      return { grantId: validatedGrantId, revoked: true };
    } catch (error) {
      if (
        error instanceof PlaymeshAiRequestError &&
        error.code === 'ai_approval_grant_not_found'
      ) {
        return { grantId: validatedGrantId, revoked: false };
      }
      throw error;
    }
  }

  async listPromptTemplates(
    locale /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<Array<PlaymeshAiPromptTemplate>> */ {
    const query = new URLSearchParams({
      surface: 'gdevelop',
      locale: validatePromptLocale(locale),
    });
    return validatePromptTemplateList(
      await this._request(`/dev/api/ai-prompt-templates?${query.toString()}`, {
        signal,
      })
    );
  }

  async savePromptTemplate(
    templateId /*: string */,
    content /*: string */,
    locale /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiPromptTemplate> */ {
    const validation = validatePlaymeshAiPromptTemplateContent(content);
    if (validation.error) {
      throw new PlaymeshAiRequestError({
        code:
          validation.error === 'too_large'
            ? 'prompt_template_too_large'
            : 'prompt_template_empty',
      });
    }
    const id = validatePathId(templateId, 'invalid_prompt_template_id');
    if (!Object.values(EXPECTED_GDEVELOP_PROMPT_TEMPLATES).includes(id)) {
      throw new PlaymeshAiRequestError({
        code: 'invalid_prompt_template_id',
      });
    }
    const query = new URLSearchParams({
      locale: validatePromptLocale(locale),
    });
    const envelope = requireResponseObject(
      await this._request(
        `/dev/api/ai-prompt-templates/${encodeURIComponent(
          id
        )}?${query.toString()}`,
        this._json('PUT', { content }, signal)
      )
    );
    const template = validatePromptTemplate(envelope.template);
    if (template.id !== id || !template.customized) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return template;
  }

  async resetPromptTemplate(
    templateId /*: string */,
    locale /*: string */,
    signal /*: ?AbortSignal */
  ) /*: Promise<PlaymeshAiPromptTemplate> */ {
    const id = validatePathId(templateId, 'invalid_prompt_template_id');
    if (!Object.values(EXPECTED_GDEVELOP_PROMPT_TEMPLATES).includes(id)) {
      throw new PlaymeshAiRequestError({
        code: 'invalid_prompt_template_id',
      });
    }
    const query = new URLSearchParams({
      locale: validatePromptLocale(locale),
    });
    const envelope = requireResponseObject(
      await this._request(
        `/dev/api/ai-prompt-templates/${encodeURIComponent(
          id
        )}?${query.toString()}`,
        { method: 'DELETE', signal }
      )
    );
    const template = validatePromptTemplate(envelope.template);
    if (template.id !== id || template.customized) {
      throw new PlaymeshAiRequestError({ code: 'invalid_ai_response' });
    }
    return template;
  }
}

export const createPlaymeshAiClient = (
  options /*: PlaymeshAiClientOptions */ = {}
) /*: PlaymeshAiClient */ =>
  new PlaymeshAiClient(options);

export const playmeshAiClient /*: PlaymeshAiClient */ = createPlaymeshAiClient();

export default PlaymeshAiClient;
