import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshProjectImport/PlaymeshPortableProjectImporter.js'
);
const rawSource = await readFile(sourcePath, 'utf8');
assert.doesNotMatch(
  rawSource,
  /PlaymeshPortableImportJournal|journalStore|recoverPendingImports|browserPrepared|BROWSER_PREPARED/
);

class PlaymeshProjectImportError extends Error {
  constructor(code, message, details = null) {
    super(message);
    this.code = code;
    this.details = details;
  }
}

const importedNames = `
const openPlaymeshPortableZip = null;
const getPortableResourceMimeType = null;
const parsePortableProjectJson = null;
const planPortableProjectResources = null;
const resolvePortableImportLimits = null;
const playmeshPortableImportAllocationClient = null;
const createProjectSnapshot = null;
const persistRestoredProject = null;
const ensureGDevelopGameId = null;
const generateCopiedGDevelopGameId = null;
const isUnassignedGDevelopGameId = null;
const createPlaymeshProjectAllocationEvidence = globalThis.__portableAllocationEvidence;
const PlaymeshProjectImportError = globalThis.__portableImporterError;
`;
const executableSource = `${importedNames}${rawSource
  .replace(/^\/\/ @flow\s*/, '')
  .replace(/import[\s\S]*?from\s+['"][^'"]+['"];\s*/g, '')}`;
globalThis.__portableImporterError = PlaymeshProjectImportError;
globalThis.__portableAllocationEvidence = async ({ projectJson, resources }) => {
  const canonicalize = value => {
    if (Array.isArray(value)) return value.map(canonicalize);
    if (value && typeof value === 'object') {
      return Object.keys(value)
        .sort()
        .reduce((result, key) => {
          result[key] = canonicalize(value[key]);
          return result;
        }, {});
    }
    return value;
  };
  const resourcePlan = resources.map(resource => ({
    logicalId: String(resource.logicalUrl || ''),
    name: String(resource.name || resource.logicalUrl || ''),
    contentHash: String(resource.contentHash || ''),
    mime: resource.blob.type || 'application/octet-stream',
    size: resource.blob.size,
    ...(resource.metadata ? { metadata: { ...resource.metadata } } : {}),
  }));
  const digest = async value =>
    Buffer.from(
      await webcrypto.subtle.digest(
        'SHA-256',
        typeof value === 'string'
          ? new TextEncoder().encode(value)
          : await value.arrayBuffer()
      )
    ).toString('hex');
  return {
    projectJsonHash: await digest(projectJson),
    resourceManifestHash: await digest(
      JSON.stringify(canonicalize(resourcePlan))
    ),
    resourcePlan,
  };
};
const importer = await import(`data:text/javascript;base64,${Buffer.from(
  executableSource
).toString('base64')}`);
delete globalThis.__portableImporterError;
delete globalThis.__portableAllocationEvidence;

const sha256 = bytes =>
  createHash('sha256')
    .update(bytes)
    .digest('hex');
const resourceBytes = new TextEncoder().encode('hero-image');
const resourceHash = sha256(resourceBytes);
const archiveBlob = new Blob(['portable fixture']);

const createHarness = ({
  sourcePackageName = 'com.example.original',
  sourceProjectName = 'Imported fixture',
  prepareConflict = false,
  workspaceFailure = false,
  commitMode = 'recover',
  persistFailure = false,
  snapshotFailure = false,
} = {}) => {
  const events = [];
  const calls = [];
  const localProjects = new Map();
  const archiveReads = [];
  let serverPhase = 'NOT_FOUND';
  let resetCount = 0;
  let projectDeleteCount = 0;
  let archiveCloseCount = 0;
  let uuidIndex = 0;

  const resource = {
    file: 'assets/hero.png',
    getFile() {
      return this.file;
    },
    setFile(value) {
      this.file = value;
    },
    getKind: () => 'image',
  };
  const project = {
    name: sourceProjectName,
    packageName: sourcePackageName,
    projectUuid: 'source-project-uuid',
    getName() {
      return this.name;
    },
    getPackageName() {
      return this.packageName;
    },
    setPackageName(value) {
      this.packageName = value;
    },
    getProjectUuid() {
      return this.projectUuid;
    },
    resetProjectUuid() {
      resetCount++;
      this.projectUuid = `copied-project-uuid-${resetCount}`;
    },
    getResourcesManager: () => ({
      getAllResourceNames: () => ({ toJSArray: () => ['Hero'] }),
      getResource: name => (name === 'Hero' ? resource : null),
    }),
    unserializeFrom: () => {},
    delete() {
      projectDeleteCount++;
    },
  };

  const state = phase => ({
    phase,
    transactionId:
      phase === 'NOT_FOUND' || phase === 'CONFLICT' ? null : 'allocation-tx-1',
    ...(phase === 'CONFLICT'
      ? {
          conflict: {
            reason: 'target_became_occupied',
            observedAt: '2026-08-05T00:00:00.000Z',
          },
        }
      : {}),
  });
  const record = (method, input, extra = null) => {
    events.push(`allocation-${method}`);
    calls.push({ method, input, extra });
  };

  const allocationClient = {
    prepare: async input => {
      record('prepare', input);
      if (prepareConflict) return state('CONFLICT');
      serverPhase = 'PREPARED';
      return state(serverPhase);
    },
    getStatus: async input => {
      record('status', input);
      return state(serverPhase);
    },
    resourcePresence: async (input, resources) => {
      record('presence', input, resources);
      if (workspaceFailure) throw new Error('presence failed');
      return {
        ...state('PREPARED'),
        missing: [{ hash: resourceHash, bytes: resourceBytes.length }],
        available: [],
      };
    },
    uploadResource: async (input, upload) => {
      record('resource-put', input, upload);
      assert.equal(upload.contentHash, resourceHash);
      assert.deepEqual(
        new Uint8Array(await upload.blob.arrayBuffer()),
        resourceBytes
      );
      return { hash: resourceHash, bytes: resourceBytes.length };
    },
    uploadProject: async (input, projectJson) => {
      record('project-put', input, projectJson);
      return {
        contentHash: sha256(projectJson),
        size: Buffer.byteLength(projectJson),
      };
    },
    finalizeWorkspace: async (input, evidence) => {
      record('finalize', input, evidence);
      serverPhase = 'WORKSPACE_FINALIZED';
      return state(serverPhase);
    },
    commit: async input => {
      record('commit', input);
      if (commitMode === 'lost-committed') {
        serverPhase = 'COMMITTED';
        throw new Error('commit response lost');
      }
      if (commitMode === 'conflict') {
        serverPhase = 'CONFLICT';
        return state(serverPhase);
      }
      serverPhase = 'COMMIT_REQUESTED';
      return state(serverPhase);
    },
    recover: async input => {
      record('recover', input);
      if (commitMode === 'pending') throw new Error('still pending');
      serverPhase = 'COMMITTED';
      return state(serverPhase);
    },
    abort: async input => {
      record('abort', input);
      serverPhase = 'ABORTED';
      return state(serverPhase);
    },
  };

  const portableImporter = importer.createPlaymeshPortableProjectImporter({
    openArchive: async () => ({
      inspectedArchive: {},
      readBlob: async ({ path: archivePath }) => {
        archiveReads.push(archivePath);
        return archivePath === 'game.json'
          ? new Blob([
              JSON.stringify({
                properties: {
                  name: sourceProjectName,
                  packageName: sourcePackageName,
                  projectUuid: 'source-project-uuid',
                },
              }),
            ])
          : new Blob([resourceBytes], { type: 'image/png' });
      },
      close: async () => {
        archiveCloseCount++;
      },
    }),
    parseProjectJson: bytes => JSON.parse(new TextDecoder().decode(bytes)),
    planResources: () => ({
      localFiles: [
        {
          path: 'assets/hero.png',
          resources: [{ name: 'Hero' }],
        },
      ],
    }),
    resolveLimits: () => ({
      maxProjectJsonBytes: 1024 * 1024,
      maxSingleResourceBytes: 1024 * 1024,
    }),
    mimeTypeForPath: () => 'image/png',
    createSnapshot: async currentProject => {
      events.push('snapshot');
      if (snapshotFailure) throw new Error('snapshot failed');
      const logicalUrl = 'playmesh-local-resource://fixture/hero.png';
      return {
        project: {
          properties: {
            name: currentProject.getName(),
            packageName: currentProject.getPackageName(),
            projectUuid: currentProject.getProjectUuid(),
          },
          resources: {
            resources: [{ name: 'Hero', file: logicalUrl }],
          },
        },
        resources: [
          {
            logicalUrl,
            name: 'Hero',
            blob: new Blob([resourceBytes], { type: 'image/png' }),
            contentHash: resourceHash,
            metadata: { z: 1, a: true },
          },
        ],
      };
    },
    persistSnapshot: async ({
      fileMetadata,
      project: projectObject,
      resources,
    }) => {
      events.push('local-persist');
      if (persistFailure) throw new Error('IndexedDB unavailable');
      localProjects.set(fileMetadata.fileIdentifier, {
        id: fileMetadata.fileIdentifier,
        gameId: fileMetadata.gameId,
        projectJson: JSON.stringify(projectObject),
        resources,
      });
    },
    ensureGameId: currentProject => {
      const value = currentProject.getPackageName();
      if (!/^com\.[a-z0-9.-]+$/.test(value)) throw new Error('invalid game id');
      return value;
    },
    generateGameId: () => 'com.playmesh.game.generated',
    isUnassignedGameId: value => value === 'com.example.gamename',
    allocationClient,
    cryptoImplementation: {
      subtle: webcrypto.subtle,
      randomUUID: () => `fixture-id-${++uuidIndex}`,
    },
    gdImplementation: {
      ProjectHelper: { createNewGDJSProject: () => project },
      Serializer: {
        fromJSObject: value => ({ value, delete: () => {} }),
      },
    },
    createObjectURL: () => 'blob:fixture-resource',
    revokeObjectURL: () => events.push('url-revoke'),
  });

  return {
    portableImporter,
    allocationClient,
    calls,
    events,
    localProjects,
    archiveReads,
    get resetCount() {
      return resetCount;
    },
    get projectDeleteCount() {
      return projectDeleteCount;
    },
    get archiveCloseCount() {
      return archiveCloseCount;
    },
  };
};

{
  const harness = createHarness();
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'imported');
  assert.equal(result.cacheStatus, 'mirrored');
  assert.equal(result.identityMode, 'preserve');
  assert.equal(result.packageName, 'com.example.original');
  assert.equal(result.projectUuid, 'source-project-uuid');
  assert.equal(harness.localProjects.size, 1);
  assert.deepEqual(harness.archiveReads, ['game.json', 'assets/hero.png']);
  assert.equal(harness.projectDeleteCount, 1);
  assert.equal(harness.archiveCloseCount, 1);
  assert.ok(
    harness.events.indexOf('allocation-recover') <
      harness.events.indexOf('local-persist'),
    'App COMMITTED must precede IndexedDB mirroring'
  );
  assert.deepEqual(harness.calls.map(call => call.method), [
    'prepare',
    'presence',
    'resource-put',
    'project-put',
    'finalize',
    'commit',
    'recover',
  ]);
  const target = harness.calls[0].input.target;
  assert.deepEqual(Object.keys(target).sort(), [
    'fileIdentifier',
    'gameId',
    'packageName',
    'projectJsonHash',
    'projectUuid',
    'resourceManifestHash',
  ]);
  assert.equal(target.projectUuid, 'source-project-uuid');
  const plan = harness.calls[1].extra;
  assert.deepEqual(plan.map(item => item.logicalId), [
    'playmesh-local-resource://fixture/hero.png',
  ]);
  assert.deepEqual(Object.keys(plan[0]), [
    'logicalId',
    'name',
    'contentHash',
    'mime',
    'size',
    'metadata',
  ]);
}

{
  const harness = createHarness({ prepareConflict: true });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'needsNewPackageName');
  assert.equal(result.reason, 'allocation_conflict');
  assert.equal(harness.localProjects.size, 0);
  assert.deepEqual(harness.calls.map(call => call.method), ['prepare']);
}

{
  const harness = createHarness();
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    packageName: 'com.example.importedcopy',
    identityMode: 'copy',
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'imported');
  assert.equal(result.identityMode, 'copy');
  assert.equal(result.projectUuid, 'copied-project-uuid-1');
  assert.equal(harness.resetCount, 1);
  assert.equal(harness.calls[0].input.origin, 'copy');
}

{
  const harness = createHarness({ sourcePackageName: 'com.example.gamename' });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.packageName, 'com.playmesh.game.generated');
  assert.equal(result.projectUuid, 'source-project-uuid');
}

{
  const harness = createHarness();
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    packageName: '   ',
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'needsNewPackageName');
  assert.equal(result.reason, 'invalid');
  assert.equal(harness.calls.length, 0);
}

{
  const harness = createHarness({ workspaceFailure: true });
  await assert.rejects(
    harness.portableImporter.importProject({
      archiveBlob,
      allocationClient: harness.allocationClient,
    }),
    error => error.code === 'allocation_workspace_failed'
  );
  assert.deepEqual(harness.calls.map(call => call.method), [
    'prepare',
    'presence',
    'status',
    'abort',
  ]);
  assert.equal(harness.localProjects.size, 0);
}

{
  const harness = createHarness({ commitMode: 'lost-committed' });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'imported');
  assert.equal(harness.calls.some(call => call.method === 'status'), true);
  assert.equal(harness.calls.some(call => call.method === 'abort'), false);
  assert.equal(harness.localProjects.size, 1);
}

{
  const harness = createHarness({ commitMode: 'conflict' });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'needsNewPackageName');
  assert.equal(result.reason, 'allocation_conflict');
  assert.equal(harness.calls.some(call => call.method === 'abort'), true);
  assert.equal(harness.localProjects.size, 0);
}

{
  const harness = createHarness({ commitMode: 'pending' });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'recovering');
  assert.equal(result.reason, 'commit_in_progress');
  assert.equal(harness.localProjects.size, 0);
}

{
  // App 已提交但浏览器缓存完全不可写时，导入仍成功；Provider 会由 current 重建。
  const harness = createHarness({ persistFailure: true });
  const result = await harness.portableImporter.importProject({
    archiveBlob,
    allocationClient: harness.allocationClient,
  });
  assert.equal(result.status, 'imported');
  assert.equal(result.cacheStatus, 'stale');
  assert.equal(harness.localProjects.size, 0);
  assert.equal(harness.calls.at(-1).method, 'recover');
}

{
  const harness = createHarness({ snapshotFailure: true });
  await assert.rejects(
    harness.portableImporter.importProject({
      archiveBlob,
      allocationClient: harness.allocationClient,
    }),
    /snapshot failed/
  );
  assert.equal(harness.calls.length, 0);
  assert.equal(harness.events.includes('url-revoke'), true);
  assert.equal(harness.archiveCloseCount, 1);
}

process.stdout.write('GDevelop portable project importer tests passed.\n');
