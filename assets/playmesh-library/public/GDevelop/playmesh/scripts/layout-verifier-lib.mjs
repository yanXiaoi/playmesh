import path from 'node:path';

import { normalizePolicyRelativePath } from './source-policy-verifier-lib.mjs';

const executableTestFilePattern = /^test-[^/]+\.mjs$/;

// fixture 必须保持为惰性数据。新增格式需要在这里显式审核，不能让脚本扩展名混入数据区。
const fixtureDataExtensions = new Set([
  '.csv',
  '.json',
  '.jsonl',
  '.tsv',
  '.txt',
  '.yaml',
  '.yml',
]);

export const classifyPlaymeshTestFiles = files => {
  if (!Array.isArray(files)) {
    throw new TypeError('Playmesh test tree files must be an array');
  }

  const executableTestFiles = [];
  const fixtureDataFiles = [];
  const seenPaths = new Set();

  for (const file of files) {
    if (!file || typeof file !== 'object' || Array.isArray(file)) {
      throw new TypeError('Playmesh test tree entries must be file records');
    }
    const relativePath = normalizePolicyRelativePath(
      file.relativePath,
      'Playmesh test tree relativePath'
    );
    if (seenPaths.has(relativePath)) {
      throw new Error(
        `Playmesh test tree contains duplicate path: ${relativePath}`
      );
    }
    seenPaths.add(relativePath);

    const segments = relativePath.split('/');
    if (segments[0] === 'fixtures') {
      if (segments.length < 2) {
        throw new Error(
          'Playmesh tests/fixtures must contain a data file path'
        );
      }
      const extension = path.posix.extname(relativePath).toLowerCase();
      if (!fixtureDataExtensions.has(extension)) {
        throw new Error(
          `Playmesh fixture must use an approved data extension, not executable code: ${relativePath}`
        );
      }
      fixtureDataFiles.push(file);
      continue;
    }

    if (segments.length !== 1) {
      throw new Error(
        `Only playmesh/tests/fixtures/** data files may be nested: ${relativePath}`
      );
    }
    if (!executableTestFilePattern.test(relativePath)) {
      throw new Error(
        `Every executable playmesh/tests file must be named test-*.mjs: ${relativePath}`
      );
    }
    executableTestFiles.push(file);
  }

  if (executableTestFiles.length === 0) {
    throw new Error(
      'Playmesh test tree must contain at least one test-*.mjs verifier'
    );
  }

  return Object.freeze({
    executableTestFiles: Object.freeze(executableTestFiles),
    fixtureDataFiles: Object.freeze(fixtureDataFiles),
  });
};
