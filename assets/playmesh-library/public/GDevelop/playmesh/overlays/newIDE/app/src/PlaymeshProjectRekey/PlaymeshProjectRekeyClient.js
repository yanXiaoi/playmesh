// @flow

import {
  PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES,
  assertPlaymeshProjectRekeyBrowserEvidence,
  assertPlaymeshProjectRekeyEnvelope,
  assertPlaymeshProjectRekeyRecoveryEnvelope,
  buildPlaymeshProjectRekeyBaseUrl,
  buildPlaymeshProjectRekeyTransactionUrl,
  createPlaymeshProjectRekeyPrepareBodyForGame,
} from './PlaymeshProjectRekeyProtocol';
import type {
  PlaymeshProjectRekeyBrowserEvidence,
  PlaymeshProjectRekeyEnvelope,
  PlaymeshProjectRekeyExpectedEvidence,
  PlaymeshProjectRekeyBrowserTarget,
  PlaymeshProjectRekeyRecoveryEnvelope,
} from './PlaymeshProjectRekeyProtocol';

/*::
type RekeyRequestOptions = {|
  method: 'GET' | 'POST',
  headers?: { [string]: string },
  body?: string,
  signal: AbortSignal,
  credentials: 'same-origin',
  cache: 'no-store',
  redirect: 'error',
|};
type RekeyFetch = (string, RekeyRequestOptions) => Promise<Response>;
export type PlaymeshProjectRekeyPrepareInput = {|
  oldGameId: string,
  newGameId: string,
  idempotencyKey: string,
  expectedOldEvidence: PlaymeshProjectRekeyExpectedEvidence,
  browserSource: PlaymeshProjectRekeyBrowserTarget,
  browserTarget: PlaymeshProjectRekeyBrowserTarget,
  clientId?: string,
  signal?: ?AbortSignal,
|};
type PlaymeshProjectRekeyTransactionInput = {|
  oldGameId: string,
  txId: string,
  signal?: ?AbortSignal,
|};
export type PlaymeshProjectRekeyClient = {|
  prepare: PlaymeshProjectRekeyPrepareInput => Promise<PlaymeshProjectRekeyEnvelope>,
  commit: PlaymeshProjectRekeyTransactionInput => Promise<PlaymeshProjectRekeyEnvelope>,
  status: PlaymeshProjectRekeyTransactionInput => Promise<PlaymeshProjectRekeyEnvelope>,
  acknowledge: ({|
    ...PlaymeshProjectRekeyTransactionInput,
    browserEvidence: PlaymeshProjectRekeyBrowserEvidence,
  |}) => Promise<PlaymeshProjectRekeyEnvelope>,
  rollback: ({|
    ...PlaymeshProjectRekeyTransactionInput,
    browserEvidence?: PlaymeshProjectRekeyBrowserEvidence,
  |}) => Promise<PlaymeshProjectRekeyEnvelope>,
  recover: ({| oldGameId: string, signal?: ?AbortSignal |}) => Promise<PlaymeshProjectRekeyRecoveryEnvelope>,
  abort: PlaymeshProjectRekeyTransactionInput => Promise<PlaymeshProjectRekeyEnvelope>,
|};
type MixedRecord = { +[string]: mixed };
*/

const DEFAULT_TIMEOUT_MS = 30000;

export class PlaymeshProjectRekeyRequestError extends Error {
  /*::
  code: string;
  status: number;
  requestId: ?string;
  details: mixed;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    status /*: number */,
    requestId /*: ?string */ = null,
    details /*: mixed */ = null
  ) {
    super(message);
    this.name = 'PlaymeshProjectRekeyRequestError';
    this.code = code;
    this.status = status;
    this.requestId = requestId;
    this.details = details;
  }
}

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const readBoundedJson = async (
  response /*: Response */
) /*: Promise<mixed> */ => {
  const rawLength = response.headers.get('Content-Length');
  if (rawLength !== null) {
    if (!/^\d+$/.test(rawLength)) {
      throw new PlaymeshProjectRekeyRequestError(
        'invalid_response',
        'Playmesh 项目身份迁移响应无效。',
        response.status
      );
    }
    const contentLength = Number(rawLength);
    if (
      !Number.isSafeInteger(contentLength) ||
      contentLength > PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES
    ) {
      throw new PlaymeshProjectRekeyRequestError(
        'response_too_large',
        'Playmesh 项目身份迁移响应过大。',
        response.status
      );
    }
  }
  let bytes /*: Uint8Array */;
  if (response.body) {
    const reader = response.body.getReader();
    const chunks /*: Array<Uint8Array> */ = [];
    let total = 0;
    for (;;) {
      const result = await reader.read();
      if (result.done) break;
      const chunk = result.value;
      if (!(chunk instanceof Uint8Array)) {
        throw new PlaymeshProjectRekeyRequestError(
          'invalid_response',
          'Playmesh 项目身份迁移响应无效。',
          response.status
        );
      }
      total += chunk.byteLength;
      if (total > PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES) {
        try {
          await reader.cancel('response_too_large');
        } catch (_) {}
        throw new PlaymeshProjectRekeyRequestError(
          'response_too_large',
          'Playmesh 项目身份迁移响应过大。',
          response.status
        );
      }
      chunks.push(chunk);
    }
    bytes = new Uint8Array(total);
    let offset = 0;
    chunks.forEach(chunk => {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    });
  } else {
    bytes = new TextEncoder().encode(await response.text());
    if (bytes.byteLength > PLAYMESH_PROJECT_REKEY_MAX_JSON_BYTES) {
      throw new PlaymeshProjectRekeyRequestError(
        'response_too_large',
        'Playmesh 项目身份迁移响应过大。',
        response.status
      );
    }
  }
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (_) {
    throw new PlaymeshProjectRekeyRequestError(
      'invalid_response',
      'Playmesh 项目身份迁移响应不是有效 JSON。',
      response.status
    );
  }
};

const requestError = (
  status /*: number */,
  payload /*: mixed */
) /*: PlaymeshProjectRekeyRequestError */ => {
  const envelope = asRecord(payload);
  const error = envelope ? asRecord(envelope.error) : null;
  const rawRequestId = envelope ? envelope.requestId : null;
  const rawCode = error ? error.code : null;
  const rawMessage = error ? error.message : null;
  const exactEnvelope =
    !!envelope &&
    !!error &&
    Object.keys(envelope).length === 2 &&
    Object.hasOwn(envelope, 'requestId') &&
    Object.hasOwn(envelope, 'error') &&
    Object.keys(error).length === 2 &&
    Object.hasOwn(error, 'code') &&
    Object.hasOwn(error, 'message') &&
    typeof rawRequestId === 'string' &&
    !!rawRequestId &&
    typeof rawCode === 'string' &&
    !!rawCode &&
    typeof rawMessage === 'string' &&
    !!rawMessage;
  return new PlaymeshProjectRekeyRequestError(
    exactEnvelope && typeof rawCode === 'string'
      ? rawCode
      : status === 404
      ? 'gdevelop_rekey_transaction_not_found'
      : status === 409
      ? 'gdevelop_rekey_transaction_unavailable'
      : 'gdevelop_rekey_request_failed',
    exactEnvelope && typeof rawMessage === 'string'
      ? rawMessage
      : `Playmesh 项目身份迁移请求失败（HTTP ${status}）。`,
    status,
    exactEnvelope && typeof rawRequestId === 'string' ? rawRequestId : null,
    payload
  );
};

export const createPlaymeshProjectRekeyClient = ({
  fetchImpl = window.fetch.bind(window),
  timeoutMs = DEFAULT_TIMEOUT_MS,
} /*: {|
  fetchImpl?: RekeyFetch,
  timeoutMs?: number,
|} */ = {}) /*: PlaymeshProjectRekeyClient */ => {
  if (typeof fetchImpl !== 'function') {
    throw new PlaymeshProjectRekeyRequestError(
      'fetch_unavailable',
      'Playmesh 项目身份迁移请求能力不可用。',
      0
    );
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
    throw new PlaymeshProjectRekeyRequestError(
      'invalid_timeout',
      'Playmesh 项目身份迁移超时配置无效。',
      0
    );
  }

  const send = async (
    url /*: string */,
    request /*: $ReadOnly<{| method: 'GET' | 'POST', body?: string |}> */,
    externalSignal /*: ?AbortSignal */
  ) /*: Promise<{| response: Response, payload: mixed |}> */ => {
    const controller = new AbortController();
    let timedOut = false;
    const onAbort = () => controller.abort();
    if (externalSignal) {
      if (externalSignal.aborted) controller.abort();
      else externalSignal.addEventListener('abort', onAbort, { once: true });
    }
    const timeoutId = window.setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeoutMs);
    try {
      const response = await fetchImpl(url, {
        method: request.method,
        ...(request.body === undefined
          ? { headers: { Accept: 'application/json' } }
          : {
              headers: {
                Accept: 'application/json',
                'Content-Type': 'application/json',
              },
              body: request.body,
            }),
        signal: controller.signal,
        credentials: 'same-origin',
        cache: 'no-store',
        redirect: 'error',
      });
      return { response, payload: await readBoundedJson(response) };
    } catch (error) {
      if (error instanceof PlaymeshProjectRekeyRequestError) throw error;
      if (externalSignal && externalSignal.aborted) {
        throw new PlaymeshProjectRekeyRequestError(
          'cancelled',
          'Playmesh 项目身份迁移已取消。',
          0
        );
      }
      if (timedOut) {
        throw new PlaymeshProjectRekeyRequestError(
          'gdevelop_rekey_timeout',
          'Playmesh 项目身份迁移请求超时。',
          0
        );
      }
      throw new PlaymeshProjectRekeyRequestError(
        'gdevelop_rekey_unavailable',
        '当前无法连接 Playmesh 本地项目身份迁移服务。',
        0,
        null,
        error
      );
    } finally {
      window.clearTimeout(timeoutId);
      if (externalSignal) {
        externalSignal.removeEventListener('abort', onAbort);
      }
    }
  };

  const sendTransaction = async (
    oldGameId /*: string */,
    url /*: string */,
    request /*: $ReadOnly<{| method: 'GET' | 'POST', body?: string |}> */,
    signal /*: ?AbortSignal */,
    allowConflictEnvelope /*: boolean */ = false
  ) /*: Promise<PlaymeshProjectRekeyEnvelope> */ => {
    const { response, payload } = await send(url, request, signal);
    if (!response.ok && !(allowConflictEnvelope && response.status === 409)) {
      throw requestError(response.status, payload);
    }
    try {
      return assertPlaymeshProjectRekeyEnvelope(payload, oldGameId);
    } catch (error) {
      if (!response.ok) throw requestError(response.status, payload);
      throw error;
    }
  };

  const emptyPost /*: $ReadOnly<{| method: 'POST', body: string |}> */ = {
    method: 'POST',
    body: '{}',
  };
  return {
    prepare: input => {
      const body = createPlaymeshProjectRekeyPrepareBodyForGame(
        {
          idempotencyKey: input.idempotencyKey,
          newGameId: input.newGameId,
          expectedOldEvidence: input.expectedOldEvidence,
          browserSource: input.browserSource,
          browserTarget: input.browserTarget,
          ...(input.clientId === undefined ? {} : { clientId: input.clientId }),
        },
        input.oldGameId
      );
      return sendTransaction(
        input.oldGameId,
        buildPlaymeshProjectRekeyBaseUrl(input.oldGameId),
        { method: 'POST', body: JSON.stringify(body) },
        input.signal
      );
    },
    commit: input =>
      sendTransaction(
        input.oldGameId,
        `${buildPlaymeshProjectRekeyTransactionUrl(
          input.oldGameId,
          input.txId
        )}/commit`,
        emptyPost,
        input.signal,
        true
      ),
    status: input =>
      sendTransaction(
        input.oldGameId,
        buildPlaymeshProjectRekeyTransactionUrl(input.oldGameId, input.txId),
        { method: 'GET' },
        input.signal
      ),
    acknowledge: input => {
      const evidence = assertPlaymeshProjectRekeyBrowserEvidence(
        input.browserEvidence,
        input.browserEvidence.fileMetadata.gameId
      );
      return sendTransaction(
        input.oldGameId,
        `${buildPlaymeshProjectRekeyTransactionUrl(
          input.oldGameId,
          input.txId
        )}/ack`,
        { method: 'POST', body: JSON.stringify(evidence) },
        input.signal,
        true
      );
    },
    rollback: input => {
      const body =
        input.browserEvidence === undefined
          ? {}
          : assertPlaymeshProjectRekeyBrowserEvidence(
              input.browserEvidence,
              input.oldGameId
            );
      return sendTransaction(
        input.oldGameId,
        `${buildPlaymeshProjectRekeyTransactionUrl(
          input.oldGameId,
          input.txId
        )}/rollback`,
        { method: 'POST', body: JSON.stringify(body) },
        input.signal,
        true
      );
    },
    recover: async input => {
      const { response, payload } = await send(
        `${buildPlaymeshProjectRekeyBaseUrl(input.oldGameId)}/recover`,
        emptyPost,
        input.signal
      );
      if (!response.ok) throw requestError(response.status, payload);
      return assertPlaymeshProjectRekeyRecoveryEnvelope(
        payload,
        input.oldGameId
      );
    },
    abort: input =>
      sendTransaction(
        input.oldGameId,
        `${buildPlaymeshProjectRekeyTransactionUrl(
          input.oldGameId,
          input.txId
        )}/abort`,
        emptyPost,
        input.signal
      ),
  };
};

export const playmeshProjectRekeyClient /*: PlaymeshProjectRekeyClient */ = createPlaymeshProjectRekeyClient();
