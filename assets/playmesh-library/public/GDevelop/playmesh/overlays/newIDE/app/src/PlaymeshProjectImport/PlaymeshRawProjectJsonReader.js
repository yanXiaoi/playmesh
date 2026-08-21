// @flow

import {
  PlaymeshProjectImportError,
  resolvePortableImportLimits,
} from './PlaymeshPortableProjectFormat';

/**
 * Expose a standalone official game.json through the same sequential reader
 * boundary used by the ZIP importer. A raw JSON file has no neighbouring
 * resource or split-project files; after parsing it follows the shared libGD
 * deserialize/createProjectSnapshot pipeline.
 */
export const openPlaymeshRawProjectJson = async (
  projectJsonBlob /*: Blob */,
  options /*: ?{| limits?: Object |} */ = null
) /*: Promise<any> */ => {
  if (!(projectJsonBlob instanceof Blob)) {
    throw new PlaymeshProjectImportError(
      'invalid_project_json',
      '请选择一个 GDevelop game.json 文件。'
    );
  }

  const limits = resolvePortableImportLimits(options && options.limits);
  let closed = false;
  const descriptor = {
    normalizedPath: 'game.json',
    compressedSize: projectJsonBlob.size,
    uncompressedSize: projectJsonBlob.size,
  };
  const inspectedArchive = {
    files: new Map([['game.json', descriptor]]),
    limits,
    compressedBytes: projectJsonBlob.size,
    expandedBytes: projectJsonBlob.size,
  };

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
    if (closed) {
      throw new PlaymeshProjectImportError(
        'archive_closed',
        'GDevelop game.json 已关闭。'
      );
    }
    if (path !== 'game.json') {
      throw new PlaymeshProjectImportError(
        'missing_archive_entry',
        `GDevelop game.json 缺少文件：${path}`
      );
    }
    if (projectJsonBlob.size > maxBytes) {
      throw new PlaymeshProjectImportError(
        'project_json_too_large',
        'game.json 超过当前设备的导入预算。',
        {
          limitCode: 'maxProjectFileBytes',
          actual: projectJsonBlob.size,
          max: maxBytes,
          path,
        }
      );
    }
    return projectJsonBlob.slice(0, projectJsonBlob.size, contentType);
  };

  const close = () /*: Promise<void> */ => {
    closed = true;
    return Promise.resolve();
  };

  return { inspectedArchive, readBlob, close };
};
