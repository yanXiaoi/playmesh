// @flow

const CAPABILITY = 'gdevelop.history.v2';
const REQUEST_TIMEOUT_MS = 30000;

/*::
type PlaymeshJsonObject = { +[string]: mixed };
type PlaymeshMutableJsonObject = { [string]: mixed };

export type PlaymeshProjectRef = $ReadOnly<{|
  gameId: string,
|}>;

export type PlaymeshProjectLifecycleResponse = {
  +historyCapability: string,
  +project: {
    +gameId: string,
    ...
  },
  ...
};

export type PlaymeshManagedProjectIdentity = {|
  +schemaVersion: 1,
  +kind: 'gdevelop',
  +gameId: string,
  +name: ?string,
  +fileIdentifiers: Array<string>,
  +createdAt: string,
  +updatedAt: string,
|};

export type PlaymeshManagedProjectSummary = {|
  +identity: PlaymeshManagedProjectIdentity,
  +hasCurrent: boolean,
|};

export type PlaymeshManagedProjectListDiagnostic = {|
  +code: string,
  +entry: string,
  +gameId: ?string,
  +messageKey: string,
|};

export type PlaymeshManagedProjectListResponse = {|
  +requestId: string,
  +activeGameId: ?string,
  +projects: Array<PlaymeshManagedProjectSummary>,
  +diagnostics: Array<PlaymeshManagedProjectListDiagnostic>,
|};

export type PlaymeshProjectDeleteResponse = {
  +gameId: string,
  +projectDeleted: boolean,
  +historyDeleted: boolean,
  +cleanupPending: boolean,
  ...
};

export type PlaymeshProjectLifecycleSoftResult<Result> =
  | {| ok: true, result: Result |}
  | {| ok: false, error: PlaymeshProjectLifecycleError |};

type PlaymeshProjectLifecycleStatus = 'syncing' | 'synced' | 'error';

type PlaymeshProjectLifecycleRequest = {|
  projectRef: PlaymeshProjectRef,
  fileIdentifier?: ?string,
  name?: ?string,
  signal?: ?AbortSignal,
|};

type PlaymeshProjectCreateRequest = {|
  projectRef: PlaymeshProjectRef,
  origin: 'create' | 'duplicate' | 'open',
  fileIdentifier?: ?string,
  name?: ?string,
  signal?: ?AbortSignal,
|};
*/

const jsonObject = (value /*: mixed */) /*: ?PlaymeshJsonObject */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: PlaymeshJsonObject */)
    : null;

export class PlaymeshProjectLifecycleError extends Error {
  /*::
  code: string;
  details: mixed;
  status: number;
  requestId: ?string;
  operation: ?string;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    details /*: mixed */ = null,
    diagnostics /*: {|
      status?: number,
      requestId?: ?string,
      operation?: ?string,
    |} */ = {}
  ) {
    super(message);
    this.name = 'PlaymeshProjectLifecycleError';
    this.code = code;
    this.details = details;
    this.status = Number.isSafeInteger(diagnostics.status)
      ? diagnostics.status
      : 0;
    this.requestId =
      typeof diagnostics.requestId === 'string' && diagnostics.requestId
        ? diagnostics.requestId
        : null;
    this.operation =
      typeof diagnostics.operation === 'string' && diagnostics.operation
        ? diagnostics.operation
        : null;
  }
}

const validateGameId = (gameId /*: mixed */) /*: string */ => {
  const normalized = typeof gameId === 'string' ? gameId.trim() : '';
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(normalized)) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_project_id',
      '本地游戏标识无效。'
    );
  }
  return normalized;
};

export const createPlaymeshProjectRef = (
  gameId /*: mixed */
) /*: PlaymeshProjectRef */ => ({ gameId: validateGameId(gameId) });

// Keep UI/storage code dependent on a project reference rather than URL layout.
// The v1 Gateway contract deliberately resolves this reference to packageName/gameId.
export const resolvePlaymeshProjectId = (
  projectRef /*: ?PlaymeshProjectRef */
) /*: string */ => validateGameId(projectRef && projectRef.gameId);

const projectUrl = (projectRef /*: PlaymeshProjectRef */) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    resolvePlaymeshProjectId(projectRef)
  )}`;

const dispatchStatus = (
  projectRef /*: PlaymeshProjectRef */,
  state /*: PlaymeshProjectLifecycleStatus */,
  error /*: ?{|
    code: string,
    message: string,
    details: mixed,
  |} */ = null
) /*: void */ => {
  window.dispatchEvent(
    new CustomEvent('playmesh-gdevelop-project-status', {
      detail: {
        gameId: resolvePlaymeshProjectId(projectRef),
        state,
        error,
        timestamp: Date.now(),
      },
    })
  );
};

const parseError = async (
  response /*: Response */,
  operation /*: string */
) /*: Promise<PlaymeshProjectLifecycleError> */ => {
  let details /*: mixed */ = null;
  try {
    details = await response.json();
  } catch (_) {}
  const detailsObject = jsonObject(details);
  const envelope = jsonObject(detailsObject && detailsObject.error);
  const code =
    envelope && typeof envelope.code === 'string' && envelope.code
      ? envelope.code
      : response.status === 401 || response.status === 403
      ? 'unauthorized'
      : response.status === 404
      ? 'not_found'
      : response.status === 409
      ? 'project_id_conflict'
      : 'project_lifecycle_failed';
  const message =
    envelope && typeof envelope.message === 'string' && envelope.message
      ? envelope.message
      : code === 'project_id_conflict'
      ? '这个游戏标识已被另一个本地工程占用。请复制为新游戏后重试。'
      : `本地工程服务请求失败（HTTP ${response.status}）。`;
  const requestId =
    detailsObject && typeof detailsObject.requestId === 'string'
      ? detailsObject.requestId
      : response.headers.get('x-request-id');
  return new PlaymeshProjectLifecycleError(code, message, details, {
    status: response.status,
    requestId,
    operation,
  });
};

const requestJson = async (
  url /*: string */,
  options /*: RequestOptions */ = {}
) /*: Promise<mixed> */ => {
  const operation = `${options.method || 'GET'} ${url}`;
  const controller = new AbortController();
  const timeoutId = window.setTimeout(
    () => controller.abort(),
    REQUEST_TIMEOUT_MS
  );
  const externalSignal = options.signal;
  const abortFromExternal = () => controller.abort();
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort();
    else
      externalSignal.addEventListener('abort', abortFromExternal, {
        once: true,
      });
  }
  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
      credentials: 'same-origin',
      cache: 'no-store',
    });
    if (!response.ok) throw await parseError(response, operation);
    try {
      return await response.json();
    } catch (_) {
      throw new PlaymeshProjectLifecycleError(
        'invalid_response',
        '本地工程服务返回了无效响应。',
        null,
        { operation }
      );
    }
  } catch (error) {
    if (error instanceof PlaymeshProjectLifecycleError) throw error;
    if (externalSignal && externalSignal.aborted) {
      throw new PlaymeshProjectLifecycleError(
        'cancelled',
        '本地工程操作已取消。',
        null,
        { operation }
      );
    }
    if (controller.signal.aborted) {
      throw new PlaymeshProjectLifecycleError(
        'project_lifecycle_timeout',
        '本地工程服务响应超时。',
        null,
        { operation }
      );
    }
    throw new PlaymeshProjectLifecycleError(
      'project_lifecycle_unavailable',
      '当前无法连接 Playmesh 本地工程服务。',
      null,
      { operation }
    );
  } finally {
    window.clearTimeout(timeoutId);
    if (externalSignal) {
      externalSignal.removeEventListener('abort', abortFromExternal);
    }
  }
};

const jsonOptions = (
  method /*: string */,
  body /*: PlaymeshJsonObject */,
  signal /*: ?AbortSignal */
) /*: RequestOptions */ => ({
  method,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
  signal,
});

const validateProjectResponse = (
  response /*: mixed */,
  projectRef /*: PlaymeshProjectRef */
) /*: PlaymeshProjectLifecycleResponse */ => {
  const responseObject = jsonObject(response);
  const project = jsonObject(responseObject && responseObject.project);
  if (
    !responseObject ||
    responseObject.historyCapability !== CAPABILITY ||
    !project ||
    project.gameId !== resolvePlaymeshProjectId(projectRef)
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程服务返回了不匹配的工程。'
    );
  }
  return {
    ...responseObject,
    historyCapability: CAPABILITY,
    project: {
      ...project,
      gameId: resolvePlaymeshProjectId(projectRef),
    },
  };
};

const requireIsoTimestamp = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程列表包含无效时间。'
    );
  }
  return value;
};

const validateCurrentEvidence = (value /*: mixed */) /*: boolean */ => {
  if (value === null) return false;
  const evidence = jsonObject(value);
  const project = jsonObject(evidence && evidence.project);
  const resources = evidence && evidence.resources;
  if (
    !evidence ||
    !Number.isSafeInteger(evidence.revision) ||
    // LocalVersionStore uses revision 0 for the first authoritative current.
    // History versions start at 1 only after the first explicit snapshot.
    evidence.revision < 0 ||
    !project ||
    typeof project.contentHash !== 'string' ||
    !/^[a-f0-9]{64}$/.test(project.contentHash) ||
    !Number.isSafeInteger(project.size) ||
    !Array.isArray(resources)
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程列表包含无效 current evidence。'
    );
  }
  for (const rawResource of resources) {
    const resource = jsonObject(rawResource);
    if (
      !resource ||
      typeof resource.contentHash !== 'string' ||
      !/^[a-f0-9]{64}$/.test(resource.contentHash) ||
      !Number.isSafeInteger(resource.size)
    ) {
      throw new PlaymeshProjectLifecycleError(
        'invalid_response',
        '本地工程列表包含无效资源 evidence。'
      );
    }
  }
  return true;
};

const validateManagedProjectIdentity = (
  value /*: mixed */
) /*: PlaymeshManagedProjectIdentity */ => {
  const identity = jsonObject(value);
  const fileIdentifiers = identity && identity.fileIdentifiers;
  if (
    !identity ||
    identity.schemaVersion !== 1 ||
    identity.kind !== 'gdevelop' ||
    typeof identity.gameId !== 'string' ||
    (identity.name !== undefined && typeof identity.name !== 'string') ||
    !Array.isArray(fileIdentifiers) ||
    !fileIdentifiers.every(
      fileIdentifier =>
        typeof fileIdentifier === 'string' && !!fileIdentifier.trim()
    )
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程列表包含无效工程身份。'
    );
  }
  const gameId = validateGameId(identity.gameId);
  return {
    schemaVersion: 1,
    kind: 'gdevelop',
    gameId,
    name: typeof identity.name === 'string' ? identity.name : null,
    fileIdentifiers: fileIdentifiers.map(value => String(value)),
    createdAt: requireIsoTimestamp(identity.createdAt),
    updatedAt: requireIsoTimestamp(identity.updatedAt),
  };
};

const createManagedProjectListDiagnostic = (
  code /*: string */,
  entry /*: string */,
  gameId /*: ?string */ = null
) /*: PlaymeshManagedProjectListDiagnostic */ => ({
  code,
  entry,
  gameId,
  messageKey: `gdevelop.projectList.diagnostics.${code}`,
});

const appendManagedProjectListDiagnostic = (
  diagnostics /*: Array<PlaymeshManagedProjectListDiagnostic> */,
  diagnostic /*: PlaymeshManagedProjectListDiagnostic */
) /*: void */ => {
  if (
    diagnostics.some(
      item =>
        item.code === diagnostic.code &&
        item.entry === diagnostic.entry &&
        item.gameId === diagnostic.gameId
    )
  ) {
    return;
  }
  diagnostics.push(diagnostic);
};

const validateManagedProjectListDiagnostic = (
  value /*: mixed */,
  index /*: number */
) /*: PlaymeshManagedProjectListDiagnostic */ => {
  const diagnostic = jsonObject(value);
  if (
    !diagnostic ||
    typeof diagnostic.code !== 'string' ||
    typeof diagnostic.entry !== 'string' ||
    typeof diagnostic.messageKey !== 'string' ||
    (diagnostic.gameId !== undefined &&
      diagnostic.gameId !== null &&
      typeof diagnostic.gameId !== 'string')
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      `本地工程列表第 ${index + 1} 条诊断无效。`
    );
  }
  const messageKey = diagnostic.messageKey;
  if (typeof messageKey !== 'string') {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      `本地工程列表第 ${index + 1} 条诊断无效。`
    );
  }
  return {
    code: diagnostic.code,
    entry: diagnostic.entry,
    gameId:
      typeof diagnostic.gameId === 'string'
        ? validateGameId(diagnostic.gameId)
        : null,
    messageKey,
  };
};

const validateManagedProjectListResponse = (
  value /*: mixed */
) /*: PlaymeshManagedProjectListResponse */ => {
  const response = jsonObject(value);
  const projects = response && response.projects;
  const diagnostics = response && response.diagnostics;
  const activeGameId = response && response.activeGameId;
  if (
    !response ||
    typeof response.requestId !== 'string' ||
    !response.requestId ||
    !Array.isArray(projects) ||
    !Array.isArray(diagnostics)
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程列表响应无效。'
    );
  }
  const responseRequestId = response.requestId;
  if (typeof responseRequestId !== 'string') {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程列表响应无效。'
    );
  }
  const validatedDiagnostics /*: Array<PlaymeshManagedProjectListDiagnostic> */ = [];
  diagnostics.forEach((rawDiagnostic, index) => {
    try {
      appendManagedProjectListDiagnostic(
        validatedDiagnostics,
        validateManagedProjectListDiagnostic(rawDiagnostic, index)
      );
    } catch (_) {
      appendManagedProjectListDiagnostic(
        validatedDiagnostics,
        createManagedProjectListDiagnostic(
          'gdevelop_metadata_invalid',
          `diagnostic-${index + 1}`
        )
      );
    }
  });

  const validatedProjects /*: Array<PlaymeshManagedProjectSummary> */ = [];
  projects.forEach((rawProject, index) => {
    const project = jsonObject(rawProject);
    let identity /*: ?PlaymeshManagedProjectIdentity */ = null;
    try {
      identity = validateManagedProjectIdentity(project && project.identity);
    } catch (_) {
      appendManagedProjectListDiagnostic(
        validatedDiagnostics,
        createManagedProjectListDiagnostic(
          'gdevelop_metadata_invalid',
          `project-${index + 1}`
        )
      );
      return;
    }
    if (!identity) return;
    let hasCurrent = false;
    try {
      if (!project || !('currentEvidence' in project)) {
        throw new PlaymeshProjectLifecycleError(
          'invalid_response',
          '本地工程列表项目缺少 current evidence。'
        );
      }
      hasCurrent = validateCurrentEvidence(project.currentEvidence);
    } catch (_) {
      appendManagedProjectListDiagnostic(
        validatedDiagnostics,
        createManagedProjectListDiagnostic(
          'gdevelop_current_evidence_unavailable',
          identity.gameId,
          identity.gameId
        )
      );
    }
    validatedProjects.push({ identity, hasCurrent });
  });

  let validatedActiveGameId /*: ?string */ = null;
  if (typeof activeGameId === 'string') {
    try {
      validatedActiveGameId = validateGameId(activeGameId);
    } catch (_) {
      appendManagedProjectListDiagnostic(
        validatedDiagnostics,
        createManagedProjectListDiagnostic(
          'gdevelop_metadata_invalid',
          'activeGameId'
        )
      );
    }
  } else if (activeGameId != null) {
    appendManagedProjectListDiagnostic(
      validatedDiagnostics,
      createManagedProjectListDiagnostic(
        'gdevelop_metadata_invalid',
        'activeGameId'
      )
    );
  }
  const activeProjectGameId = validatedActiveGameId;
  if (
    activeProjectGameId &&
    !validatedProjects.some(
      project =>
        project.hasCurrent &&
        project.identity.gameId === activeProjectGameId
    )
  ) {
    const listed = validatedProjects.find(
      project => project.identity.gameId === activeProjectGameId
    );
    appendManagedProjectListDiagnostic(
      validatedDiagnostics,
      createManagedProjectListDiagnostic(
        listed
          ? 'gdevelop_current_evidence_unavailable'
          : 'gdevelop_metadata_invalid',
        activeProjectGameId,
        activeProjectGameId
      )
    );
    validatedActiveGameId = null;
  }
  return {
    requestId: responseRequestId,
    activeGameId: validatedActiveGameId,
    projects: validatedProjects,
    diagnostics: validatedDiagnostics,
  };
};

export const listPlaymeshProjects = async ({
  signal,
} /*: {| signal?: ?AbortSignal |} */ = {}) /*: Promise<PlaymeshManagedProjectListResponse> */ =>
  validateManagedProjectListResponse(
    await requestJson('/dev/api/gdevelop/projects', { signal })
  );

export const createPlaymeshProject = async (
  {
    projectRef,
    origin,
    fileIdentifier,
    name,
    signal,
  } /*: PlaymeshProjectCreateRequest */
) /*: Promise<PlaymeshProjectLifecycleResponse> */ => {
  const body /*: PlaymeshMutableJsonObject */ = {
    gameId: resolvePlaymeshProjectId(projectRef),
    origin,
  };
  if (fileIdentifier) body.fileIdentifier = fileIdentifier;
  if (name) body.name = name;
  const response = await requestJson(
    '/dev/api/gdevelop/projects',
    jsonOptions('POST', body, signal)
  );
  return validateProjectResponse(response, projectRef);
};

export const openPlaymeshProject = async (
  {
    projectRef,
    fileIdentifier,
    name,
    signal,
  } /*: PlaymeshProjectLifecycleRequest */
) /*: Promise<PlaymeshProjectLifecycleResponse> */ => {
  const body /*: PlaymeshMutableJsonObject */ = {};
  if (fileIdentifier) body.fileIdentifier = fileIdentifier;
  if (name) body.name = name;
  const response = await requestJson(
    `${projectUrl(projectRef)}/open`,
    jsonOptions('POST', body, signal)
  );
  return validateProjectResponse(response, projectRef);
};

export const updatePlaymeshProject = async (
  {
    projectRef,
    fileIdentifier,
    name,
    signal,
  } /*: PlaymeshProjectLifecycleRequest */
) /*: Promise<PlaymeshProjectLifecycleResponse> */ => {
  const body /*: PlaymeshMutableJsonObject */ = {};
  if (fileIdentifier) body.fileIdentifier = fileIdentifier;
  if (name) body.name = name;
  const response = await requestJson(
    projectUrl(projectRef),
    jsonOptions('PATCH', body, signal)
  );
  return validateProjectResponse(response, projectRef);
};

export const deletePlaymeshProject = async (
  {
    projectRef,
    signal,
  } /*: {|
  projectRef: PlaymeshProjectRef,
  signal?: ?AbortSignal,
|} */
) /*: Promise<PlaymeshProjectDeleteResponse> */ => {
  const response = await requestJson(projectUrl(projectRef), {
    method: 'DELETE',
    signal,
  });
  const responseObject = jsonObject(response);
  const projectDeleted = responseObject && responseObject.projectDeleted;
  const historyDeleted = responseObject && responseObject.historyDeleted;
  const cleanupPending = responseObject && responseObject.cleanupPending;
  if (
    !responseObject ||
    responseObject.gameId !== resolvePlaymeshProjectId(projectRef) ||
    projectDeleted !== true ||
    typeof historyDeleted !== 'boolean' ||
    typeof cleanupPending !== 'boolean'
  ) {
    throw new PlaymeshProjectLifecycleError(
      'invalid_response',
      '本地工程删除响应无效。'
    );
  }
  return {
    ...responseObject,
    gameId: resolvePlaymeshProjectId(projectRef),
    projectDeleted: true,
    historyDeleted,
    cleanupPending,
  };
};

// 仅非权威的辅助操作可以使用 soft 包装；工程保存不得吞掉 Gateway 失败。
export async function runPlaymeshProjectLifecycleSoft /*::<Result>*/(
  {
    projectRef,
    action,
  } /*: {|
  projectRef: PlaymeshProjectRef,
  action: () => Promise<Result>,
|} */
) /*: Promise<PlaymeshProjectLifecycleSoftResult<Result>> */ {
  try {
    dispatchStatus(projectRef, 'syncing');
    const result = await action();
    dispatchStatus(projectRef, 'synced');
    return { ok: true, result };
  } catch (error) {
    const lifecycleError =
      error instanceof PlaymeshProjectLifecycleError
        ? error
        : new PlaymeshProjectLifecycleError(
            'project_lifecycle_unavailable',
            error instanceof Error
              ? error.message
              : '当前无法连接 Playmesh 本地工程服务。',
            error
          );
    dispatchStatus(projectRef, 'error', {
      code: lifecycleError.code,
      message: lifecycleError.message,
      details: lifecycleError.details,
    });
    return { ok: false, error: lifecycleError };
  }
}
