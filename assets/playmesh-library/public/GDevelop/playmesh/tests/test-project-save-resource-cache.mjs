import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const dependencyCacheRoot = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/cache/deps'
);
const dependencyCaches = existsSync(dependencyCacheRoot)
  ? await readdir(dependencyCacheRoot)
  : [];
const appPackage = dependencyCaches
  .map(entry => path.join(dependencyCacheRoot, entry, 'package.json'))
  .find(candidate =>
    existsSync(
      path.join(path.dirname(candidate), 'node_modules/@babel/core/package.json')
    )
  );
assert.ok(appPackage, 'the fixed WebIDE Babel dependency cache is required');

const appRequire = createRequire(appPackage);
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const transformFlow = source =>
  transformSync(source, {
    babelrc: false,
    configFile: false,
    plugins: [[flowStripPlugin, { all: true }]],
    sourceType: 'module',
  }).code;
const importSource = async source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const readOverlay = relativePath =>
  readFile(
    path.resolve(testDirectory, '../overlays/newIDE/app/src', relativePath),
    'utf8'
  );

globalThis.window = { crypto: webcrypto };

const sha256 = await importSource(
  transformFlow(await readOverlay('PlaymeshCrypto/PlaymeshSha256.js'))
);
globalThis.__playmeshTestSha256Blob = sha256.sha256Blob;
globalThis.__playmeshTestSha256Hex = sha256.sha256Hex;

let historyEvidenceSource = await readOverlay(
  'PlaymeshHistory/PlaymeshHistoryEvidence.js'
);
historyEvidenceSource = historyEvidenceSource
  .replace(
    /import type \{[\s\S]*?\} from '\.\.\/ProjectsStorage\/PlaymeshLocalStorageProvider\/PlaymeshProjectStore';/,
    ''
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
    `const assertPlaymeshHistoryRestoreBrowserEvidence = value => value;
const assertPlaymeshHistoryRestoreResource = value => value;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/PlaymeshCrypto\/PlaymeshSha256';/,
    `const sha256Blob = globalThis.__playmeshTestSha256Blob;
const sha256Hex = globalThis.__playmeshTestSha256Hex;`
  )
  .replace(
    /import type \{[\s\S]*?\} from '\.\/PlaymeshHistoryRestoreProtocol';/,
    ''
  );
const historyEvidence = await importSource(transformFlow(historyEvidenceSource));

const objectUrl = 'blob:save-cache-fixture';
globalThis.__playmeshTestResourceRegistry = {
  acquire: () => objectUrl,
};
let projectSerializerSource = await readOverlay(
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer.js'
);
projectSerializerSource = projectSerializerSource
  .replace(
    "import { serializeToJSObject } from '../../Utils/Serializer';",
    'const serializeToJSObject = project => project.serializedProject;'
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshProjectStore';/,
    `const getStoredProject = async () => null;
const putStoredProject = async () => {};`
  )
  .replace("import { type FileMetadata } from '..';", '')
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/\.\.\/PlaymeshManifest\/PlaymeshGDevelopManifestController';/,
    `const ensureGDevelopGameId = () => 'com.playmesh.game.cachetest';
const isUnassignedGDevelopGameId = () => false;`
  )
  .replace(
    "import PlaymeshGameManifest from '../../PlaymeshShared/GameManifest';",
    `const PlaymeshGameManifest = { isAndroidPackageName: () => true };`
  )
  .replace(
    "import { sha256Blob } from '../../PlaymeshCrypto/PlaymeshSha256';",
    'const sha256Blob = globalThis.__playmeshTestSha256Blob;'
  )
  .replace(
    "import { playmeshResourceObjectUrlRegistry } from './PlaymeshResourceObjectUrlRegistry';",
    'const playmeshResourceObjectUrlRegistry = globalThis.__playmeshTestResourceRegistry;'
  );
const projectSerializer = await importSource(
  transformFlow(projectSerializerSource)
);

class CountingBlob extends Blob {
  constructor(parts, options) {
    super(parts, options);
    this.arrayBufferCalls = 0;
  }

  async arrayBuffer() {
    this.arrayBufferCalls += 1;
    return Blob.prototype.arrayBuffer.call(this);
  }
}

const hashText = value => createHash('sha256').update(value).digest('hex');
const makeProject = url => ({
  serializedProject: { resources: [{ file: url }] },
  getResourcesManager: () => ({
    getAllResourceNames: () => ({ toJSArray: () => ['sprite'] }),
    getResource: () => ({ getFile: () => url }),
  }),
});
const fileMetadata = { fileIdentifier: 'cache-project' };

const newResourceBlob = new CountingBlob(['unchanged'], {
  type: 'application/octet-stream',
});
let fetchCalls = 0;
globalThis.fetch = async url => {
  fetchCalls += 1;
  assert.equal(url, objectUrl);
  return {
    ok: true,
    blob: async () => newResourceBlob,
  };
};

const firstSnapshot = await projectSerializer.createProjectSnapshot(
  makeProject(objectUrl),
  fileMetadata
);
const secondSnapshot = await projectSerializer.createProjectSnapshot(
  makeProject(objectUrl),
  fileMetadata
);
await historyEvidence.createPlaymeshHistoryResourceDto(
  secondSnapshot.resources[0]
);
assert.equal(fetchCalls, 1, 'an unchanged registered object URL is fetched once');
assert.equal(
  newResourceBlob.arrayBufferCalls,
  1,
  'serializer and history verification share one digest of an immutable Blob'
);
assert.equal(firstSnapshot.resources[0].blob, newResourceBlob);
assert.equal(secondSnapshot.resources[0].blob, newResourceBlob);

const restoredBlob = new CountingBlob(['restored'], { type: 'image/png' });
const restoredLogicalUrl = 'playmesh-local-resource://restored/sprite.png';
const restoredResource = {
  logicalUrl: restoredLogicalUrl,
  name: 'sprite',
  blob: restoredBlob,
  contentHash: hashText('restored'),
};
projectSerializer.restoreStoredResources(
  { resources: [{ file: restoredLogicalUrl }] },
  [restoredResource]
);
const restoredSnapshot = await projectSerializer.createProjectSnapshot(
  makeProject(objectUrl),
  fileMetadata
);
assert.equal(fetchCalls, 1, 'a restored registered Blob is not fetched again');
assert.equal(restoredSnapshot.resources[0].blob, restoredBlob);
await historyEvidence.createPlaymeshHistoryResourceDto(
  restoredSnapshot.resources[0]
);
await historyEvidence.createPlaymeshHistoryResourceDto(
  restoredSnapshot.resources[0]
);
assert.equal(
  restoredBlob.arrayBufferCalls,
  1,
  'strict history verification hashes a restored immutable Blob once'
);

const changedBlob = new CountingBlob(['changed'], { type: 'image/png' });
const changedDto = await historyEvidence.createPlaymeshHistoryResourceDto({
  logicalUrl: restoredLogicalUrl,
  blob: changedBlob,
  contentHash: hashText('changed'),
});
assert.equal(changedDto.contentHash, hashText('changed'));
assert.equal(
  changedBlob.arrayBufferCalls,
  1,
  'a replacement Blob has a distinct cache identity and is validated'
);

const corruptBlob = new CountingBlob(['corrupt'], { type: 'image/png' });
await assert.rejects(
  historyEvidence.createPlaymeshHistoryResourceDto({
    logicalUrl: restoredLogicalUrl,
    blob: corruptBlob,
    contentHash: hashText('different'),
  }),
  error => error.code === 'resource_corrupt',
  'cached hashing must not bypass the declared contentHash check'
);
assert.equal(corruptBlob.arrayBufferCalls, 1);

class FlakyBlob extends Blob {
  constructor(parts) {
    super(parts);
    this.arrayBufferCalls = 0;
  }

  async arrayBuffer() {
    this.arrayBufferCalls += 1;
    if (this.arrayBufferCalls === 1) throw new Error('transient read failure');
    return Blob.prototype.arrayBuffer.call(this);
  }
}
const flakyBlob = new FlakyBlob(['retry']);
await assert.rejects(sha256.sha256Blob(flakyBlob), /transient read failure/);
assert.equal(await sha256.sha256Blob(flakyBlob), hashText('retry'));
assert.equal(
  flakyBlob.arrayBufferCalls,
  2,
  'a rejected digest is evicted so a later save can retry'
);

process.stdout.write('GDevelop save resource cache tests passed.\n');
