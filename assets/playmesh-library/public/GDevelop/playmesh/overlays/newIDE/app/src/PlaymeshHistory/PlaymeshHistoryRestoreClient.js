// @flow

import {
  PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES,
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreEnvelope,
  assertPlaymeshHistoryRestoreRecoveryEnvelope,
  buildPlaymeshHistoryRestoreBaseUrl,
  buildPlaymeshHistoryRestoreTransactionUrl,
  createPlaymeshHistoryRestorePrepareBody,
} from './PlaymeshHistoryRestoreProtocol';
import type {
  PlaymeshHistoryRestoreBrowserEvidence,
  PlaymeshHistoryRestoreEnvelope,
  PlaymeshHistoryRestoreRecoveryEnvelope,
} from './PlaymeshHistoryRestoreProtocol';

/*::
type RestoreRequestOptions = {
  method?: string,
  headers?: { [string]: string },
  body?: string,
  signal?: AbortSignal,
  credentials?: string,
  cache?: string,
};
type Fetch = (RequestInfo, ?RestoreRequestOptions) => Promise<Response>;
type PlaymeshHistoryRestorePrepareInput = {|
  gameId: string,
  idempotencyKey: string,
  baseRevision: number,
  targetRevision: number,
  source: 'user' | 'system',
  currentProjectFiles: mixed,
  currentResources: mixed,
  clientId?: string,
  signal?: AbortSignal,
|};
type PlaymeshHistoryRestoreTransactionInput = {|
  gameId: string,
  txId: string,
  signal?: AbortSignal,
|};
export type PlaymeshHistoryRestoreClient = {|
  prepare: (
    PlaymeshHistoryRestorePrepareInput
  ) => Promise<PlaymeshHistoryRestoreEnvelope>,
  commit: (
    PlaymeshHistoryRestoreTransactionInput
  ) => Promise<PlaymeshHistoryRestoreEnvelope>,
  status: (
    PlaymeshHistoryRestoreTransactionInput
  ) => Promise<PlaymeshHistoryRestoreEnvelope>,
  acknowledge: ({|
    ...PlaymeshHistoryRestoreTransactionInput,
    browserEvidence: PlaymeshHistoryRestoreBrowserEvidence,
  |}) => Promise<PlaymeshHistoryRestoreEnvelope>,
  recover: ({|
    gameId: string,
    signal?: AbortSignal,
  |}) => Promise<PlaymeshHistoryRestoreRecoveryEnvelope>,
  abort: (
    PlaymeshHistoryRestoreTransactionInput
  ) => Promise<PlaymeshHistoryRestoreEnvelope>,
|};
type MixedRecord = { +[string]: mixed };
type MergedAbortSignals = {|
  signal: AbortSignal,
  didTimeout: () => boolean,
  cleanup: () => void,
|};
*/

const DEFAULT_TIMEOUT_MS = 30000;

export class PlaymeshHistoryRestoreRequestError extends Error {
  /*::
  code: string;
  status: number;
  details: mixed;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    status /*: number */,
    details /*: mixed */ = null
  ) {
    super(message);
    this.name = 'PlaymeshHistoryRestoreRequestError';
    this.code = code;
    this.status = status;
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
      throw new PlaymeshHistoryRestoreRequestError(
        'invalid_response',
        'Playmesh 历史恢复响应无效。',
        response.status
      );
    }
    const contentLength = Number(rawLength);
    if (
      !Number.isSafeInteger(contentLength) ||
      contentLength > PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES
    ) {
      throw new PlaymeshHistoryRestoreRequestError(
        'response_too_large',
        'Playmesh 历史恢复响应过大。',
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
        throw new PlaymeshHistoryRestoreRequestError(
          'invalid_response',
          'Playmesh 历史恢复响应无效。',
          response.status
        );
      }
      total += chunk.byteLength;
      if (total > PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES) {
        try {
          await reader.cancel('response_too_large');
        } catch (_) {}
        throw new PlaymeshHistoryRestoreRequestError(
          'response_too_large',
          'Playmesh 历史恢复响应过大。',
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
    if (bytes.byteLength > PLAYMESH_HISTORY_RESTORE_MAX_JSON_BYTES) {
      throw new PlaymeshHistoryRestoreRequestError(
        'response_too_large',
        'Playmesh 历史恢复响应过大。',
        response.status
      );
    }
  }
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch (_) {
    throw new PlaymeshHistoryRestoreRequestError(
      'invalid_response',
      'Playmesh 历史恢复响应不是有效 JSON。',
      response.status
    );
  }
};

const requestError = (
  status /*: number */,
  payload /*: mixed */
) /*: PlaymeshHistoryRestoreRequestError */ => {
  const envelope = asRecord(payload);
  const error = asRecord(envelope && envelope.error);
  const code = error && error.code;
  const message = error && error.message;
  return new PlaymeshHistoryRestoreRequestError(
    typeof code === 'string' && code
      ? code
      : status === 404
      ? 'gdevelop_restore_transaction_not_found'
      : status === 409
      ? 'gdevelop_restore_transaction_unavailable'
      : 'history_restore_request_failed',
    typeof message === 'string' && message
      ? message
      : `Playmesh 历史恢复请求失败（HTTP ${status}）。`,
    status,
    payload
  );
};

const mergeAbortSignals = (
  externalSignal /*: ?AbortSignal */,
  timeoutMs /*: number */
) /*: MergedAbortSignals */ => {
  const controller = new AbortController();
  let timedOut = false;
  const timeoutId = window.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  const onAbort = () => controller.abort();
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort();
    else externalSignal.addEventListener('abort', onAbort, { once: true });
  }
  return {
    signal: controller.signal,
    didTimeout: () => timedOut,
    cleanup: () => {
      window.clearTimeout(timeoutId);
      if (externalSignal) {
        externalSignal.removeEventListener('abort', onAbort);
      }
    },
  };
};

export const createPlaymeshHistoryRestoreClient = ({
  fetchImpl = window.fetch.bind(window),
  timeoutMs = DEFAULT_TIMEOUT_MS,
} /*: {|
  fetchImpl?: Fetch,
  timeoutMs?: number,
|} */ = {}) /*: PlaymeshHistoryRestoreClient */ => {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
    throw new PlaymeshHistoryRestoreRequestError(
      'invalid_timeout',
      'Playmesh 历史恢复超时配置无效。',
      0
    );
  }

  const send = async (
    url /*: string */,
    options /*: RestoreRequestOptions */,
    externalSignal /*: ?AbortSignal */
  ) /*: Promise<{| response: Response, payload: mixed |}> */ => {
    const merged = mergeAbortSignals(externalSignal, timeoutMs);
    try {
      const response = await fetchImpl(url, {
        ...options,
        signal: merged.signal,
        credentials: 'same-origin',
        cache: 'no-store',
      });
      return { response, payload: await readBoundedJson(response) };
    } catch (error) {
      if (error instanceof PlaymeshHistoryRestoreRequestError) throw error;
      if (externalSignal && externalSignal.aborted) {
        throw new PlaymeshHistoryRestoreRequestError(
          'cancelled',
          'Playmesh 历史恢复已取消。',
          0
        );
      }
      if (merged.didTimeout()) {
        throw new PlaymeshHistoryRestoreRequestError(
          'history_restore_timeout',
          'Playmesh 历史恢复请求超时。',
          0
        );
      }
      throw new PlaymeshHistoryRestoreRequestError(
        'history_restore_unavailable',
        '当前无法连接 Playmesh 本地历史恢复服务。',
        0
      );
    } finally {
      merged.cleanup();
    }
  };

  const sendTransaction = async (
    gameId /*: string */,
    url /*: string */,
    options /*: RestoreRequestOptions */,
    signal /*: ?AbortSignal */,
    allowedConflictEnvelope /*: boolean */ = false
  ) /*: Promise<PlaymeshHistoryRestoreEnvelope> */ => {
    const { response, payload } = await send(url, options, signal);
    if (!response.ok && !(allowedConflictEnvelope && response.status === 409)) {
      throw requestError(response.status, payload);
    }
    try {
      return assertPlaymeshHistoryRestoreEnvelope(payload, gameId);
    } catch (error) {
      if (!response.ok) throw requestError(response.status, payload);
      throw error;
    }
  };

  const emptyPost /*: RestoreRequestOptions */ = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{}',
  };

  return {
    prepare: async input => {
      const body = createPlaymeshHistoryRestorePrepareBody({
        idempotencyKey: input.idempotencyKey,
        baseRevision: input.baseRevision,
        targetRevision: input.targetRevision,
        source: input.source,
        currentProjectFiles: input.currentProjectFiles,
        currentResources: input.currentResources,
        clientId: input.clientId,
      });
      return sendTransaction(
        input.gameId,
        buildPlaymeshHistoryRestoreBaseUrl(input.gameId),
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        },
        input.signal
      );
    },
    commit: input =>
      sendTransaction(
        input.gameId,
        `${buildPlaymeshHistoryRestoreTransactionUrl(
          input.gameId,
          input.txId
        )}/commit`,
        emptyPost,
        input.signal,
        true
      ),
    status: input =>
      sendTransaction(
        input.gameId,
        buildPlaymeshHistoryRestoreTransactionUrl(input.gameId, input.txId),
        { method: 'GET' },
        input.signal
      ),
    acknowledge: input => {
      const browserEvidence = assertPlaymeshHistoryRestoreBrowserEvidence(
        input.browserEvidence
      );
      return sendTransaction(
        input.gameId,
        `${buildPlaymeshHistoryRestoreTransactionUrl(
          input.gameId,
          input.txId
        )}/ack`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(browserEvidence),
        },
        input.signal,
        true
      );
    },
    recover: async input => {
      const { response, payload } = await send(
        `${buildPlaymeshHistoryRestoreBaseUrl(input.gameId)}/recover`,
        emptyPost,
        input.signal
      );
      if (!response.ok) throw requestError(response.status, payload);
      return assertPlaymeshHistoryRestoreRecoveryEnvelope(
        payload,
        input.gameId
      );
    },
    abort: input =>
      sendTransaction(
        input.gameId,
        `${buildPlaymeshHistoryRestoreTransactionUrl(
          input.gameId,
          input.txId
        )}/abort`,
        emptyPost,
        input.signal
      ),
  };
};

export const playmeshHistoryRestoreClient /*: PlaymeshHistoryRestoreClient */ = createPlaymeshHistoryRestoreClient();

// Called only after project open observed the durable mutation lock. PREPARED
// is the sole pre-decision phase and can be rolled back; later phases must be
// recovered forward by the restore coordinator.
export const abortPreparedPlaymeshHistoryRestore = async ({
  gameId,
  signal,
  client = playmeshHistoryRestoreClient,
} /*: {|
  gameId: string,
  signal?: AbortSignal,
  client?: PlaymeshHistoryRestoreClient,
|} */) /*: Promise<boolean> */ => {
  const recovery = await client.recover({
    gameId,
    signal,
  });
  const transaction = recovery.transaction;
  if (!transaction) return true;
  if (transaction.phase !== 'PREPARED') return false;
  const aborted = await client.abort({
    gameId,
    txId: transaction.txId,
    signal,
  });
  if (aborted.transaction.phase !== 'ABORTED') {
    throw new PlaymeshHistoryRestoreRequestError(
      'history_restore_abort_incomplete',
      'Playmesh 历史恢复 PREPARED 事务未能安全回滚。',
      0,
      aborted
    );
  }
  return true;
};
