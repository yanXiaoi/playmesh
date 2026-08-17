// @flow

export const PLAYMESH_GDEVELOP_PREVIEW_PROTOCOL_VERSION = '1.0.0';

/*::
type PlaymeshMixedRecord = { +[string]: mixed };

export type PlaymeshPreviewRunStatus = {
  projectId: string,
  runId?: string,
  phase: string,
  joinCode?: ?string,
  links: Array<string>,
  message?: ?string,
  updatedAt: number,
};

export type PlaymeshPreviewResponse = {|
  protocolVersion: '1.0.0',
  previewId: string,
  gameId: string,
  expiresAt: number,
  run: PlaymeshPreviewRunStatus,
|};

type PlaymeshPreviewRunErrorDetails = {
  status?: number,
  +[string]: mixed,
};

type PlaymeshPreviewRequestOptions = {|
  url: string,
  method?: 'GET' | 'DELETE',
  signal?: ?AbortSignal,
  fetchImplementation?: typeof fetch,
  expectedGameId: string,
|};

type PlaymeshPreviewReadOptions = {|
  gameId: string,
  signal?: ?AbortSignal,
  fetchImplementation?: typeof fetch,
|};

type PlaymeshPreviewStopOptions = {|
  gameId: string,
  previewId: string,
  signal?: ?AbortSignal,
  fetchImplementation?: typeof fetch,
|};

type PlaymeshPreviewWaitOptions = {|
  initialResponse: PlaymeshPreviewResponse,
  signal?: ?AbortSignal,
  fetchImplementation?: typeof fetch,
  EventSourceConstructor?: ?typeof EventSource,
  currentLocation?: ?string,
  timeoutMs?: number,
  pollIntervalMs?: number,
  onStatus?: PlaymeshPreviewRunStatus => void,
  resolveWhenRunning?: boolean,
|};
*/

export class PlaymeshPreviewRunError extends Error {
  /*::
  code: string;
  status: ?number;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    details /*: PlaymeshPreviewRunErrorDetails */ = {}
  ) {
    super(message);
    this.name = 'PlaymeshPreviewRunError';
    this.code = code;
    this.status = undefined;
    Object.keys(details).forEach(key => {
      Reflect.set(this, key, details[key]);
    });
  }
}

const mixedRecord = (
  value /*: mixed */
) /*: ?PlaymeshMixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const previewBasePath = (gameId /*: string */) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(gameId)}/preview`;

export const buildPlaymeshPreviewUploadUrl = ({
  gameId,
} /*: {| gameId: string |} */) /*: string */ => previewBasePath(gameId);

const assertRunStatus = (
  run /*: mixed */,
  expectedGameId /*: string */
) /*: PlaymeshPreviewRunStatus */ => {
  const runRecord = mixedRecord(run);
  if (!runRecord) {
    throw new PlaymeshPreviewRunError(
      'invalid_preview_run',
      'Playmesh 返回了无效的 GDevelop 预览运行状态。'
    );
  }
  const projectId = runRecord.projectId;
  const phase = runRecord.phase;
  const updatedAt = runRecord.updatedAt;
  const rawLinks = runRecord.links;
  if (
    projectId !== expectedGameId ||
    typeof phase !== 'string' ||
    !phase ||
    (runRecord.runId !== undefined &&
      typeof runRecord.runId !== 'string') ||
    (runRecord.joinCode !== undefined &&
      runRecord.joinCode !== null &&
      typeof runRecord.joinCode !== 'string') ||
    !Array.isArray(rawLinks) ||
    (runRecord.message !== undefined &&
      runRecord.message !== null &&
      typeof runRecord.message !== 'string') ||
    typeof updatedAt !== 'number'
  ) {
    throw new PlaymeshPreviewRunError(
      'invalid_preview_run',
      'Playmesh 返回了无效的 GDevelop 预览运行状态。'
    );
  }
  const links /*: Array<string> */ = [];
  rawLinks.forEach(link => {
    if (typeof link !== 'string') {
      throw new PlaymeshPreviewRunError(
        'invalid_preview_run',
        'Playmesh 返回了无效的 GDevelop 预览运行状态。'
      );
    }
    links.push(link);
  });
  const validatedRun /*: PlaymeshPreviewRunStatus */ = {
    projectId: expectedGameId,
    phase,
    links,
    updatedAt,
  };
  if (typeof runRecord.runId === 'string') {
    validatedRun.runId = runRecord.runId;
  }
  if (
    runRecord.joinCode === null ||
    typeof runRecord.joinCode === 'string'
  ) {
    validatedRun.joinCode = runRecord.joinCode;
  }
  if (
    runRecord.message === null ||
    typeof runRecord.message === 'string'
  ) {
    validatedRun.message = runRecord.message;
  }
  return validatedRun;
};

export const assertPlaymeshPreviewResponse = (
  value /*: mixed */,
  expectedGameId /*: string */
) /*: PlaymeshPreviewResponse */ => {
  const response = mixedRecord(value);
  if (
    !response ||
    response.protocolVersion !== PLAYMESH_GDEVELOP_PREVIEW_PROTOCOL_VERSION ||
    typeof response.previewId !== 'string' ||
    !response.previewId ||
    response.gameId !== expectedGameId ||
    typeof response.expiresAt !== 'number' ||
    !Number.isFinite(response.expiresAt)
  ) {
    throw new PlaymeshPreviewRunError(
      'invalid_preview_response',
      'Playmesh 返回了无效的 GDevelop 预览响应。'
    );
  }
  return {
    protocolVersion: PLAYMESH_GDEVELOP_PREVIEW_PROTOCOL_VERSION,
    previewId: response.previewId,
    gameId: expectedGameId,
    expiresAt: response.expiresAt,
    run: assertRunStatus(response.run, expectedGameId),
  };
};

const responseJson = async (response /*: Response */) /*: Promise<mixed> */ => {
  try {
    return await response.json();
  } catch (_) {
    return null;
  }
};

const requestPreview = async ({
  url,
  method = 'GET',
  signal,
  fetchImplementation = global.fetch,
  expectedGameId,
} /*: PlaymeshPreviewRequestOptions */) /*: Promise<PlaymeshPreviewResponse> */ => {
  const response = await fetchImplementation(url, {
    method,
    credentials: 'same-origin',
    cache: 'no-store',
    signal,
  });
  const value /*: mixed */ = await responseJson(response);
  if (!response.ok) {
    const valueRecord = mixedRecord(value);
    const envelope = mixedRecord(valueRecord && valueRecord.error);
    const responseCode = envelope && envelope.code;
    const responseMessage = envelope && envelope.message;
    throw new PlaymeshPreviewRunError(
      typeof responseCode === 'string' && responseCode
        ? responseCode
        : 'preview_request_failed',
      typeof responseMessage === 'string' && responseMessage
        ? responseMessage
        : `Playmesh GDevelop 预览请求失败（HTTP ${response.status}）。`,
      { status: response.status }
    );
  }
  return assertPlaymeshPreviewResponse(value, expectedGameId);
};

export const getCurrentPlaymeshPreview = ({
  gameId,
  signal,
  fetchImplementation,
} /*: PlaymeshPreviewReadOptions */) /*: Promise<PlaymeshPreviewResponse> */ =>
  requestPreview({
    url: previewBasePath(gameId),
    signal,
    fetchImplementation,
    expectedGameId: gameId,
  });

export const stopPlaymeshPreview = ({
  gameId,
  previewId,
  signal,
  fetchImplementation,
} /*: PlaymeshPreviewStopOptions */) /*: Promise<PlaymeshPreviewResponse> */ =>
  requestPreview({
    url: `${previewBasePath(gameId)}/${encodeURIComponent(previewId)}`,
    method: 'DELETE',
    signal,
    fetchImplementation,
    expectedGameId: gameId,
  });

const isLoopbackHostname = (hostname /*: string */) /*: boolean */ => {
  const normalized = String(hostname || '').toLowerCase();
  return (
    normalized === 'localhost' ||
    normalized === '::1' ||
    normalized === '[::1]' ||
    normalized.startsWith('127.')
  );
};

export const selectPlaymeshPreviewLink = (
  links /*: ?$ReadOnlyArray<string> */,
  currentLocation /*: ?string */ = global.location && global.location.href
) /*: ?string */ => {
  const candidates /*: Array<URL> */ = [];
  (links || []).forEach(link => {
    try {
      const url = new URL(link);
      if (url.protocol === 'http:' || url.protocol === 'https:') {
        candidates.push(url);
      }
    } catch (_) {}
  });
  if (!candidates.length) return null;
  let current /*: ?URL */ = null;
  try {
    current = currentLocation ? new URL(currentLocation) : null;
  } catch (_) {}
  if (current && !isLoopbackHostname(current.hostname)) {
    const currentHostname = current.hostname;
    const sameHost = candidates.find(
      url => url.hostname === currentHostname
    );
    if (sameHost) return sameHost.href;
  }
  const lan = candidates.find(url => !isLoopbackHostname(url.hostname));
  return (lan || candidates[0]).href;
};

const runFailure = (
  run /*: PlaymeshPreviewRunStatus */
) /*: ?PlaymeshPreviewRunError */ => {
  if (run.phase !== 'error' && run.phase !== 'stopped') return null;
  return new PlaymeshPreviewRunError(
    `preview_run_${run.phase}`,
    run.message ||
      (run.phase === 'error'
        ? 'Playmesh 无法启动 GDevelop 预览。'
        : 'GDevelop 预览已停止。')
  );
};

const abortError = (signal /*: ?AbortSignal */) /*: Error */ => {
  const signalRecord = mixedRecord(signal);
  const reason = signalRecord && signalRecord.reason;
  return reason instanceof Error
    ? reason
    : new PlaymeshPreviewRunError('cancelled', '预览已取消。');
};

export const waitForPlaymeshPreviewLink /*: (
  options: PlaymeshPreviewWaitOptions
) => Promise<string> */ = ({
  initialResponse,
  signal,
  fetchImplementation = global.fetch,
  EventSourceConstructor = global.EventSource,
  currentLocation,
  timeoutMs = 60000,
  pollIntervalMs = 750,
  onStatus,
  resolveWhenRunning = false,
}) =>
  new Promise/*::<string>*/((resolve, reject) => {
    const gameId = initialResponse.gameId;
    const expectedRunId = initialResponse.run.runId;
    let settled = false;
    let pollTimer /*: ?TimeoutID */ = null;
    let timeoutTimer /*: ?TimeoutID */ = null;
    let eventSource /*: ?EventSource */ = null;

    const cleanup = () /*: void */ => {
      if (pollTimer !== null) global.clearTimeout(pollTimer);
      if (timeoutTimer !== null) global.clearTimeout(timeoutTimer);
      eventSource?.close?.();
      signal?.removeEventListener?.('abort', onAbort);
    };
    const finish = (
      error /*: ?Error */,
      link /*: ?string */ = null
    ) /*: void */ => {
      if (settled) return;
      settled = true;
      cleanup();
      if (error) reject(error);
      else if (link) resolve(link);
      else {
        reject(
          new PlaymeshPreviewRunError(
            'preview_link_missing',
            'Playmesh GDevelop 预览没有返回可用链接。'
          )
        );
      }
    };
    const acceptRun = (run /*: mixed */) /*: boolean */ => {
      const runRecord = mixedRecord(run);
      if (
        !runRecord ||
        runRecord.projectId !== gameId ||
        (expectedRunId &&
          typeof runRecord.runId === 'string' &&
          runRecord.runId !== expectedRunId)
      ) {
        return false;
      }
      let validRun /*: PlaymeshPreviewRunStatus */;
      try {
        validRun = assertRunStatus(run, gameId);
      } catch (error) {
        finish(error);
        return true;
      }
      if (onStatus) onStatus(validRun);
      const failure = runFailure(validRun);
      if (failure) {
        finish(failure);
        return true;
      }
      if (validRun.phase === 'running') {
        if (resolveWhenRunning) {
          // The App already pushed its existing DeveloperRun GamePage. No
          // browser URL is needed when GDevelop is hosted inside the App.
          finish(null, 'playmesh-app-runtime-ready');
          return true;
        }
        const link = selectPlaymeshPreviewLink(
          validRun.links,
          currentLocation
        );
        if (link) {
          finish(null, link);
          return true;
        }
      }
      return false;
    };
    const poll = async () /*: Promise<void> */ => {
      try {
        const response = await getCurrentPlaymeshPreview({
          gameId,
          signal,
          fetchImplementation,
        });
        if (response.previewId !== initialResponse.previewId) {
          finish(
            new PlaymeshPreviewRunError(
              'preview_generation_replaced',
              'GDevelop 预览已被更新的运行替换。'
            )
          );
          return;
        }
        if (acceptRun(response.run)) return;
      } catch (error) {
        if (signal?.aborted) {
          finish(abortError(signal));
          return;
        }
        // SSE is authoritative while connected; GET is only a disconnect/race
        // fallback, so a transient poll failure must not end the preview.
      }
      if (!settled) pollTimer = global.setTimeout(poll, pollIntervalMs);
    };
    const onAbort = () /*: void */ => finish(abortError(signal));

    if (acceptRun(initialResponse.run)) return;
    if (signal?.aborted) {
      onAbort();
      return;
    }
    signal?.addEventListener?.('abort', onAbort, { once: true });
    timeoutTimer = global.setTimeout(
      () =>
        finish(
          new PlaymeshPreviewRunError(
            'preview_start_timeout',
            '等待 Playmesh GDevelop 预览启动超时。'
          )
        ),
      timeoutMs
    );
    if (EventSourceConstructor) {
      eventSource = new EventSourceConstructor('/dev/api/events', {
        withCredentials: true,
      });
      eventSource.addEventListener('run.status', (event /*: MessageEvent */) => {
        try {
          const eventData = event.data;
          if (typeof eventData !== 'string') {
            throw new PlaymeshPreviewRunError(
              'invalid_preview_event',
              'Playmesh 返回了无效的 GDevelop 预览事件。'
            );
          }
          acceptRun(JSON.parse(eventData));
        } catch (error) {
          finish(error);
        }
      });
    }
    void poll();
  });

export const waitForPlaymeshPreviewAppRuntime /*: (
  options: PlaymeshPreviewWaitOptions
) => Promise<void> */ = options =>
  waitForPlaymeshPreviewLink({
    ...options,
    resolveWhenRunning: true,
  }).then(() => {});
