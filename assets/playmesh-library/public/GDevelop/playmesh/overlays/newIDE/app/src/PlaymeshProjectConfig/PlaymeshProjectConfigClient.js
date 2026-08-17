// @flow

import {
  PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES,
  PlaymeshProjectConfigProtocolError,
  assertPlaymeshProjectConfigReadResponse,
  buildPlaymeshProjectConfigUrl,
  createPlaymeshProjectConfigPutBody,
  parsePlaymeshProjectConfigErrorEnvelope,
  readPlaymeshProjectConfigJson,
} from './PlaymeshProjectConfigProtocol';

/*::
import type {
  PlaymeshProjectConfigReadResponse,
  PlaymeshProjectGameType,
} from './PlaymeshProjectConfigProtocol';

type PlaymeshProjectConfigFetchOptions = {|
  method: 'GET' | 'PUT',
  headers: { [string]: string },
  body?: string,
  signal: AbortSignal,
  credentials: 'same-origin',
  cache: 'no-store',
  redirect: 'error',
|};
type PlaymeshProjectConfigFetch = (
  url: string,
  options: PlaymeshProjectConfigFetchOptions
) => Promise<Response>;
type PlaymeshProjectConfigClientOptions = {|
  fetchImplementation?: PlaymeshProjectConfigFetch,
  timeoutMs?: number,
|};
type PlaymeshProjectConfigReadOptions = {|
  gameId: string,
  signal?: ?AbortSignal,
|};
type PlaymeshProjectConfigPutOptions = {|
  gameId: string,
  gameType: PlaymeshProjectGameType,
  minPlayers: number,
  maxPlayers: number,
  tags: Array<string>,
  expectedRevision: number,
  signal?: ?AbortSignal,
|};
type PlaymeshProjectConfigClientErrorOptions = {|
  code: string,
  message?: string,
  status?: number,
  requestId?: ?string,
  details?: mixed,
|};
*/

const DEFAULT_TIMEOUT_MS = 30000;

const responseHeader = (
  response /*: Response */,
  name /*: string */
) /*: ?string */ => {
  try {
    const value = response.headers.get(name);
    return value && value.trim() ? value.trim() : null;
  } catch (_) {
    return null;
  }
};

export class PlaymeshProjectConfigClientError extends Error {
  /*::
  code: string;
  status: number;
  requestId: ?string;
  details: mixed;
  */

  constructor(
    {
      code,
      message = 'Playmesh 项目配置服务当前不可用。',
      status = 0,
      requestId = null,
      details = null,
    } /*: PlaymeshProjectConfigClientErrorOptions */
  ) {
    super(message);
    this.name = 'PlaymeshProjectConfigClientError';
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.details = details;
  }
}

export class PlaymeshProjectConfigConflictError extends PlaymeshProjectConfigClientError {
  /*:: currentRevision: number; */

  constructor(
    {
      currentRevision,
      message = 'Playmesh 项目配置已在其他位置修改。',
      requestId = null,
    } /*: {|
    currentRevision: number,
    message?: string,
    requestId?: ?string,
  |} */
  ) {
    super({
      code: 'gdevelop_config_revision_conflict',
      message,
      status: 409,
      requestId,
    });
    this.name = 'PlaymeshProjectConfigConflictError';
    this.currentRevision = currentRevision;
  }
}

const asClientError = (
  error /*: mixed */,
  status /*: number */ = 0
) /*: PlaymeshProjectConfigClientError */ => {
  if (error instanceof PlaymeshProjectConfigClientError) return error;
  const code =
    error &&
    typeof error === 'object' &&
    typeof Reflect.get(error, 'code') === 'string'
      ? String(Reflect.get(error, 'code'))
      : 'invalid_response';
  const message =
    error instanceof Error ? error.message : 'Playmesh 项目配置响应无效。';
  return new PlaymeshProjectConfigClientError({
    code,
    message,
    status,
    details: error,
  });
};

export class PlaymeshProjectConfigClient {
  /*::
  _fetch: PlaymeshProjectConfigFetch;
  _timeoutMs: number;
  */

  constructor({
    fetchImplementation = global.fetch,
    timeoutMs = DEFAULT_TIMEOUT_MS,
  } /*: PlaymeshProjectConfigClientOptions */ = {}) {
    if (typeof fetchImplementation !== 'function') {
      throw new PlaymeshProjectConfigClientError({
        code: 'fetch_unavailable',
      });
    }
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
      throw new PlaymeshProjectConfigClientError({
        code: 'invalid_timeout',
      });
    }
    this._fetch = fetchImplementation;
    this._timeoutMs = timeoutMs;
  }

  async _request(
    {
      gameId,
      method,
      body,
      signal,
    } /*: {|
    gameId: string,
    method: 'GET' | 'PUT',
    body?: string,
    signal?: ?AbortSignal,
  |} */
  ) /*: Promise<PlaymeshProjectConfigReadResponse> */ {
    const url = buildPlaymeshProjectConfigUrl(gameId);
    const controller = new AbortController();
    const abortFromExternal = () => controller.abort();
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener('abort', abortFromExternal, { once: true });
    }
    const timeoutId = global.setTimeout(
      () => controller.abort(),
      this._timeoutMs
    );
    try {
      const headers = {
        Accept: 'application/json',
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      };
      const response = await this._fetch(url, {
        method,
        headers,
        ...(body === undefined ? {} : { body }),
        signal: controller.signal,
        credentials: 'same-origin',
        cache: 'no-store',
        redirect: 'error',
      });
      const responseRequestId = responseHeader(response, 'X-Request-ID');
      let value;
      try {
        value = await readPlaymeshProjectConfigJson(response);
      } catch (error) {
        const clientError = asClientError(error, response.status);
        throw new PlaymeshProjectConfigClientError({
          code: clientError.code,
          message: clientError.message,
          status: response.status,
          requestId: responseRequestId,
          details: clientError.details,
        });
      }
      if (!response.ok) {
        let parsed;
        try {
          parsed = parsePlaymeshProjectConfigErrorEnvelope(value);
        } catch (error) {
          const clientError = asClientError(error, response.status);
          throw new PlaymeshProjectConfigClientError({
            code: clientError.code,
            message: clientError.message,
            status: response.status,
            requestId: responseRequestId,
            details: clientError.details,
          });
        }
        if (
          response.status === 409 &&
          parsed.code === 'gdevelop_config_revision_conflict' &&
          parsed.currentRevision !== undefined
        ) {
          throw new PlaymeshProjectConfigConflictError({
            currentRevision: parsed.currentRevision,
            message: parsed.message,
            requestId: parsed.requestId,
          });
        }
        throw new PlaymeshProjectConfigClientError({
          code: parsed.code,
          message: parsed.message,
          status: response.status,
          requestId: parsed.requestId,
          details: value,
        });
      }
      try {
        return assertPlaymeshProjectConfigReadResponse(value, gameId);
      } catch (error) {
        const clientError = asClientError(error, response.status);
        throw new PlaymeshProjectConfigClientError({
          code: clientError.code,
          message: clientError.message,
          status: response.status,
          requestId: responseRequestId,
          details: clientError.details,
        });
      }
    } catch (error) {
      if (
        error instanceof PlaymeshProjectConfigClientError ||
        error instanceof PlaymeshProjectConfigConflictError
      ) {
        throw error;
      }
      if (signal && signal.aborted) {
        throw new PlaymeshProjectConfigClientError({
          code: 'cancelled',
          message: 'Playmesh 项目配置请求已取消。',
        });
      }
      if (controller.signal.aborted) {
        throw new PlaymeshProjectConfigClientError({
          code: 'request_timeout',
          message: 'Playmesh 项目配置请求超时。',
        });
      }
      if (error instanceof PlaymeshProjectConfigProtocolError) {
        throw asClientError(error);
      }
      throw new PlaymeshProjectConfigClientError({
        code: 'config_unavailable',
        details: error,
      });
    } finally {
      global.clearTimeout(timeoutId);
      if (signal) signal.removeEventListener('abort', abortFromExternal);
    }
  }

  read(
    { gameId, signal } /*: PlaymeshProjectConfigReadOptions */
  ) /*: Promise<PlaymeshProjectConfigReadResponse> */ {
    return this._request({ gameId, method: 'GET', signal });
  }

  put(
    {
      gameId,
      gameType,
      minPlayers,
      maxPlayers,
      tags,
      expectedRevision,
      signal,
    } /*: PlaymeshProjectConfigPutOptions */
  ) /*: Promise<PlaymeshProjectConfigReadResponse> */ {
    const body = createPlaymeshProjectConfigPutBody({
      gameType,
      minPlayers,
      maxPlayers,
      tags,
      expectedRevision,
    });
    return this._request({
      gameId,
      method: 'PUT',
      body: JSON.stringify(body),
      signal,
    });
  }
}

export { PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES };
