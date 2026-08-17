import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const execFileAsync = promisify(execFile);
const importerPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshCatalog/PlaymeshExampleImporter.js'
);
let source = await readFile(importerPath, 'utf8');
const platformHelperSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshShared/PlaymeshGDevelopPlatform.js'
  ),
  'utf8'
);
const platformHelper = await import(
  `data:text/javascript;base64,${Buffer.from(platformHelperSource).toString(
    'base64'
  )}`
);
const allocationCoordinatorSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjects/PlaymeshProjectAllocationCoordinator.js'
  ),
  'utf8'
);
const allocationCoordinator = await import(
  `data:text/javascript;base64,${Buffer.from(`
const playmeshPortableImportAllocationClient = null;
const computeSha256Hex = async (bytes, cryptoImplementation) =>
  Array.from(
    new Uint8Array(await cryptoImplementation.subtle.digest('SHA-256', bytes))
  )
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
${allocationCoordinatorSource
  .replace(/^\/\/ @flow\s*/, '')
  .replace(/import[\s\S]*?from\s+['"][^'"]+['"];\s*/g, '')}
`).toString('base64')}`
);

const removeFlowTypeDeclarations = value => {
  let result = value;
  const declaration = /^(?:export\s+)?type\s+[A-Za-z_$][A-Za-z0-9_$]*/m;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    let quote = null;
    let escaped = false;
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = match.index;
    for (; end < result.length; end++) {
      const character = result[end];
      if (quote) {
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === "'" || character === '"') {
        quote = character;
        continue;
      }
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        character === ';' &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        end++;
        break;
      }
    }
    result = result.slice(0, match.index) + result.slice(end);
  }
};

const removeFlowVariableAnnotations = value => {
  const declaration = /\b(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*:/g;
  let result = value;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    const colon = result.indexOf(':', match.index);
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = colon + 1;
    for (; end < result.length; end++) {
      const character = result[end];
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        (character === '=' || character === ';') &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        break;
      }
    }
    result = result.slice(0, colon) + result.slice(end);
    declaration.lastIndex = colon;
  }
};

const stripCatalogFlowTypes = value => {
  let result = value
    .replace(/^\/\/ @flow\s*/, '')
    .replace(/import type[\s\S]*?;\s*/g, '')
    .replace(/\/\*::[\s\S]*?\*\//g, '');
  result = removeFlowTypeDeclarations(result);
  result = removeFlowVariableAnnotations(result);
  return result
    .replace(/\bnew Promise<[^>]+>/g, 'new Promise')
    .replace(/\(([A-Za-z_$][A-Za-z0-9_$]*):\s*any\)/g, '$1')
    .replace(
      /([A-Za-z_$][A-Za-z0-9_$]*)\??\s*:\s*\??(?:mixed|string|number|boolean|void|libGDevelop|[A-Z$][A-Za-z0-9_$]*)(?:<[^\n()]*?>)?(?:\s*\|\s*(?:mixed|string|number|boolean|void|libGDevelop|[A-Z$][A-Za-z0-9_$]*)(?:<[^\n()]*?>)?)*(?=\s*[,)=])/g,
      '$1'
    )
    .replace(
      /}\s*:\s*(?:\{\|[\s\S]*?\|}|[A-Za-z_$][A-Za-z0-9_$]*(?:<[^\n()]*?>)?)\s*\)/g,
      '})'
    )
    .replace(
      /\)\s*:\s*\??[A-Za-z_$][A-Za-z0-9_$]*(?:<[^;{}]*?>)?(?:\s*\|\s*\??[A-Za-z_$][A-Za-z0-9_$]*(?:<[^;{}]*?>)?)*\s*=>/g,
      ') =>'
    )
    .replace(
      /\)\s*:\s*\?\{[^}\n]+\}\s*=>/g,
      ') =>'
    );
};

source = stripCatalogFlowTypes(source);
const remainingFlowType = source.match(
  /import type|export type|^type\s|new Promise<|:\s*(?:mixed|string|number|boolean|void|libGDevelop|Promise<|Array<|Map<|Set<|PlaymeshCatalog|PlaymeshExample|StoredProject|FileMetadata)/m
);
if (remainingFlowType) {
  throw new Error(
    source.slice(
      Math.max(0, remainingFlowType.index - 80),
      remainingFlowType.index + 160
    )
  );
}

class PlaymeshCatalogError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const sha256Hex = async bytes => {
  const digest = await webcrypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
};

const state = {
  activeDownloads: 0,
  maximumActiveDownloads: 0,
  clearCount: 0,
  projectAllocations: [],
  staging: new Map(),
  failStagingArtifactKey: null,
  failGDevelopValidation: false,
  platformInitializationCount: 0,
  validationEvents: [],
  allocationError: null,
  bodies: new Map(),
  exampleManifest: null,
};

const mocks = {
  allocatePlaymeshProjectSnapshot: async input => {
    if (state.allocationError) throw state.allocationError;
    await allocationCoordinator.createPlaymeshProjectAllocationEvidence({
      projectJson: JSON.stringify(input.snapshot.project),
      resources: input.snapshot.resources,
      cryptoImplementation: webcrypto,
    });
    state.projectAllocations.push(input);
  },
  beginCatalogStaging: async () => {},
  cleanupExpiredCatalogStaging: async () => {},
  clearCatalogStaging: async sessionId => {
    state.clearCount++;
    for (const key of [...state.staging.keys()]) {
      if (key.startsWith(`${sessionId}:`)) state.staging.delete(key);
    }
  },
  getCatalogStagedArtifact: async (sessionId, artifactKey) =>
    state.staging.get(`${sessionId}:${artifactKey}`) || null,
  putCatalogStagedArtifact: async ({
    sessionId,
    artifactKey,
    blob,
    metadata,
  }) => {
    if (artifactKey === state.failStagingArtifactKey) {
      throw new DOMException('Quota exceeded.', 'QuotaExceededError');
    }
    state.staging.set(`${sessionId}:${artifactKey}`, { blob, metadata });
  },
  PlaymeshCatalogError,
  sha256Hex,
  getPlaymeshExampleManifest: async () => ({
    manifest: {
      limits: {
        downloadConcurrency: 2,
        exampleTotalBytes: 256 * 1024 * 1024,
      },
    },
    exampleManifest: state.exampleManifest,
  }),
  fetchPlaymeshArtifact: async ({ artifact, signal }) => {
    if (signal && signal.aborted) {
      throw new PlaymeshCatalogError('cancelled', '示例导入已取消。');
    }
    state.activeDownloads++;
    state.maximumActiveDownloads = Math.max(
      state.maximumActiveDownloads,
      state.activeDownloads
    );
    try {
      await new Promise(resolve => setTimeout(resolve, 2));
      const bytes = state.bodies.get(artifact.id);
      if (!bytes) throw new Error('Missing fixture body.');
      return {
        bytes,
        contentHash: await sha256Hex(bytes),
        mediaType: artifact.mediaType,
      };
    } finally {
      state.activeDownloads--;
    }
  },
  generateCopiedGDevelopGameId: () => 'com.playmesh.game.gimport00001',
  ensureGDevelopJsPlatformIsRegistered:
    platformHelper.ensureGDevelopJsPlatformIsRegistered,
  sanitizePlaymeshExternalUrl: value =>
    typeof value === 'string' && /^https?:\/\//.test(value) ? value : '',
};

globalThis.__playmeshExampleImporterMocks = mocks;
source = source
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshCatalogCache';/,
    `const {
  beginCatalogStaging,
  cleanupExpiredCatalogStaging,
  clearCatalogStaging,
  getCatalogStagedArtifact,
  putCatalogStagedArtifact,
} = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshCatalogRuntime';/,
    `const {
  PlaymeshCatalogError,
  sha256Hex,
} = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshCatalogSource';/,
    `const {
  fetchPlaymeshArtifact,
    getPlaymeshExampleManifest,
} = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{ generateCopiedGDevelopGameId \} from '[^']+';/,
    `const { generateCopiedGDevelopGameId } = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{ allocatePlaymeshProjectSnapshot \} from '[^']+';/,
    `const { allocatePlaymeshProjectSnapshot } = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{ ensureGDevelopJsPlatformIsRegistered as ensurePlaymeshGDevelopJsPlatformIsRegistered \} from '[^']+';/,
    `const { ensureGDevelopJsPlatformIsRegistered: ensurePlaymeshGDevelopJsPlatformIsRegistered } = globalThis.__playmeshExampleImporterMocks;`
  )
  .replace(
    /import \{ sanitizePlaymeshExternalUrl \} from '[^']+';/,
    `const { sanitizePlaymeshExternalUrl } = globalThis.__playmeshExampleImporterMocks;`
  );

const importer = await import(`data:text/javascript;base64,${Buffer.from(
  source,
  'utf8'
).toString('base64')}`);

globalThis.window = {
  crypto: webcrypto,
};
globalThis.global.gd = {
  initializePlatforms: () => {
    state.platformInitializationCount++;
    state.validationEvents.push('initialize-platforms');
  },
  ProjectHelper: {
    createNewGDJSProject: () => ({
      unserializeFrom: () => {
        state.validationEvents.push('unserialize-project');
        if (state.failGDevelopValidation) throw new Error('Invalid project');
      },
      getCurrentPlatform: () => ({
        getName: () => 'GDevelop JS platform',
      }),
      delete: () => {},
    }),
  },
  Serializer: {
    fromJSObject: () => ({ delete: () => {} }),
  },
};

const artifactFor = (name, bytes, mediaType) => ({
  id: name,
  declaredBytes: bytes.byteLength,
  mediaType,
});

const licenseFor = status => ({
  status,
  name: status === 'open' ? 'MIT' : 'Fixture terms',
  sourceUrl: 'https://example.invalid/LICENSE',
  evidenceKey: `fixture:${status}:evidence`,
  documents: [],
});

const resetState = () => {
  state.activeDownloads = 0;
  state.maximumActiveDownloads = 0;
  state.clearCount = 0;
  state.projectAllocations = [];
  state.staging.clear();
  state.failStagingArtifactKey = null;
  state.failGDevelopValidation = false;
  state.validationEvents = [];
  state.allocationError = null;
  state.bodies.clear();
};

const installFixture = async () => {
  const resourcePaths = ['images/a.png', 'audio/b.ogg', 'fonts/c.ttf'];
  const projectView = new TextEncoder().encode(
    JSON.stringify({
      properties: { name: 'Original' },
      resources: {
        resources: resourcePaths.map((file, index) => ({
          name: `Resource${index}`,
          file,
        })),
      },
    })
  );
  const projectBytes = projectView.buffer.slice(
    projectView.byteOffset,
    projectView.byteOffset + projectView.byteLength
  );
  const project = artifactFor('project', projectBytes, 'application/json');
  const resources = [];
  for (let index = 0; index < resourcePaths.length; index++) {
    const resourceView = new Uint8Array([index + 1, index + 2, index + 3]);
    const bytes = resourceView.buffer.slice(
      resourceView.byteOffset,
      resourceView.byteOffset + resourceView.byteLength
    );
    const artifact = artifactFor(
      `resource-${index}`,
      bytes,
      'application/octet-stream'
    );
    state.bodies.set(artifact.id, bytes);
    resources.push({
      file: resourcePaths[index],
      name: `Resource${index}`,
      artifact,
    });
  }
  state.bodies.set(project.id, projectBytes);
  state.exampleManifest = {
    schemaVersion: 2,
    id: 'fixture',
    name: '官方示例',
    project,
    projectDownload: {
      bytes: projectBytes,
      contentHash: await sha256Hex(projectBytes),
    },
    resources,
    requestCount: resources.length + 1,
    totalBytes:
      projectBytes.byteLength +
      resources.reduce(
        (total, resource) => total + resource.artifact.declaredBytes,
        0
      ),
    license: licenseFor('open'),
  };
};

const installDuplicateResourceFixture = async () => {
  const sourcePath = 'assets/shared.png';
  const projectView = new TextEncoder().encode(
    JSON.stringify({
      properties: { name: 'Original' },
      resources: {
        resources: [
          { name: 'Shared primary', file: sourcePath },
          { name: 'Shared alias', file: 'assets\\shared.png' },
        ],
      },
    })
  );
  const projectBytes = projectView.buffer.slice(
    projectView.byteOffset,
    projectView.byteOffset + projectView.byteLength
  );
  const resourceView = new Uint8Array([7, 8, 9]);
  const resourceBytes = resourceView.buffer.slice(
    resourceView.byteOffset,
    resourceView.byteOffset + resourceView.byteLength
  );
  const project = artifactFor('project', projectBytes, 'application/json');
  const artifact = artifactFor(
    'resource-shared',
    resourceBytes,
    'image/png'
  );
  state.bodies.set(project.id, projectBytes);
  state.bodies.set(artifact.id, resourceBytes);
  state.exampleManifest = {
    schemaVersion: 2,
    id: 'duplicate-resource-fixture',
    name: '重复资源官方示例',
    project,
    projectDownload: {
      bytes: projectBytes,
      contentHash: await sha256Hex(projectBytes),
    },
    resources: [
      {
        file: sourcePath,
        name: 'Shared primary',
        artifact,
      },
    ],
    requestCount: 2,
    totalBytes: projectBytes.byteLength + resourceBytes.byteLength,
    license: licenseFor('open'),
  };
};

const installPinnedSourceFixture = async ({ sourceRoot, exampleId }) => {
  const examplesIndex = JSON.parse(
    await readFile(
      path.resolve(testDirectory, '../catalog/generated/examples-index.json'),
      'utf8'
    )
  );
  const head = (
    await execFileAsync('git', ['-C', sourceRoot, 'rev-parse', 'HEAD'], {
      encoding: 'utf8',
    })
  ).stdout.trim();
  assert.equal(
    head,
    examplesIndex.source.commit,
    'pinned example fixture must use the catalog exact commit'
  );
  const header = examplesIndex.headers.find(item => item.id === exampleId);
  assert.ok(header, `Missing pinned example header: ${exampleId}`);
  const projectBuffer = await readFile(
    path.join(sourceRoot, ...header.project.path.split('/'))
  );
  const projectValue = JSON.parse(projectBuffer.toString('utf8'));
  const projectBytes = projectBuffer.buffer.slice(
    projectBuffer.byteOffset,
    projectBuffer.byteOffset + projectBuffer.byteLength
  );
  const project = artifactFor('project', projectBytes, 'application/json');
  state.bodies.set(project.id, projectBytes);
  const seenPaths = new Set();
  const resources = [];
  let localReferenceCount = 0;
  for (const resource of projectValue.resources.resources) {
    if (typeof resource.file !== 'string' || resource.file.startsWith('data:')) {
      continue;
    }
    const relativePath = resource.file
      .replaceAll('\\', '/')
      .replace(/^\.\//, '');
    assert.doesNotMatch(relativePath, /^[a-z][a-z\d+.-]*:/i);
    localReferenceCount++;
    if (seenPaths.has(relativePath)) continue;
    seenPaths.add(relativePath);
    const resourceBuffer = await readFile(
      path.join(sourceRoot, ...header.root.split('/'), ...relativePath.split('/'))
    );
    const bytes = resourceBuffer.buffer.slice(
      resourceBuffer.byteOffset,
      resourceBuffer.byteOffset + resourceBuffer.byteLength
    );
    const artifact = artifactFor(
      `resource-${resources.length}`,
      bytes,
      'application/octet-stream'
    );
    state.bodies.set(artifact.id, bytes);
    resources.push({
      file: relativePath,
      name: String(resource.name || relativePath),
      artifact,
    });
  }
  state.exampleManifest = {
    schemaVersion: 2,
    id: header.id,
    name: header.name,
    project,
    projectDownload: {
      bytes: projectBytes,
      contentHash: await sha256Hex(projectBytes),
    },
    resources,
    requestCount: resources.length + 1,
    totalBytes:
      projectBytes.byteLength +
      resources.reduce(
        (total, resource) => total + resource.artifact.declaredBytes,
        0
      ),
    license: licenseFor('open'),
  };
  return { header, localReferenceCount, distinctSourceCount: resources.length };
};

resetState();
await installFixture();
const progress = [];
const imported = await importer.importPlaymeshExample({
  header: { id: 'fixture', name: '官方示例' },
  onProgress: value => progress.push(value),
});
assert.equal(imported.name, '官方示例');
assert.equal(state.projectAllocations.length, 1);
const allocation = state.projectAllocations[0];
assert.equal(allocation.snapshot.resources.length, 3);
assert.equal(allocation.gameId, 'com.playmesh.game.gimport00001');
assert.equal(allocation.origin, 'create');
const storedJson = allocation.snapshot.project;
assert.equal(
  storedJson.properties.packageName,
  'com.playmesh.game.gimport00001'
);
assert.notEqual(
  storedJson.properties.projectUuid,
  storedJson.properties.packageName
);
assert.ok(
  allocation.snapshot.resources.every(
    resource =>
      resource.blob instanceof Blob &&
      /^[a-f0-9]{64}$/.test(resource.contentHash)
  )
);
assert.match(JSON.stringify(storedJson), /playmesh-local-resource:\/\//);
assert.equal(state.maximumActiveDownloads, 2);
assert.equal(state.clearCount, 1);
assert.equal(state.staging.size, 0);
assert.deepEqual(progress.at(-1), { completed: 4, total: 4 });
assert.deepEqual(state.validationEvents, [
  'initialize-platforms',
  'unserialize-project',
]);
assert.equal(state.platformInitializationCount, 1);
assert.doesNotMatch(
  source,
  /\bgd\.initializePlatforms\(/,
  'example import must share the process-wide platform guard instead of calling native initialization directly'
);

for (const status of ['non-open', 'unknown', 'conflict']) {
  resetState();
  await installFixture();
  state.exampleManifest.license = licenseFor(status);
  await assert.rejects(
    importer.importPlaymeshExample({
      header: { id: 'fixture', name: '官方示例' },
    }),
    error => error.code === 'license_acknowledgement_required'
  );
  assert.equal(state.projectAllocations.length, 0);
  await importer.importPlaymeshExample({
    header: { id: 'fixture', name: '官方示例' },
    licenseEvidenceKey: state.exampleManifest.license.evidenceKey,
  });
  assert.equal(
    state.projectAllocations.length,
    1,
    `${status} remains importable after acknowledging the current evidence`
  );
}

resetState();
await installDuplicateResourceFixture();
await importer.importPlaymeshExample({
  header: {
    id: 'duplicate-resource-fixture',
    name: '重复资源官方示例',
  },
});
assert.equal(state.projectAllocations.length, 1);
const aliasedSnapshot = state.projectAllocations[0].snapshot;
const aliasedEntries = aliasedSnapshot.project.resources.resources;
assert.equal(aliasedSnapshot.resources.length, 2);
assert.equal(new Set(aliasedEntries.map(entry => entry.file)).size, 2);
assert.deepEqual(
  aliasedSnapshot.resources.map(resource => resource.logicalUrl),
  aliasedEntries.map(entry => entry.file)
);
assert.deepEqual(
  aliasedSnapshot.resources.map(resource => resource.name),
  ['Shared primary', 'Shared alias']
);
assert.equal(
  aliasedSnapshot.resources[0].contentHash,
  aliasedSnapshot.resources[1].contentHash,
  'duplicate official references must reuse the verified CAS content'
);
assert.equal(
  aliasedSnapshot.resources[0].blob,
  aliasedSnapshot.resources[1].blob,
  'duplicate official references must not duplicate downloaded bytes'
);

resetState();
await installFixture();
const cancelled = new AbortController();
cancelled.abort();
await assert.rejects(
  importer.importPlaymeshExample({
    header: { id: 'fixture', name: '官方示例' },
    signal: cancelled.signal,
  }),
  error => error.code === 'cancelled'
);
assert.equal(state.projectAllocations.length, 0);
assert.equal(state.clearCount, 1);
assert.equal(state.staging.size, 0);

resetState();
await installFixture();
state.failStagingArtifactKey = 'resource:0';
await assert.rejects(
  importer.importPlaymeshExample({
    header: { id: 'fixture', name: '官方示例' },
  }),
  error =>
    error.code === 'QuotaExceededError' &&
    error.stage === 'resource_download'
);
assert.equal(state.activeDownloads, 0);
assert.equal(state.projectAllocations.length, 0);
assert.equal(state.clearCount, 1);
assert.equal(state.staging.size, 0);

resetState();
await installFixture();
state.allocationError = Object.assign(new Error('manifest mismatch'), {
  code: 'gdevelop_allocation_evidence_mismatch',
  status: 409,
  requestId: 'dev-example-fixture',
  operation: 'gdevelop.project.allocation.workspace.finalize',
  details: {
    requestId: 'dev-example-fixture',
    operation: 'gdevelop.project.allocation.workspace.finalize',
  },
});
let allocationFailure = null;
await assert.rejects(
  importer.importPlaymeshExample({
    header: { id: 'fixture', name: '官方示例' },
  }),
  error => {
    allocationFailure = error;
    return (
      error.code === 'gdevelop_allocation_evidence_mismatch' &&
      error.stage === 'project_allocation' &&
      error.operation ===
        'gdevelop.project.allocation.workspace.finalize' &&
      error.status === 409 &&
      error.requestId === 'dev-example-fixture'
    );
  }
);
assert.equal(state.projectAllocations.length, 0);
assert.equal(state.clearCount, 1);
assert.equal(state.staging.size, 0);
const originalConsoleError = console.error;
const diagnosticLines = [];
console.error = line => diagnosticLines.push(String(line));
try {
  importer.reportPlaymeshExampleImportFailure(allocationFailure);
} finally {
  console.error = originalConsoleError;
}
assert.deepEqual(diagnosticLines, [
  '[PlayMesh Examples] requestId=dev-example-fixture stage=project_allocation operation=gdevelop.project.allocation.workspace.finalize status=409 code=gdevelop_allocation_evidence_mismatch reason=gdevelop_allocation_evidence_mismatch target=unavailable',
]);
assert.doesNotMatch(diagnosticLines[0], /Bearer|developer-token/i);

resetState();
await installFixture();
state.failGDevelopValidation = true;
await assert.rejects(
  importer.importPlaymeshExample({
    header: { id: 'fixture', name: '官方示例' },
  }),
  error => error.code === 'invalid_project_schema'
);
assert.equal(state.projectAllocations.length, 0);
assert.equal(state.clearCount, 1);
assert.equal(state.staging.size, 0);

assert.doesNotMatch(source, /resourceBytes\s*=/);

const pinnedSourceArgumentIndex = process.argv.indexOf('--examples-source');
if (pinnedSourceArgumentIndex >= 0) {
  const sourceRoot = process.argv[pinnedSourceArgumentIndex + 1];
  assert.ok(sourceRoot, '--examples-source requires a local Git source path');
  resetState();
  const pinned = await installPinnedSourceFixture({
    sourceRoot,
    exampleId: '3d-bomber-bunny',
  });
  assert.ok(
    pinned.localReferenceCount > pinned.distinctSourceCount,
    'the pinned regression fixture must retain duplicate official resource references'
  );
  try {
    await importer.importPlaymeshExample({ header: pinned.header });
  } catch (error) {
    assert.fail(
      `Pinned example import failed: ${error && error.code}: ${
        error && error.message
      }`
    );
  }
  const pinnedSnapshot = state.projectAllocations[0].snapshot;
  const pinnedEntries = pinnedSnapshot.project.resources.resources.filter(
    resource =>
      typeof resource.file === 'string' &&
      resource.file.startsWith('playmesh-local-resource://')
  );
  assert.equal(pinnedSnapshot.resources.length, pinned.localReferenceCount);
  assert.equal(new Set(pinnedEntries.map(entry => entry.file)).size, pinnedEntries.length);
  assert.equal(
    new Set(pinnedSnapshot.resources.map(resource => resource.logicalUrl)).size,
    pinnedSnapshot.resources.length
  );
  assert.ok(
    new Set(pinnedSnapshot.resources.map(resource => resource.contentHash)).size <
      pinnedSnapshot.resources.length,
    'pinned duplicate references must reuse at least one CAS object'
  );
}
process.stdout.write('GDevelop example importer tests passed.\n');
