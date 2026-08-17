// @flow

import { initializeZipJs } from '../Utils/Zip.js';

/*::
import type {
  PlaymeshPackageEntry,
  PlaymeshPackageEntryProducer,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';

type PlaymeshMixedRecord = { +[string]: mixed };

export type PlaymeshCommittedImportResult = {
  committed: true,
  project: {
    id: string,
    name: string,
    version: string,
    [string]: mixed,
  },
  preservedDirectories: Array<mixed>,
  [string]: mixed,
};

export type PlaymeshPackageProgress =
  | {|
      phase: 'compressing',
      completedFiles: number,
      totalFiles: number,
    |}
  | {|
      phase: 'uploading',
      bytesProduced: number,
    |};

type PlaymeshPackageUploadErrorDetails = {
  cause?: mixed,
  bytesProduced?: number,
  safeToRetry?: boolean,
  responseReceived?: boolean,
  stateUncertain?: boolean,
  status?: number,
  +[string]: mixed,
};

type PlaymeshPackageProgressCallback = PlaymeshPackageProgress => void;
type PlaymeshZipLoader = () => Promise<ZipJs>;
type PlaymeshFetchImplementation = typeof fetch;
type PlaymeshRequestConstructor = typeof Request;
type PlaymeshReadableStreamConstructor = typeof ReadableStream;

type PlaymeshStreamingSupportOptions = {|
  RequestConstructor?: PlaymeshRequestConstructor,
  ReadableStreamConstructor?: PlaymeshReadableStreamConstructor,
  fetchImplementation?: PlaymeshFetchImplementation,
|};

type PlaymeshWriteZipOptions = {|
  zipJs: ZipJs,
  writer: ZipJs$Writer,
  producer: PlaymeshPackageEntryProducer,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshPackageProgressCallback,
|};

type PlaymeshAddEntriesOptions = {|
  zipJs: ZipJs,
  zipWriter: ZipJs$ZipWriter,
  producer: PlaymeshPackageEntryProducer,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshPackageProgressCallback,
|};

type PlaymeshPendingWrite = {|
  callback: () => void,
  onerror: ?(error: mixed) => void,
|};

type PlaymeshStreamingWriter = {|
  writer: ZipJs$Writer,
  stream: ReadableStream,
  fail: (error: mixed) => void,
  +bytesProduced: number,
|};

export type PlaymeshResponseValidator<Result> = (
  response: mixed,
  expectedGameId: string
) => Result;

export type PlaymeshUploadCommonOptions<Result> = {
  +producer: PlaymeshPackageEntryProducer,
  +expectedGameId: string,
  +requestUrl?: string,
  +responseValidator?: PlaymeshResponseValidator<Result>,
  +signal?: ?AbortSignal,
  +onProgress?: PlaymeshPackageProgressCallback,
  +fetchImplementation?: PlaymeshFetchImplementation,
  +zipLoader?: PlaymeshZipLoader,
};

export type PlaymeshStreamUploadOptions<Result> = {
  ...PlaymeshUploadCommonOptions<Result>,
  +RequestConstructor?: PlaymeshRequestConstructor,
  +ReadableStreamConstructor?: PlaymeshReadableStreamConstructor,
  +featureDetector?: PlaymeshStreamingSupportOptions => boolean,
};

type PlaymeshBlobCreationOptions = {|
  producer: PlaymeshPackageEntryProducer,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshPackageProgressCallback,
  zipLoader?: PlaymeshZipLoader,
|};
*/

const IMPORT_URL = '/dev/api/packages/import';

export class PlaymeshPackageUploadError extends Error {
  /*::
  code: string;
  cause: mixed;
  bytesProduced: ?number;
  safeToRetry: ?boolean;
  responseReceived: ?boolean;
  stateUncertain: ?boolean;
  status: ?number;
  */

  constructor(
    code /*: string */,
    message /*: string */,
    details /*: PlaymeshPackageUploadErrorDetails */ = {}
  ) {
    super(message);
    this.name = 'PlaymeshPackageUploadError';
    this.code = code;
    this.cause = undefined;
    this.bytesProduced = undefined;
    this.safeToRetry = undefined;
    this.responseReceived = undefined;
    this.stateUncertain = undefined;
    this.status = undefined;
    Object.keys(details).forEach(key => {
      Reflect.set(this, key, details[key]);
    });
  }
}

const cancelledError = () /*: Error */ => {
  const error = new Error('发布已取消。');
  error.name = 'AbortError';
  return error;
};

const readerForEntry = (
  zipJs /*: ZipJs */,
  entry /*: PlaymeshPackageEntry */
) /*: ZipJs$Reader */ => {
  if (entry.kind === 'text') {
    return Reflect.construct(zipJs.TextReader, [entry.text]);
  }
  if (entry.kind === 'blob') {
    return Reflect.construct(zipJs.BlobReader, [entry.blob]);
  }
  throw new PlaymeshPackageUploadError(
    'invalid_package_entry',
    `无法压缩未知文件类型：${entry.filePath}`
  );
};

const addEntries = async ({
  zipJs,
  zipWriter,
  producer,
  signal,
  onProgress,
} /*: PlaymeshAddEntriesOptions */) /*: Promise<void> */ => {
  let completedFiles = 0;
  for (const entry of producer.entries()) {
    if (signal && signal.aborted) throw cancelledError();
    await new Promise/*::<void>*/((resolve, reject) => {
      try {
        zipWriter.add(
          entry.filePath,
          readerForEntry(zipJs, entry),
          resolve,
          () => {},
          {}
        );
      } catch (error) {
        reject(error);
      }
    });
    completedFiles++;
    if (onProgress) {
      onProgress({
        phase: 'compressing',
        completedFiles,
        totalFiles: producer.fileCount,
      });
    }
  }
};

const writeZip = ({
  zipJs,
  writer,
  producer,
  signal,
  onProgress,
} /*: PlaymeshWriteZipOptions */) /*: Promise<mixed> */ =>
  new Promise/*::<mixed>*/((resolve, reject) => {
    zipJs.createWriter(
      writer,
      zipWriter => {
        (async () => {
          await addEntries({ zipJs, zipWriter, producer, signal, onProgress });
          if (signal && signal.aborted) throw cancelledError();
          zipWriter.close(resolve);
        })().catch(reject);
      },
      reject
    );
  });

export const supportsPlaymeshStreamingUpload /*: (
  options?: PlaymeshStreamingSupportOptions
) => boolean */ = ({
  RequestConstructor = global.Request,
  ReadableStreamConstructor = global.ReadableStream,
  fetchImplementation = global.fetch,
} = {}) => {
  if (!RequestConstructor || !ReadableStreamConstructor || !fetchImplementation) {
    return false;
  }
  try {
    let duplexWasRead = false;
    const body = new ReadableStreamConstructor({
      start(controller) {
        controller.close();
      },
    });
    const request = new RequestConstructor(
      global.location ? global.location.href : 'http://127.0.0.1/',
      {
        method: 'POST',
        body,
        get duplex() {
          duplexWasRead = true;
          return 'half';
        },
      }
    );
    const requestRecord = mixedRecord(request);
    return duplexWasRead && !!(requestRecord && requestRecord.body);
  } catch (_) {
    return false;
  }
};

const createStreamingZipWriter = ({
  signal,
  onProgress,
  ReadableStreamConstructor,
} /*: {|
  signal?: ?AbortSignal,
  onProgress?: PlaymeshPackageProgressCallback,
  ReadableStreamConstructor: PlaymeshReadableStreamConstructor,
|} */) /*: PlaymeshStreamingWriter */ => {
  let controller /*: ?ReadableStreamController */ = null;
  let closed = false;
  let failed = false;
  let bytesProduced = 0;
  const pendingWrites /*: Array<PlaymeshPendingWrite> */ = [];

  const fail = (error /*: mixed */) /*: void */ => {
    if (failed || closed) return;
    failed = true;
    const streamError =
      error instanceof Error ? error : new Error(String(error));
    if (controller) controller.error(streamError);
    while (pendingWrites.length) {
      const pending = pendingWrites.shift();
      if (pending && pending.onerror) pending.onerror(error);
    }
  };

  const resumeOneWrite = () => {
    if (!pendingWrites.length || failed) return;
    const pending = pendingWrites.shift();
    if (pending) pending.callback();
  };

  const stream = new ReadableStreamConstructor({
    start(nextController /*: ReadableStreamController */) {
      controller = nextController;
    },
    pull() {
      resumeOneWrite();
    },
    cancel(reason) {
      fail(reason instanceof Error ? reason : cancelledError());
    },
  });

  if (signal) {
    signal.addEventListener(
      'abort',
      () => {
        const signalRecord = mixedRecord(signal);
        const abortReason = signalRecord && signalRecord.reason;
        fail(abortReason instanceof Error ? abortReason : cancelledError());
      },
      { once: true }
    );
  }

  const rawWriter = Reflect.construct(Object, []);
  const initializeWriter = (
    callback /*: () => void */,
    onerror /*: ?(error: mixed) => void */ = null
  ) /*: void */ => {
    if (failed || (signal && signal.aborted)) {
      if (onerror) onerror(cancelledError());
      return;
    }
    callback();
  };
  const writeChunk = (
    array /*: Uint8Array */,
    callback /*: () => void */,
    onerror /*: ?(error: mixed) => void */ = null
  ) /*: void */ => {
    if (failed || (signal && signal.aborted)) {
      if (onerror) onerror(cancelledError());
      return;
    }
    try {
      // zip.js may reuse its Uint8Array. Copy one chunk, never the full ZIP.
      const chunk = new Uint8Array(array);
      const activeController = controller;
      if (!activeController) {
        throw new Error('Playmesh ZIP 流尚未初始化。');
      }
      activeController.enqueue(chunk);
      bytesProduced += chunk.byteLength;
      if (onProgress) {
        onProgress({ phase: 'uploading', bytesProduced });
      }
      if ((activeController.desiredSize || 0) > 0) callback();
      else pendingWrites.push({ callback, onerror });
    } catch (error) {
      fail(error);
      if (onerror) onerror(error);
    }
  };
  const finishWriter = (
    callback /*: (result: mixed) => void */,
    _onerror /*: ?(error: mixed) => void */ = null
  ) /*: void */ => {
    if (!failed && !closed) {
      closed = true;
      const activeController = controller;
      if (!activeController) {
        throw new Error('Playmesh ZIP 流尚未初始化。');
      }
      activeController.close();
    }
    callback({ bytesProduced });
  };
  Object.defineProperties(rawWriter, {
    init: {
      value: initializeWriter,
      enumerable: true,
      configurable: true,
      writable: true,
    },
    writeUint8Array: {
      value: writeChunk,
      enumerable: true,
      configurable: true,
      writable: true,
    },
    getData: {
      value: finishWriter,
      enumerable: true,
      configurable: true,
      writable: true,
    },
  });
  const writer /*: ZipJs$Writer */ = rawWriter;

  return {
    writer,
    stream,
    fail,
    get bytesProduced() {
      return bytesProduced;
    },
  };
};

const responseJson = async (response /*: Response */) /*: Promise<mixed> */ => {
  try {
    return await response.json();
  } catch (_) {
    return null;
  }
};

const mixedRecord = (
  value /*: mixed */
) /*: ?PlaymeshMixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

const assertCommittedImport = (
  result /*: mixed */,
  expectedGameId /*: string */
) /*: PlaymeshCommittedImportResult */ => {
  const resultRecord = mixedRecord(result);
  const project = mixedRecord(resultRecord && resultRecord.project);
  if (
    !resultRecord ||
    resultRecord.committed !== true ||
    !project ||
    typeof project.id !== 'string' ||
    !project.id ||
    project.id !== expectedGameId ||
    typeof project.name !== 'string' ||
    !project.name ||
    typeof project.version !== 'string' ||
    !project.version ||
    !Array.isArray(resultRecord.preservedDirectories)
  ) {
    throw new PlaymeshPackageUploadError(
      'invalid_import_response',
      'Playmesh 返回了无效的安装结果。',
      {
        responseReceived: true,
        safeToRetry: false,
        stateUncertain: true,
      }
    );
  }
  return {
    committed: true,
    project: {
      id: project.id,
      name: project.name,
      version: project.version,
    },
    preservedDirectories: [...resultRecord.preservedDirectories],
  };
};

export const uploadPlaymeshPackageStream /*: <Result = empty>(
  options: PlaymeshStreamUploadOptions<Result>
) => Promise<PlaymeshCommittedImportResult | Result> */ = async ({
  producer,
  expectedGameId,
  requestUrl = IMPORT_URL,
  responseValidator,
  signal,
  onProgress,
  fetchImplementation = global.fetch,
  RequestConstructor = global.Request,
  ReadableStreamConstructor = global.ReadableStream,
  zipLoader = initializeZipJs,
  featureDetector = supportsPlaymeshStreamingUpload,
}) => {
  if (
    !featureDetector({
      RequestConstructor,
      ReadableStreamConstructor,
      fetchImplementation,
    })
  ) {
    throw new PlaymeshPackageUploadError(
      'stream_upload_unsupported',
      '当前 WebView 或浏览器不支持流式发布。',
      { bytesProduced: 0, safeToRetry: true, responseReceived: false }
    );
  }
  const zipJs = await zipLoader();
  const streamingWriter = createStreamingZipWriter({
    signal,
    onProgress,
    ReadableStreamConstructor,
  });
  const zipCompleted = writeZip({
    zipJs,
    writer: streamingWriter.writer,
    producer,
    signal,
    onProgress,
  }).catch(error => {
    streamingWriter.fail(error);
    throw error;
  });
  // Prevent a producer rejection becoming unhandled while fetch is settling.
  zipCompleted.catch(() => {});
  let response;
  try {
    response = await fetchImplementation(requestUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/zip',
        'X-Playmesh-Client-ID': 'visual-gdevelop',
      },
      credentials: 'same-origin',
      cache: 'no-store',
      body: streamingWriter.stream,
      duplex: 'half',
      signal,
    });
  } catch (error) {
    streamingWriter.fail(error);
    const bytesProduced = streamingWriter.bytesProduced;
    if (signal && signal.aborted) {
      throw new PlaymeshPackageUploadError('cancelled', '发布已取消。', {
        bytesProduced,
        safeToRetry: false,
        responseReceived: false,
        stateUncertain: bytesProduced > 0,
      });
    }
    throw new PlaymeshPackageUploadError(
      bytesProduced === 0
        ? 'stream_upload_failed_before_body'
        : 'upload_state_uncertain',
      bytesProduced === 0
        ? '流式发布在发送正文前失败。'
        : '连接在发布过程中中断，无法确认是否已安装。请先检查本地游戏库。',
      {
        cause: error,
        bytesProduced,
        safeToRetry: bytesProduced === 0,
        responseReceived: false,
        stateUncertain: bytesProduced > 0,
      }
    );
  }
  const details /*: mixed */ = await responseJson(response);
  if (!response.ok) {
    streamingWriter.fail(new Error(`HTTP ${response.status}`));
    const detailsRecord = mixedRecord(details);
    const envelope = mixedRecord(detailsRecord && detailsRecord.error);
    const responseCode = envelope && envelope.code;
    const responseMessage = envelope && envelope.message;
    throw new PlaymeshPackageUploadError(
      typeof responseCode === 'string' && responseCode
        ? responseCode
        : 'package_import_failed',
      typeof responseMessage === 'string' && responseMessage
        ? responseMessage
        : `Playmesh 安装失败（HTTP ${response.status}）。`,
      {
        status: response.status,
        bytesProduced: streamingWriter.bytesProduced,
        responseReceived: true,
        safeToRetry: false,
        stateUncertain: false,
      }
    );
  }
  await zipCompleted;
  return responseValidator
    ? responseValidator(details, expectedGameId)
    : assertCommittedImport(details, expectedGameId);
};

export const createPlaymeshPackageBlob /*: (
  options: PlaymeshBlobCreationOptions
) => Promise<Blob> */ = async ({
  producer,
  signal,
  onProgress,
  zipLoader = initializeZipJs,
}) => {
  const zipJs = await zipLoader();
  const result = await writeZip({
    zipJs,
    writer: Reflect.construct(zipJs.BlobWriter, ['application/zip']),
    producer,
    signal,
    onProgress,
  });
  if (!(result instanceof Blob)) {
    throw new PlaymeshPackageUploadError(
      'invalid_zip_output',
      'Playmesh ZIP 生成器没有返回 Blob。'
    );
  }
  return result;
};

export const uploadPlaymeshPackageBlob /*: <Result = empty>(
  options: PlaymeshUploadCommonOptions<Result>
) => Promise<PlaymeshCommittedImportResult | Result> */ = async ({
  producer,
  expectedGameId,
  requestUrl = IMPORT_URL,
  responseValidator,
  signal,
  onProgress,
  fetchImplementation = global.fetch,
  zipLoader = initializeZipJs,
}) => {
  const blob = await createPlaymeshPackageBlob({
    producer,
    signal,
    onProgress,
    zipLoader,
  });
  let response;
  try {
    response = await fetchImplementation(requestUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/zip',
        'X-Playmesh-Client-ID': 'visual-gdevelop',
      },
      credentials: 'same-origin',
      cache: 'no-store',
      body: blob,
      signal,
    });
  } catch (error) {
    throw new PlaymeshPackageUploadError(
      signal && signal.aborted ? 'cancelled' : 'blob_upload_failed',
      signal && signal.aborted
        ? '发布已取消。'
        : '内存 ZIP 已生成，但无法连接 Playmesh 安装通道。',
      { cause: error, safeToRetry: false, responseReceived: false }
    );
  }
  const details /*: mixed */ = await responseJson(response);
  if (!response.ok) {
    const detailsRecord = mixedRecord(details);
    const envelope = mixedRecord(detailsRecord && detailsRecord.error);
    const responseCode = envelope && envelope.code;
    const responseMessage = envelope && envelope.message;
    throw new PlaymeshPackageUploadError(
      typeof responseCode === 'string' && responseCode
        ? responseCode
        : 'package_import_failed',
      typeof responseMessage === 'string' && responseMessage
        ? responseMessage
        : `Playmesh 安装失败（HTTP ${response.status}）。`,
      { status: response.status, safeToRetry: false, responseReceived: true }
    );
  }
  return responseValidator
    ? responseValidator(details, expectedGameId)
    : assertCommittedImport(details, expectedGameId);
};
