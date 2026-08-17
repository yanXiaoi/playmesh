import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshRoot = path.resolve(testDirectory, '..');
const readOverlay = relativePath =>
  readFile(
    path.join(playmeshRoot, 'overlays/newIDE/app/src', relativePath),
    'utf8'
  );

const importSource = source =>
  import(
    `data:text/javascript;base64,${Buffer.from(source, 'utf8').toString(
      'base64'
    )}`
  );

const platformSource = await readOverlay(
  'PlaymeshShared/PlaymeshGDevelopPlatform.js'
);
const platformModule = await importSource(platformSource);
let archiveSource = await readOverlay(
  'ProjectsStorage/DownloadFileStorageProvider/PlaymeshDownloadProjectArchive.js'
);

const calls = [];
const archivedBlob = new Blob(['portable-project']);
const archiveFiles = async options => {
  calls.push('archive');
  assert.equal(options.basePath, '/');
  assert.equal(options.textFiles.length, 1);
  assert.equal(options.textFiles[0].filePath, 'game.json');
  assert.deepEqual(JSON.parse(options.textFiles[0].text), {
    properties: { name: 'Fixture copy' },
  });
  assert.equal(options.blobFiles.length, 1);
  assert.equal(options.blobFiles[0].filePath, 'assets/image/player.png');
  assert.equal(options.blobFiles[0].blob instanceof Blob, true);
  return archivedBlob;
};
const serializeToJSObject = () => {
  calls.push('serialize-json');
  return { properties: { name: 'Fixture copy' } };
};
globalThis.__playmeshDownloadArchiveMocks = {
  archiveFiles,
  serializeToJSObject,
  ensureGDevelopJsPlatformIsRegistered:
    platformModule.ensureGDevelopJsPlatformIsRegistered,
};
archiveSource = archiveSource
  .replace(
    /import \{ serializeToJSObject \} from '[^']+';/,
    'const { serializeToJSObject } = globalThis.__playmeshDownloadArchiveMocks;'
  )
  .replace(
    /import \{ archiveFiles \} from '[^']+';/,
    'const { archiveFiles } = globalThis.__playmeshDownloadArchiveMocks;'
  )
  .replace(
    /import \{ ensureGDevelopJsPlatformIsRegistered \} from '[^']+';/,
    'const { ensureGDevelopJsPlatformIsRegistered } = globalThis.__playmeshDownloadArchiveMocks;'
  );
const archiveModule = await importSource(archiveSource);

let platformRegistered = false;
let platformInitializationCount = 0;
let temporaryProjectDeleteCount = 0;
const gdImplementation = {
  initializePlatforms() {
    calls.push('initialize-platform');
    platformRegistered = true;
    platformInitializationCount++;
  },
  ProjectHelper: {
    createNewGDJSProject() {
      calls.push('create-project-copy');
      return {
        unserializeFrom() {
          calls.push('unserialize-project-copy');
          if (!platformRegistered) {
            throw new Error('Platform "GDevelop JS platform" is unknown.');
          }
        },
        delete() {
          calls.push('delete-project-copy');
          temporaryProjectDeleteCount++;
        },
      };
    },
  },
  SerializerElement: class {
    constructor() {
      calls.push('create-serializer');
    }

    delete() {
      calls.push('delete-serializer');
    }
  },
};
const project = {
  serializeTo() {
    calls.push('serialize-project');
  },
};
const downloadResources = async ({ project: projectCopy, onAddBlobFile }) => {
  assert.ok(projectCopy);
  calls.push('download-resources');
  onAddBlobFile({
    filePath: 'assets/image/player.png',
    blob: new Blob([new Uint8Array([1, 2, 3])]),
  });
};

const result = await archiveModule.createPlaymeshDownloadProjectArchive({
  project,
  downloadResources,
  gdImplementation,
  archiveImplementation: archiveFiles,
  serializeImplementation: serializeToJSObject,
});
assert.equal(result, archivedBlob);
assert.deepEqual(calls, [
  'initialize-platform',
  'create-project-copy',
  'create-serializer',
  'serialize-project',
  'unserialize-project-copy',
  'delete-serializer',
  'download-resources',
  'serialize-json',
  'archive',
  'delete-project-copy',
]);
assert.equal(platformInitializationCount, 1);
assert.equal(temporaryProjectDeleteCount, 1);

calls.length = 0;
await archiveModule.createPlaymeshDownloadProjectArchive({
  project,
  downloadResources,
  gdImplementation,
  archiveImplementation: archiveFiles,
  serializeImplementation: serializeToJSObject,
});
assert.equal(platformInitializationCount, 1, 'native platform initialization is once per libGD instance');
assert.equal(calls.includes('initialize-platform'), false);
assert.equal(temporaryProjectDeleteCount, 2);

const startupPolicy = await readFile(
  path.join(playmeshRoot, 'scripts/apply-source-policy.mjs'),
  'utf8'
);
assert.match(
  startupPolicy,
  /ensureGDevelopJsPlatformIsRegistered\(gd\);\s*\n\s*global\.gd = gd;/,
  'startup must register the platform before publishing libGD or importing BrowserApp'
);
assert.match(startupPolicy, /createPlaymeshDownloadProjectArchive/);
assert.doesNotMatch(
  startupPolicy,
  /DownloadFileSaveAsDialog[\s\S]{0,12000}gd\.initializePlatforms\(/,
  'download UI must use the shared archive boundary, not initialize native state ad hoc'
);
assert.match(
  startupPolicy,
  /openBlobDownloadUrl|BlobDownloadUrlHolder/,
  'the completed archive must stay on the browser/native save bridge path'
);

console.log('GDevelop downloadable project archive tests passed.');
