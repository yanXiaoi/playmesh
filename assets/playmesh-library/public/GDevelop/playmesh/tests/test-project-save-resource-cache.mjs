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
let ownedObjectUrlSequence = 0;
const ownedBlobs = new Map();
globalThis.__playmeshTestResourceRegistry = {
  acquire: resource => {
    const ownedObjectUrl = `blob:playmesh-owned-${++ownedObjectUrlSequence}`;
    ownedBlobs.set(ownedObjectUrl, resource.blob);
    return ownedObjectUrl;
  },
  owns: url => ownedBlobs.has(url),
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
    `const PlaymeshGameManifest = { isValidNewProjectGameId: () => true };`
  )
  .replace(
    "import { sha256Blob } from '../../PlaymeshCrypto/PlaymeshSha256';",
    'const sha256Blob = globalThis.__playmeshTestSha256Blob;'
  )
  .replace(
    "import { playmeshResourceObjectUrlRegistry } from './PlaymeshResourceObjectUrlRegistry';",
    'const playmeshResourceObjectUrlRegistry = globalThis.__playmeshTestResourceRegistry;'
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshProjectFiles';/,
    `const PLAYMESH_GDEVELOP_ROOT_PROJECT_FILE = 'game.json';
const splitPlaymeshProject = project => [{ path: 'game.json', content: project }];
const unsplitPlaymeshProject = async files => files[0].content;`
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
  serializedProject: { properties: {}, resources: [{ file: url }] },
  setFolderProject(value) {
    this.serializedProject.properties.folderProject = value;
  },
  getResourcesManager: () => ({
    getAllResourceNames: () => ({ toJSArray: () => ['sprite'] }),
    getResource: () => ({ getFile: () => url }),
  }),
});
const fileMetadata = { fileIdentifier: 'cache-project' };

const newResourceBlob = new CountingBlob(['unchanged'], {
  type: 'application/octet-stream',
});
const fetchableBlobs = new Map([[objectUrl, newResourceBlob]]);
let fetchCalls = 0;
globalThis.fetch = async url => {
  fetchCalls += 1;
  const blob = fetchableBlobs.get(url);
  assert.ok(blob, `unexpected Blob URL fetch: ${url}`);
  return {
    ok: true,
    blob: async () => blob,
  };
};

const firstProject = makeProject(objectUrl);
const firstSnapshot = await projectSerializer.createProjectSnapshot(
  firstProject,
  fileMetadata
);
assert.equal(
  firstSnapshot.projectFiles[0].content.properties.folderProject,
  true,
  'serializer must force the official folder-project flag before serialization'
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
const restoredContent = projectSerializer.restoreStoredResources(
  { resources: [{ file: restoredLogicalUrl }] },
  [restoredResource]
);
const restoredObjectUrl = restoredContent.resources[0].file;
assert.equal(
  globalThis.__playmeshTestResourceRegistry.owns(restoredObjectUrl),
  true
);
const restoredSnapshot = await projectSerializer.createProjectSnapshot(
  makeProject(restoredObjectUrl),
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

globalThis.__playmeshTestAdoptResourceBlob =
  projectSerializer.adoptPlaymeshLocalResourceBlob;
globalThis.__playmeshTestDownloadBlobs = fetchableBlobs;
let localResourceFetcherSource = await readOverlay(
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshLocalResourceFetcher.js'
);
localResourceFetcherSource = localResourceFetcherSource
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/ResourceFetcher';/,
    ''
  )
  .replace(
    "import { isBlobURL } from '../../ResourcesList/ResourceUtils';",
    "const isBlobURL = value => typeof value === 'string' && value.startsWith('blob:');"
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/\.\.\/Utils\/BlobDownloader';/,
    `const downloadUrlsToBlobs = async ({ urlContainers }) =>
  urlContainers.map(item => ({
    item,
    blob: globalThis.__playmeshTestDownloadBlobs.get(item.url) || null,
    error: null,
  }));`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshProjectSerializer';/,
    'const adoptPlaymeshLocalResourceBlob = globalThis.__playmeshTestAdoptResourceBlob;'
  )
  .replace(
    "import { playmeshResourceObjectUrlRegistry } from './PlaymeshResourceObjectUrlRegistry';",
    'const playmeshResourceObjectUrlRegistry = globalThis.__playmeshTestResourceRegistry;'
  );
const localResourceFetcher = await importSource(
  transformFlow(localResourceFetcherSource)
);

const temporaryEditorUrl = 'blob:external-editor-temporary';
const temporaryEditorBlob = new CountingBlob(['external-editor-frame'], {
  type: 'image/png',
});
fetchableBlobs.set(temporaryEditorUrl, temporaryEditorBlob);
const liveResource = {
  file: temporaryEditorUrl,
  getName: () => 'external-editor-frame.png',
  getFile() {
    return this.file;
  },
  setFile(url) {
    this.file = url;
  },
};
const interleavedProject = {
  ...makeProject(temporaryEditorUrl),
  getResourcesManager: () => ({
    getAllResourceNames: () => ({
      toJSArray: () => ['external-editor-frame.png'],
    }),
    getResource: () => liveResource,
  }),
};

// Reproduce the real race: save sees the temporary Blob first and registers
// its logical identity, then the official external-editor fetch step runs.
await projectSerializer.createProjectSnapshot(interleavedProject, fileMetadata);
assert.equal(
  globalThis.__playmeshTestResourceRegistry.owns(temporaryEditorUrl),
  false,
  'snapshot bookkeeping must not turn an editor-owned Blob URL into a stable URL'
);
const fetchResult = await localResourceFetcher.fetchPlaymeshLocalResources({
  project: interleavedProject,
  fileMetadata,
  onProgress: () => {},
});
assert.deepEqual(fetchResult.erroredResources, []);
assert.notEqual(liveResource.file, temporaryEditorUrl);
assert.equal(
  projectSerializer.getPlaymeshLogicalResourceUrl(temporaryEditorUrl),
  null,
  'adopting a temporary URL must release snapshot-only reverse mappings'
);
assert.equal(
  globalThis.__playmeshTestResourceRegistry.owns(liveResource.file),
  true,
  'the official fetch seam must replace a temporary URL even after a save snapshot'
);
fetchableBlobs.delete(temporaryEditorUrl);
assert.equal(
  ownedBlobs.get(liveResource.file),
  temporaryEditorBlob,
  'revoking the temporary editor URL must not invalidate the adopted resource'
);

process.stdout.write('GDevelop save resource cache tests passed.\n');
