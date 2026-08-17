import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const uploaderPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/ExportAndShare/PlaymeshPackageUploader.js'
);
let uploaderSource = await readFile(uploaderPath, 'utf8');
globalThis.__playmeshZipLoader = async () => {
  throw new Error('A test must supply its zipLoader explicitly.');
};
uploaderSource = uploaderSource.replace(
  "import { initializeZipJs } from '../Utils/Zip.js';",
  'const initializeZipJs = globalThis.__playmeshZipLoader;'
);
const uploader = await import(
  `data:text/javascript;base64,${Buffer.from(uploaderSource).toString('base64')}`
);

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const createFakeZipJs = ({ deferStart = false } = {}) => {
  const state = {
    blobWriterCount: 0,
    activeAdds: 0,
    maxActiveAdds: 0,
  };

  class TextReader {
    constructor(text) {
      this.text = text;
    }
  }

  class BlobReader {
    constructor(blob) {
      this.blob = blob;
    }
  }

  class BlobWriter {
    constructor(contentType) {
      state.blobWriterCount++;
      this.contentType = contentType;
      this.chunks = [];
    }

    init(callback) {
      callback();
    }

    writeUint8Array(array, callback) {
      this.chunks.push(new Uint8Array(array));
      callback();
    }

    getData(callback) {
      callback(new Blob(this.chunks, { type: this.contentType }));
    }
  }

  const createWriter = (writer, onready, onerror) => {
    const start = () => {
      writer.init(() => {
        const zipWriter = {
          add(filePath, reader, onend) {
            state.activeAdds++;
            state.maxActiveAdds = Math.max(
              state.maxActiveAdds,
              state.activeAdds
            );
            const finishEntry = () => {
              state.activeAdds--;
              onend();
            };
            const write = content => {
              const header = encoder.encode(`FILE:${filePath}\n`);
              const payload =
                typeof content === 'string' ? encoder.encode(content) : content;
              const bytes = new Uint8Array(header.length + payload.length);
              bytes.set(header);
              bytes.set(payload, header.length);
              writer.writeUint8Array(bytes, finishEntry, onerror);
              // The pinned zip.js implementation may reuse its buffer. The
              // streaming Writer must have copied it synchronously.
              bytes.fill(0);
            };
            if (reader instanceof TextReader) {
              write(reader.text);
              return;
            }
            reader.blob
              .arrayBuffer()
              .then(buffer => write(new Uint8Array(buffer)), onerror);
          },
          close(callback) {
            writer.getData(callback, onerror);
          },
        };
        onready(zipWriter);
      }, onerror);
    };
    if (deferStart) setTimeout(start, 5);
    else start();
  };

  return {
    zipJs: { TextReader, BlobReader, BlobWriter, createWriter },
    state,
  };
};

const entries = [
  {
    filePath: 'app/index.html',
    kind: 'text',
    text: '<!doctype html><title>Playmesh</title>',
  },
  {
    filePath: 'app/assets/data.bin',
    kind: 'blob',
    blob: new Blob([new Uint8Array([1, 2, 3, 4])]),
  },
  {
    filePath: 'main.json',
    kind: 'text',
    text: '{"id":"com.playmesh.game.gpublish001"}\n',
  },
];
const producer = {
  fileCount: entries.length,
  entries: () => entries.values(),
};

const gameId = 'com.playmesh.game.gpublish001';
const successResult = {
  committed: true,
  project: {
    id: gameId,
    name: 'Published',
    version: '1.0.0',
  },
  preservedDirectories: [],
};
const jsonResponse = (status, body) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
});
const consumeStream = async stream => {
  const reader = stream.getReader();
  const chunks = [];
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    chunks.push(result.value);
    // Yield between reads so the custom Writer must resume through pull().
    await Promise.resolve();
  }
  return chunks;
};
const withTimeout = promise =>
  Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Uploader test timed out.')), 3000)
    ),
  ]);

{
  const { zipJs, state } = createFakeZipJs();
  const progress = [];
  let requestOptions;
  let detectedCapabilities;
  let streamConstructions = 0;
  const NativeReadableStream = globalThis.ReadableStream;
  const CountingReadableStream = function(source) {
    streamConstructions++;
    return new NativeReadableStream(source);
  };
  const fetchImplementation = async (url, options) => {
    assert.equal(url, '/dev/api/packages/import');
    requestOptions = options;
    const chunks = await consumeStream(options.body);
    assert.ok(chunks.length >= entries.length);
    const body = decoder.decode(
      new Uint8Array(chunks.flatMap(chunk => Array.from(chunk)))
    );
    for (const entry of entries) assert.match(body, new RegExp(entry.filePath));
    return jsonResponse(200, successResult);
  };
  const result = await withTimeout(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      RequestConstructor: globalThis.Request,
      ReadableStreamConstructor: CountingReadableStream,
      featureDetector: capabilities => {
        detectedCapabilities = capabilities;
        return true;
      },
      zipLoader: async () => zipJs,
      onProgress: value => progress.push(value),
      fetchImplementation,
    })
  );
  assert.deepEqual(result, successResult);
  assert.equal(requestOptions.method, 'POST');
  assert.equal(requestOptions.duplex, 'half');
  assert.equal(requestOptions.credentials, 'same-origin');
  assert.equal(requestOptions.headers['Content-Type'], 'application/zip');
  assert.equal(
    requestOptions.headers['X-Playmesh-Client-ID'],
    'visual-gdevelop'
  );
  assert.equal(state.blobWriterCount, 0);
  assert.equal(state.maxActiveAdds, 1);
  assert.equal(streamConstructions, 1);
  assert.equal(detectedCapabilities.RequestConstructor, globalThis.Request);
  assert.equal(
    detectedCapabilities.ReadableStreamConstructor,
    CountingReadableStream
  );
  assert.equal(detectedCapabilities.fetchImplementation, fetchImplementation);
  assert.equal(
    progress.filter(item => item.phase === 'compressing').at(-1).completedFiles,
    entries.length
  );
  assert.ok(progress.some(item => item.bytesProduced > 0));
}

{
  let zipLoaded = false;
  let fetchCalled = false;
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      featureDetector: () => false,
      zipLoader: async () => {
        zipLoaded = true;
      },
      fetchImplementation: async () => {
        fetchCalled = true;
      },
    }),
    error =>
      error.code === 'stream_upload_unsupported' &&
      error.bytesProduced === 0 &&
      error.safeToRetry === true
  );
  assert.equal(zipLoaded, false);
  assert.equal(fetchCalled, false);
}

{
  const { zipJs } = createFakeZipJs({ deferStart: true });
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async () => {
        throw new Error('Connection rejected before request body.');
      },
    }),
    error =>
      error.code === 'stream_upload_failed_before_body' &&
      error.bytesProduced === 0 &&
      error.safeToRetry === true &&
      error.stateUncertain === false
  );
}

{
  const { zipJs, state } = createFakeZipJs();
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async () => {
        throw new Error('Connection lost after ZIP production started.');
      },
    }),
    error =>
      error.code === 'upload_state_uncertain' &&
      error.bytesProduced > 0 &&
      error.safeToRetry === false &&
      error.responseReceived === false &&
      error.stateUncertain === true
  );
  assert.equal(state.blobWriterCount, 0);
}

{
  const { zipJs } = createFakeZipJs();
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async (_, options) => {
        await consumeStream(options.body);
        return jsonResponse(409, {
          error: { code: 'version_conflict', message: 'Version conflict.' },
        });
      },
    }),
    error =>
      error.code === 'version_conflict' &&
      error.message === 'Version conflict.' &&
      error.responseReceived === true &&
      error.stateUncertain === false &&
      error.safeToRetry === false
  );
}

{
  const { zipJs } = createFakeZipJs();
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async (_, options) => {
        await consumeStream(options.body);
        return jsonResponse(200, {
          committed: true,
          project: { id: 'com.playmesh.game.gpublish001', name: 'Published' },
        });
      },
    }),
    error =>
      error.code === 'invalid_import_response' &&
      error.responseReceived === true &&
      error.safeToRetry === false &&
      error.stateUncertain === true
  );
}

{
  const { zipJs } = createFakeZipJs();
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: 'com.playmesh.game.gdifferent001',
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async (_, options) => {
        await consumeStream(options.body);
        return jsonResponse(200, successResult);
      },
    }),
    error =>
      error.code === 'invalid_import_response' &&
      error.responseReceived === true &&
      error.safeToRetry === false &&
      error.stateUncertain === true
  );
}

{
  const { zipJs } = createFakeZipJs();
  const invalidProducer = {
    fileCount: 1,
    entries: () =>
      [
        {
          filePath: 'app/invalid.dat',
          kind: 'unsupported',
        },
      ].values(),
  };
  await assert.rejects(
    withTimeout(
      uploader.uploadPlaymeshPackageStream({
        producer: invalidProducer,
        expectedGameId: gameId,
        featureDetector: () => true,
        zipLoader: async () => zipJs,
        fetchImplementation: async (_, options) => {
          await consumeStream(options.body);
          throw new Error('The invalid ZIP stream must fail.');
        },
      })
    ),
    error =>
      error.code === 'stream_upload_failed_before_body' &&
      error.bytesProduced === 0 &&
      error.safeToRetry === true
  );
}

{
  const { zipJs } = createFakeZipJs();
  await assert.rejects(
    withTimeout(
      uploader.uploadPlaymeshPackageStream({
        producer,
        expectedGameId: gameId,
        featureDetector: () => true,
        zipLoader: async () => zipJs,
        fetchImplementation: async (_, options) => {
          const reader = options.body.getReader();
          const firstChunk = await reader.read();
          assert.equal(firstChunk.done, false);
          await reader.cancel(new Error('Request body consumer cancelled.'));
          throw new Error('Connection closed after consuming a chunk.');
        },
      })
    ),
    error =>
      error.code === 'upload_state_uncertain' &&
      error.bytesProduced > 0 &&
      error.stateUncertain === true &&
      error.safeToRetry === false
  );
}

{
  const { zipJs, state } = createFakeZipJs();
  let fetchCalls = 0;
  const fetchImplementation = async (_, options) => {
    fetchCalls++;
    assert.ok(options.body instanceof Blob);
    if (fetchCalls === 1) throw new Error('Temporary connection failure.');
    return jsonResponse(200, successResult);
  };
  await assert.rejects(
    uploader.uploadPlaymeshPackageBlob({
      producer,
      expectedGameId: gameId,
      zipLoader: async () => zipJs,
      fetchImplementation,
    }),
    error =>
      error.code === 'blob_upload_failed' && error.safeToRetry === false
  );
  const result = await uploader.uploadPlaymeshPackageBlob({
    producer,
    expectedGameId: gameId,
    zipLoader: async () => zipJs,
    fetchImplementation,
  });
  assert.deepEqual(result, successResult);
  assert.equal(fetchCalls, 2);
  assert.equal(state.blobWriterCount, 2);
}

{
  const { zipJs } = createFakeZipJs();
  const previewResult = {
    protocolVersion: '1.0.0',
    previewId: 'preview-1',
    gameId,
    run: { projectId: gameId, phase: 'starting', links: [] },
  };
  let validated = false;
  const result = await uploader.uploadPlaymeshPackageBlob({
    producer,
    expectedGameId: gameId,
    requestUrl: `/dev/api/gdevelop/projects/${gameId}/preview`,
    responseValidator: (details, expectedGameId) => {
      assert.equal(details, previewResult);
      assert.equal(expectedGameId, gameId);
      validated = true;
      return details;
    },
    zipLoader: async () => zipJs,
    fetchImplementation: async (url, options) => {
      assert.equal(
        url,
        `/dev/api/gdevelop/projects/${gameId}/preview`
      );
      assert.ok(options.body instanceof Blob);
      return jsonResponse(202, previewResult);
    },
  });
  assert.equal(validated, true);
  assert.equal(result, previewResult);
}

{
  const { zipJs } = createFakeZipJs();
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    uploader.uploadPlaymeshPackageStream({
      producer,
      expectedGameId: gameId,
      signal: controller.signal,
      featureDetector: () => true,
      zipLoader: async () => zipJs,
      fetchImplementation: async () => {
        throw new DOMException('Aborted', 'AbortError');
      },
    }),
    error =>
      error.code === 'cancelled' &&
      error.safeToRetry === false &&
      error.bytesProduced === 0
  );
}

const dialogSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/ExportAndShare/PlaymeshPublishDialog.js'
  ),
  'utf8'
);
assert.match(
  dialogSource,
  /if \(!supportsPlaymeshStreamingUpload\(\)\)[\s\S]*setState\('fallback-confirm'\)/
);
assert.match(
  dialogSource,
  /error\.safeToRetry === true[\s\S]*error\.bytesProduced === 0[\s\S]*setState\('fallback-confirm'\)/
);
assert.match(
  dialogSource,
  /error\.stateUncertain[\s\S]*setState\('uncertain'\)[\s\S]*playmeshMessages\.publishConnectionUncertain/
);
assert.match(
  dialogSource,
  /error\.code === 'cancelled'[\s\S]*setState\(error\.stateUncertain \? 'uncertain' : 'cancelled'\)[\s\S]*playmeshMessages\.publishCancelledUncertain[\s\S]*playmeshMessages\.publishCancelledClean[\s\S]*return;/
);
assert.match(
  dialogSource,
  /state === 'fallback-confirm' \|\| state === 'fallback-error'[\s\S]*uploadPreparedPackage\('blob'\)/
);
assert.match(dialogSource, /abortControllerRef\.current\.abort\(\)/);
assert.match(
  dialogSource,
  /const beginOperation = \(\): \?number => \{[\s\S]*if \(operationInFlightRef\.current\) return null;[\s\S]*operationInFlightRef\.current = true;/
);
assert.match(
  dialogSource,
  /mountedRef\.current = false;[\s\S]*activeOperationTokenRef\.current = null;[\s\S]*operationInFlightRef\.current = false;[\s\S]*abortControllerRef\.current\.abort\(\)/
);
assert.doesNotMatch(dialogSource, /nextOperationTokenRef\.current\+\+/);
assert.match(
  dialogSource,
  /if \(!isOperationActive\(operationToken\)\) return;[\s\S]*uploadPreparedPackage\('stream', operationToken\)/
);
assert.equal(
  (dialogSource.match(/expectedGameId: prepared\.gameId/g) || []).length,
  2
);
assert.match(
  dialogSource,
  /error\.code === 'blob_upload_failed'[\s\S]*playmeshMessages\.publishBlobFailed/
);
assert.match(dialogSource, /kind=[\s\S]*state === 'ready'[\s\S]*\? 'valid'/);
assert.doesNotMatch(dialogSource, /kind=[\s\S]*\? 'success'/);
assert.match(
  dialogSource,
  /title=\{playmeshT\(playmeshMessages\.publishTitle\)\}/
);
assert.match(dialogSource, /!saved\.gameId/);
assert.match(dialogSource, /gameId: saved\.gameId/);
assert.match(
  dialogSource,
  /project_config_blocks_multiplayer_publish[\s\S]*playmeshMessages\.projectConfigPublishBlocked/
);
assert.doesNotMatch(dialogSource, /title=(?:\{|\")[^\n]*发布/);

process.stdout.write('GDevelop Playmesh package uploader tests passed.\n');
