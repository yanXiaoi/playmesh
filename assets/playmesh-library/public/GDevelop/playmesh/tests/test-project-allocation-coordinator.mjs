import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjects/PlaymeshProjectAllocationCoordinator.js'
  ),
  'utf8'
);

globalThis.window = { crypto: webcrypto };
const executable = `
const playmeshPortableImportAllocationClient = null;
const computeSha256Hex = async (bytes, cryptoImplementation) =>
  Array.from(
    new Uint8Array(await cryptoImplementation.subtle.digest('SHA-256', bytes))
  )
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
${source
  .replace(/^\/\/ @flow\s*/, '')
  .replace(/import[\s\S]*?from\s+['"][^'"]+['"];\s*/g, '')}`;
const coordinator = await import(
  `data:text/javascript;base64,${Buffer.from(executable).toString('base64')}`
);

const digest = async value =>
  Buffer.from(
    await webcrypto.subtle.digest(
      'SHA-256',
      typeof value === 'string' ? new TextEncoder().encode(value) : value
    )
  ).toString('hex');

const canonicalizeJson = value => {
  if (Array.isArray(value)) return value.map(canonicalizeJson);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map(key => [key, canonicalizeJson(value[key])])
    );
  }
  return value;
};

const snapshot = { project: { properties: { name: 'Blank project' } }, resources: [] };
const input = {
  fileIdentifier: 'blank-file',
  gameId: 'com.playmesh.blank',
  name: 'Blank project',
  origin: 'create',
  projectUuid: 'project-uuid',
  snapshot,
};

{
  const firstBytes = new TextEncoder().encode('first-resource');
  const secondBytes = new TextEncoder().encode('second-resource');
  const resources = [
    {
      logicalUrl: 'playmesh-local-resource://fixture/z-resource',
      name: 'z-resource',
      blob: new Blob([firstBytes], { type: 'image/png' }),
      contentHash: await digest(firstBytes),
    },
    {
      logicalUrl: 'playmesh-local-resource://fixture/a-resource',
      name: 'a-resource',
      blob: new Blob([secondBytes], { type: 'image/png' }),
      contentHash: await digest(secondBytes),
    },
  ];
  const projectWithResources = {
    ...snapshot.project,
    resources: {
      resources: [
        {
          name: 'z-resource',
          file: 'playmesh-local-resource://fixture/z-resource',
        },
        {
          name: 'a-resource',
          file: 'playmesh-local-resource://fixture/a-resource',
        },
      ],
    },
  };
  const forward = await coordinator.createPlaymeshProjectAllocationEvidence({
    projectJson: JSON.stringify(projectWithResources),
    resources,
    cryptoImplementation: webcrypto,
  });
  const reverse = await coordinator.createPlaymeshProjectAllocationEvidence({
    projectJson: JSON.stringify(projectWithResources),
    resources: [...resources].reverse(),
    cryptoImplementation: webcrypto,
  });
  assert.deepEqual(
    forward.resourcePlan.map(resource => resource.logicalId),
    [
      'playmesh-local-resource://fixture/a-resource',
      'playmesh-local-resource://fixture/z-resource',
    ]
  );
  assert.equal(
    forward.resourceManifestHash,
    reverse.resourceManifestHash,
    'snapshot enumeration must not change the official project resource ordering'
  );
  const resourceManifestInOfficialOrder = [
    forward.resourcePlan[1],
    forward.resourcePlan[0],
  ];
  assert.equal(
    forward.resourceManifestHash,
    await digest(
      JSON.stringify(canonicalizeJson(resourceManifestInOfficialOrder))
    ),
    'resource manifest evidence must match official GDevelop resource order'
  );
  assert.notEqual(
    forward.resourceManifestHash,
    await digest(JSON.stringify(canonicalizeJson(forward.resourcePlan))),
    'resource plan canonical order and resource manifest order are distinct contracts'
  );
}

const createClient = ({
  prepareError = null,
  prepareState = null,
  finalizeError = null,
  commitLostResponse = false,
  invalidState = false,
} = {}) => {
  const calls = [];
  let phase = 'NOT_FOUND';
  let commitAttempts = 0;
  let lostStatusConsumed = false;
  const state = next => ({ phase: next, transactionId: 'tx-1' });
  return {
    calls,
    client: {
      prepare: async request => {
        calls.push(['prepare', request.idempotencyKey]);
        if (prepareError) throw prepareError;
        if (invalidState) return { phase: 'WRONG' };
        phase = (prepareState && prepareState.phase) || 'PREPARED';
        return prepareState || state(phase);
      },
      getStatus: async request => {
        calls.push(['status', request.transactionId || null]);
        if (prepareError && !request.transactionId) throw prepareError;
        if (invalidState) return { nope: true };
        if (
          commitLostResponse &&
          phase === 'COMMIT_REQUESTED' &&
          !lostStatusConsumed
        ) {
          lostStatusConsumed = true;
          throw new Error('status unavailable');
        }
        return state(phase);
      },
      resourcePresence: async () => {
        calls.push(['presence']);
        return { ...state('PREPARED'), missing: [], available: [] };
      },
      uploadResource: async () => calls.push(['resource']),
      uploadProject: async () => calls.push(['project']),
      finalizeWorkspace: async () => {
        calls.push(['finalize']);
        if (finalizeError) throw finalizeError;
        phase = 'WORKSPACE_FINALIZED';
        return state(phase);
      },
      commit: async () => {
        commitAttempts += 1;
        calls.push(['commit', commitAttempts]);
        phase = commitLostResponse ? 'COMMIT_REQUESTED' : 'COMMITTED';
        if (commitLostResponse && commitAttempts === 1) {
          throw new Error('lost response');
        }
        return state(phase);
      },
      recover: async () => {
        calls.push(['recover']);
        phase = 'COMMITTED';
        return state(phase);
      },
      abort: async () => {
        calls.push(['abort']);
        phase = 'ABORTED';
        return state(phase);
      },
    },
  };
};

{
  const harness = createClient();
  const result = await coordinator.allocatePlaymeshProjectSnapshot({
    ...input,
    allocationClient: harness.client,
  });
  assert.equal(result.phase, 'COMMITTED');
  assert.deepEqual(
    harness.calls.map(call => call[0]),
    ['prepare', 'project', 'finalize', 'commit']
  );
}

{
  const harness = createClient({
    prepareState: {
      phase: 'CONFLICT',
      transactionId: null,
      conflict: {
        reason: 'target_became_occupied',
        observedAt: new Date().toISOString(),
      },
    },
  });
  await assert.rejects(
    coordinator.allocatePlaymeshProjectSnapshot({
      ...input,
      fileIdentifier: 'conflict-file',
      allocationClient: harness.client,
    }),
    error => error.code === 'project_id_conflict' && error.status === 409
  );
}

for (const status of [401, 404]) {
  const requestId = `request-${status}`;
  const harness = createClient({
    prepareError: Object.assign(new Error('gateway rejected'), {
      code: status === 401 ? 'unauthorized' : 'not_found',
      status,
      details: { requestId },
    }),
  });
  await assert.rejects(
    coordinator.allocatePlaymeshProjectSnapshot({
      ...input,
      fileIdentifier: `error-${status}`,
      allocationClient: harness.client,
    }),
    error => error.status === status && error.message.includes(requestId)
  );
}

{
  const harness = createClient({ invalidState: true });
  await assert.rejects(
    coordinator.allocatePlaymeshProjectSnapshot({
      ...input,
      fileIdentifier: 'protocol-file',
      allocationClient: harness.client,
    }),
    error => error.code === 'invalid_response'
  );
}

{
  const harness = createClient({ finalizeError: new Error('disk full') });
  await assert.rejects(
    coordinator.allocatePlaymeshProjectSnapshot({
      ...input,
      fileIdentifier: 'rollback-file',
      allocationClient: harness.client,
    })
  );
  assert.equal(
    harness.calls.some(call => call[0] === 'abort'),
    true,
    'pre-decision workspace failure must abort the allocation transaction'
  );
}

{
  const harness = createClient({ commitLostResponse: true });
  const retryInput = {
    ...input,
    fileIdentifier: 'retry-file',
    allocationClient: harness.client,
  };
  await assert.rejects(
    coordinator.allocatePlaymeshProjectSnapshot(retryInput),
    /lost response/
  );
  assert.equal(
    harness.calls.some(call => call[0] === 'abort'),
    false,
    'an uncertain post-commit response must never roll back'
  );
  const result = await coordinator.allocatePlaymeshProjectSnapshot(retryInput);
  assert.equal(result.phase, 'COMMITTED');
  assert.deepEqual(
    harness.calls.filter(call => call[0] === 'prepare').length,
    1,
    'retry must reuse the recorded transaction instead of reallocating'
  );
  assert.equal(harness.calls.some(call => call[0] === 'recover'), true);
}

delete globalThis.window;
process.stdout.write('GDevelop blank project allocation coordinator tests passed.\n');
