import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const appRequire = createRequire(
  path.resolve(
    repositoryRoot,
    'work/gdevelop-webide-build-cache/cache/deps/bbf28bb16c6a2ce0083d526eda1d1414f7c2dca83289849270ea43b64eafe380/package.json'
  )
);
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshResourceObjectUrlRegistry.js'
  ),
  'utf8'
);
const executable = transformSync(source, {
  babelrc: false,
  configFile: false,
  plugins: [[flowStripPlugin, { all: true }]],
  sourceType: 'module',
}).code;
const module = await import(
  `data:text/javascript;base64,${Buffer.from(executable).toString('base64')}`
);

const created = [];
const revoked = [];
const registry = module.createPlaymeshResourceObjectUrlRegistry({
  createObjectURL: blob => {
    const url = `blob:fixture-${created.length}`;
    created.push({ blob, url });
    return url;
  },
  revokeObjectURL: url => revoked.push(url),
});
const hashA = 'a'.repeat(64);
const imageA = new Blob(['image-a'], { type: 'image/png' });
const firstUrl = registry.acquire({
  logicalUrl: 'playmesh-local-resource://one/image.png',
  blob: imageA,
  contentHash: hashA,
});
const sameContentUrl = registry.acquire({
  logicalUrl: 'playmesh-local-resource://two/copy.png',
  blob: new Blob(['image-a'], { type: 'image/png' }),
  contentHash: hashA,
});
assert.notEqual(
  sameContentUrl,
  firstUrl,
  'different logical resources must not collapse to one reverse-mapping URL'
);
assert.equal(created.length, 2);
assert.deepEqual(revoked, []);

const sameLogicalResourceUrl = registry.acquire({
  logicalUrl: 'playmesh-local-resource://one/image.png',
  blob: new Blob(['image-a'], { type: 'image/png' }),
  contentHash: hashA,
});
assert.equal(sameLogicalResourceUrl, firstUrl);
assert.equal(created.length, 2);

const replacementUrl = registry.acquire({
  logicalUrl: 'playmesh-local-resource://one/image.png',
  blob: new Blob(['image-b'], { type: 'image/png' }),
  contentHash: 'b'.repeat(64),
});
assert.notEqual(replacementUrl, firstUrl);
assert.equal(created.length, 3);
// Save, preview, tab changes and resource reloads do not call dispose, so both
// the old asynchronous consumer and the replacement remain fetchable.
assert.deepEqual(revoked, []);

registry.dispose();
assert.deepEqual(
  revoked.sort(),
  [firstUrl, sameContentUrl, replacementUrl].sort()
);

process.stdout.write('Resource object URL lifetime contract passed.\n');
