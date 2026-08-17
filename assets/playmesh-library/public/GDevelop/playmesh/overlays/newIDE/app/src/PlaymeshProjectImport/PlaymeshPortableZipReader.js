// @flow
import { initializeZipJs } from '../Utils/Zip.js';
import {
  inspectPortableProjectEntries,
  PlaymeshProjectImportError,
} from './PlaymeshPortableProjectFormat';

const invalidZipError = (
  rawError /*: mixed */
) /*: PlaymeshProjectImportError */ =>
  rawError instanceof PlaymeshProjectImportError
    ? rawError
    : new PlaymeshProjectImportError(
        'invalid_zip',
        '工程 ZIP 已损坏或使用了不支持的压缩格式。',
        rawError
      );

/**
 * zip.js 2.x accepts a writer object. This writer refuses output before a
 * malicious entry can grow past the size declared by the validated central
 * directory. It also avoids a second full ArrayBuffer for resource files.
 */
export const createLimitedBlobWriter = (
  {
    contentType,
    expectedBytes,
    maxBytes,
    onFailure,
  } /*: {|
  contentType: string,
  expectedBytes: number,
  maxBytes: number,
  onFailure: PlaymeshProjectImportError => void,
|} */
) /*: any */ => {
  let totalBytes = 0;
  let failure = null;
  const parts = [];

  const failWriter = (
    rawError /*: mixed */,
    onerror /*: ?(mixed => void) */
  ) => {
    if (!failure) {
      failure =
        rawError instanceof PlaymeshProjectImportError
          ? rawError
          : new PlaymeshProjectImportError(
              'archive_extraction_failed',
              '工程 ZIP 条目解压失败。',
              rawError
            );
      onFailure(failure);
    }
    if (onerror) onerror(failure);
  };

  return {
    init(callback, onerror) {
      if (failure) {
        failWriter(failure, onerror);
        return;
      }
      callback();
    },
    writeUint8Array(array, callback, onerror) {
      if (!(array instanceof Uint8Array)) {
        failWriter(new Error('zip.js returned a non-byte chunk.'), onerror);
        return;
      }
      const nextTotal = totalBytes + array.byteLength;
      if (
        !Number.isSafeInteger(nextTotal) ||
        nextTotal > maxBytes ||
        nextTotal > expectedBytes
      ) {
        failWriter(
          new PlaymeshProjectImportError(
            'expanded_entry_too_large',
            'ZIP 条目实际解压大小超过声明值或安全上限。',
            {
              limitCode: 'entryActualBytes',
              actual: nextTotal,
              max: Math.min(expectedBytes, maxBytes),
              expectedBytes,
            }
          ),
          onerror
        );
        return;
      }
      // A worker may reuse its transfer buffer after the callback.
      parts.push(new Uint8Array(array));
      totalBytes = nextTotal;
      callback();
    },
    getData(callback, onerror) {
      if (failure) {
        failWriter(failure, onerror);
        return;
      }
      if (totalBytes !== expectedBytes) {
        failWriter(
          new PlaymeshProjectImportError(
            'expanded_entry_size_mismatch',
            'ZIP 条目实际解压大小与声明值不一致。',
            { expectedBytes, actualBytes: totalBytes }
          ),
          onerror
        );
        return;
      }
      callback(new Blob(parts, { type: contentType }));
    },
  };
};

export const openPlaymeshPortableZip = async (
  archiveBlob /*: Blob */,
  options /*: ?{| zipJs?: any, limits?: Object |} */ = null
) /*: Promise<any> */ => {
  if (!(archiveBlob instanceof Blob)) {
    throw new PlaymeshProjectImportError(
      'invalid_archive',
      '请选择一个 GDevelop portable ZIP 文件。'
    );
  }
  const zipJs =
    options && options.zipJs ? options.zipJs : await initializeZipJs();
  let zipReader = null;
  let activeExtractionReject /*: ?(mixed => void) */ = null;
  let openingReject /*: ?(mixed => void) */ = null;
  let closed = false;
  let extractionInProgress = false;

  const entries /*: Array<any> */ = await new Promise((resolve, reject) => {
    openingReject = reject;
    const rejectOpening = (rawError /*: mixed */) => {
      if (!openingReject) return;
      const rejectCurrent = openingReject;
      openingReject = null;
      if (zipReader) {
        try {
          zipReader.close();
        } catch (_) {}
      }
      rejectCurrent(invalidZipError(rawError));
    };
    try {
      zipJs.createReader(
        // $FlowFixMe[invalid-constructor]
        new zipJs.BlobReader(archiveBlob),
        reader => {
          zipReader = reader;
          try {
            reader.getEntries(value => {
              openingReject = null;
              resolve(value);
            });
          } catch (error) {
            rejectOpening(error);
          }
        },
        rawError => {
          const error = invalidZipError(rawError);
          if (activeExtractionReject) activeExtractionReject(error);
          else rejectOpening(error);
        }
      );
    } catch (error) {
      rejectOpening(error);
    }
  });

  let inspectedArchive;
  try {
    inspectedArchive = inspectPortableProjectEntries({
      archiveBytes: archiveBlob.size,
      entries,
      limits: options && options.limits,
    });
  } catch (error) {
    if (zipReader) {
      try {
        zipReader.close();
      } catch (_) {}
    }
    throw error;
  }

  const readBlob = async (
    {
      path,
      contentType,
      maxBytes,
    } /*: {|
    path: string,
    contentType: string,
    maxBytes: number,
  |} */
  ) /*: Promise<Blob> */ => {
    if (closed || !zipReader) {
      throw new PlaymeshProjectImportError(
        'archive_closed',
        '工程 ZIP 已关闭。'
      );
    }
    if (extractionInProgress) {
      throw new PlaymeshProjectImportError(
        'concurrent_archive_read',
        '工程 ZIP 必须逐项读取。'
      );
    }
    const descriptor = inspectedArchive.files.get(path);
    if (!descriptor) {
      throw new PlaymeshProjectImportError(
        'missing_archive_entry',
        `工程 ZIP 缺少文件：${path}`
      );
    }
    if (descriptor.uncompressedSize > maxBytes) {
      throw new PlaymeshProjectImportError(
        'expanded_entry_too_large',
        `工程 ZIP 文件超过读取上限：${path}`,
        {
          limitCode: 'readMaxBytes',
          actual: descriptor.uncompressedSize,
          max: maxBytes,
          path,
        }
      );
    }

    extractionInProgress = true;
    try {
      return await new Promise((resolve, reject) => {
        let settled = false;
        const finishReject = (rawError /*: mixed */) => {
          if (settled) return;
          settled = true;
          activeExtractionReject = null;
          reject(invalidZipError(rawError));
        };
        activeExtractionReject = finishReject;
        const writer = createLimitedBlobWriter({
          contentType,
          expectedBytes: descriptor.uncompressedSize,
          maxBytes,
          onFailure: finishReject,
        });
        try {
          descriptor.entry.getData(
            writer,
            result => {
              if (settled) return;
              if (
                !(result instanceof Blob) ||
                result.size !== descriptor.uncompressedSize
              ) {
                finishReject(
                  new PlaymeshProjectImportError(
                    'expanded_entry_size_mismatch',
                    `ZIP 文件解压大小不一致：${path}`
                  )
                );
                return;
              }
              settled = true;
              activeExtractionReject = null;
              resolve(result);
            },
            () => {},
            true // Enforce the CRC32 stored by the official exporter.
          );
        } catch (error) {
          finishReject(error);
        }
      });
    } finally {
      extractionInProgress = false;
    }
  };

  const close = () /*: Promise<void> */ => {
    if (closed) return Promise.resolve();
    closed = true;
    return new Promise(resolve => {
      if (!zipReader) {
        resolve();
        return;
      }
      zipReader.close(resolve);
    });
  };

  return { inspectedArchive, readBlob, close };
};
