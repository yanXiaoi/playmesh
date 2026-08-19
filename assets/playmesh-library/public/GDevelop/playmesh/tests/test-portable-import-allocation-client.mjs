import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshProjectImport/PlaymeshPortableImportAllocationClient.js'
);
const hostConfigSourcePath = path.resolve(
  testDirectory,
  '../../../../../../lib/core/developer/gdevelop_project_config.dart'
);
const hostAllocationSourcePath = path.resolve(
  testDirectory,
  '../../../../../../lib/core/developer/gdevelop_project_allocation.dart'
);

const [sourceText, hostConfigSource, hostAllocationSource] = await Promise.all([
  readFile(sourcePath, 'utf8'),
  readFile(hostConfigSourcePath, 'utf8'),
  readFile(hostAllocationSourcePath, 'utf8'),
]);
const source = sourceText.replace(
  /^\/\/ @flow\s*/,
  ''
);
const allocation = await import(`data:text/javascript;base64,${Buffer.from(
  source,
  'utf8'
).toString('base64')}`);

const baseUrl = '/dev/api/gdevelop/project-allocation-transactions';
const target = {
  fileIdentifier: 'browser-file-1',
  gameId: 'com.example.imported',
  packageName: 'com.example.imported',
  projectUuid: 'project-uuid-1',
  projectFilesHash: 'c'.repeat(64),
  resourceManifestHash: 'd'.repeat(64),
};
const portInput = {
  idempotencyKey: 'portable-import-1',
  transactionId: null,
  origin: 'import',
  name: 'Imported fixture',
  target,
};
const projectFilesJson = JSON.stringify([
  { path: 'game.json', content: { name: 'Fixture' } },
]);
const projectFilesSize = Buffer.byteLength(projectFilesJson);
const resourcePlan = [
  {
    logicalId: 'images/player.png',
    name: 'images/player.png',
    contentHash: '1'.repeat(64),
    mime: 'image/png',
    size: 3,
  },
  {
    logicalId: 'sounds/theme.ogg',
    name: 'sounds/theme.ogg',
    contentHash: '2'.repeat(64),
    mime: 'audio/ogg',
    size: 4,
    metadata: { preloadAsSound: true },
  },
];
const workspaceProject = {
  packageName: target.packageName,
  projectUuid: target.projectUuid,
  projectFilesHash: target.projectFilesHash,
  projectFilesSize,
  resourceReferences: resourcePlan.map(({ logicalId, name }) => ({
    logicalId,
    name,
  })),
};
const workspaceFinalization = {
  packageName: target.packageName,
  projectUuid: target.projectUuid,
  projectFilesHash: target.projectFilesHash,
  projectFilesSize,
  resourceManifestHash: target.resourceManifestHash,
};
const currentHostProjectConfig = {
  schemaVersion: 2,
  gameId: target.gameId,
  revision: 1,
  gameType: 'single',
  minPlayers: 1,
  maxPlayers: 1,
  tags: [],
  updatedAt: '2026-08-05T00:00:00.000Z',
};
const allocationEvidenceForConfig = config => ({
  projectMetadataHash: 'a'.repeat(64),
  config: {
    status: 'ready',
    revision: 1,
    contentHash: 'b'.repeat(64),
    config,
  },
});

// Keep the WebIDE response fixture bound to the current host DTO. This catches
// host config schema changes even though the example-importer unit test mocks
// the allocation boundary.
const hostSchemaVersion = hostConfigSource.match(
  /static const schemaVersion = (\d+);/
);
assert.ok(hostSchemaVersion, 'host GDevelop config schemaVersion is declared');
assert.equal(Number(hostSchemaVersion[1]), currentHostProjectConfig.schemaVersion);
const hostConfigClassStart = hostConfigSource.indexOf(
  'class GDevelopProjectConfig {'
);
const hostConfigFactoryStart = hostConfigSource.indexOf(
  'factory GDevelopProjectConfig.fromJson',
  hostConfigClassStart
);
assert.ok(hostConfigClassStart >= 0 && hostConfigFactoryStart > hostConfigClassStart);
const hostConfigToJson = hostConfigSource
  .slice(hostConfigClassStart, hostConfigFactoryStart)
  .match(/Map<String, Object\?> toJson\(\) => \{([\s\S]*?)\n\s*\};/);
assert.ok(hostConfigToJson, 'host GDevelop config toJson shape is discoverable');
const hostConfigKeys = [
  ...hostConfigToJson[1].matchAll(/^\s*'([^']+)':/gm),
].map(match => match[1]);
assert.deepEqual(hostConfigKeys, Object.keys(currentHostProjectConfig));
const hostAllocationEvidenceSource = hostAllocationSource.slice(
  hostAllocationSource.indexOf('class GDevelopProjectAllocationEvidence {'),
  hostAllocationSource.indexOf('class GDevelopProjectAllocationPayload {')
);
const hostAllocationTransactionSource = hostAllocationSource.slice(
  hostAllocationSource.indexOf('class GDevelopProjectAllocationTransaction {'),
  hostAllocationSource.indexOf('enum GDevelopProjectAllocationCrashPoint')
);
assert.match(
  hostAllocationTransactionSource,
  /'allocationEvidence': record\.payload\.allocationEvidence\.toJson\(\)/
);
assert.match(hostAllocationEvidenceSource, /'config': config\.toJson\(\)/);

const transaction = (phase, overrides = {}) => {
  const hasWorkspace = [
    'WORKSPACE_FINALIZED',
    'COMMIT_REQUESTED',
    'COMMITTED',
  ].includes(phase);
  return {
    txId: 'allocation-tx-1',
    idempotencyKey: portInput.idempotencyKey,
    gameId: target.gameId,
    origin: portInput.origin,
    phase,
    name: portInput.name,
    clientId: null,
    workspaceTarget: target,
    allocationEvidence: allocationEvidenceForConfig(currentHostProjectConfig),
    resourcePlan: phase === 'PREPARED' && !overrides.resourcePlan ? [] : resourcePlan,
    createdAt: '2026-08-05T00:00:00.000Z',
    updatedAt: '2026-08-05T00:00:01.000Z',
    expiresAt:
      phase === 'PREPARED' ||
      phase === 'WORKSPACE_FINALIZED' ||
      phase === 'COMMIT_REQUESTED'
        ? '2026-08-05T00:05:00.000Z'
        : null,
    retainedUntil:
      phase === 'COMMITTED' || phase === 'ABORTED'
        ? '2026-08-06T00:00:00.000Z'
        : null,
    workspaceProject: hasWorkspace ? workspaceProject : null,
    workspaceFinalization: hasWorkspace ? workspaceFinalization : null,
    conflict:
      phase === 'CONFLICT'
        ? {
            reason: 'target_became_occupied',
            observedAt: '2026-08-05T00:00:01.000Z',
          }
        : null,
    ...overrides,
  };
};

const responseEnvelope = value => ({
  requestId: 'request-1',
  transaction: value,
});

const createFetchHarness = responses => {
  const calls = [];
  const queue = [...responses];
  return {
    calls,
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      assert.notEqual(init.signal, undefined);
      const next = queue.shift();
      assert.ok(next, `Unexpected allocation request: ${init.method} ${url}`);
      const body = JSON.stringify(next.payload);
      return new Response(body, {
        status: next.status,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Content-Length': String(Buffer.byteLength(body)),
          ...(next.headers || {}),
        },
      });
    },
    assertDrained: () => assert.equal(queue.length, 0),
  };
};

{
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(transaction('PREPARED')) },
    {
      status: 200,
      payload: {
        ...responseEnvelope(transaction('PREPARED', { resourcePlan })),
        missing: [{ hash: resourcePlan[0].contentHash, bytes: 3 }],
        available: [{ hash: resourcePlan[1].contentHash, bytes: 4 }],
      },
    },
    {
      status: 200,
      payload: {
        requestId: 'request-resource',
        resource: { hash: resourcePlan[0].contentHash, bytes: 3 },
      },
    },
    {
      status: 200,
      payload: {
        requestId: 'request-project',
        project: {
          contentHash: target.projectFilesHash,
          size: projectFilesSize,
        },
      },
    },
    {
      status: 200,
      payload: responseEnvelope(transaction('WORKSPACE_FINALIZED')),
    },
    {
      status: 202,
      payload: responseEnvelope(transaction('COMMIT_REQUESTED')),
    },
    {
      status: 200,
      payload: responseEnvelope(transaction('COMMIT_REQUESTED')),
    },
    { status: 200, payload: responseEnvelope(transaction('COMMITTED')) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });

  assert.deepEqual(await client.prepare(portInput), {
    phase: 'PREPARED',
    transactionId: 'allocation-tx-1',
  });
  const preparedInput = { ...portInput, transactionId: 'allocation-tx-1' };
  assert.deepEqual(await client.resourcePresence(preparedInput, resourcePlan), {
    phase: 'PREPARED',
    transactionId: 'allocation-tx-1',
    missing: [{ hash: resourcePlan[0].contentHash, bytes: 3 }],
    available: [{ hash: resourcePlan[1].contentHash, bytes: 4 }],
  });
  const resourceBlob = new Blob(['abc'], { type: 'image/png' });
  assert.deepEqual(
    await client.uploadResource(preparedInput, {
      contentHash: resourcePlan[0].contentHash,
      blob: resourceBlob,
    }),
    { hash: resourcePlan[0].contentHash, bytes: 3 }
  );
  assert.deepEqual(
    await client.uploadProjectFiles(preparedInput, projectFilesJson),
    {
      contentHash: target.projectFilesHash,
      size: projectFilesSize,
    }
  );
  assert.deepEqual(
    await client.finalizeWorkspace(preparedInput, workspaceFinalization),
    { phase: 'WORKSPACE_FINALIZED', transactionId: 'allocation-tx-1' }
  );
  assert.deepEqual(await client.commit(preparedInput), {
    phase: 'COMMIT_REQUESTED',
    transactionId: 'allocation-tx-1',
  });
  assert.deepEqual(await client.getStatus(preparedInput), {
    phase: 'COMMIT_REQUESTED',
    transactionId: 'allocation-tx-1',
  });
  assert.deepEqual(await client.recover(preparedInput), {
    phase: 'COMMITTED',
    transactionId: 'allocation-tx-1',
  });

  const [
    prepareCall,
    presenceCall,
    resourceCall,
    projectCall,
    finalizeCall,
    commitCall,
    statusCall,
    recoverCall,
  ] = fetchHarness.calls;
  assert.equal(prepareCall.url, baseUrl);
  assert.equal(prepareCall.init.method, 'POST');
  assert.deepEqual(JSON.parse(prepareCall.init.body), {
    idempotencyKey: portInput.idempotencyKey,
    gameId: target.gameId,
    origin: 'import',
    name: portInput.name,
    workspaceTarget: target,
  });
  assert.equal('clientId' in JSON.parse(prepareCall.init.body), false);
  assert.equal(
    presenceCall.url,
    `${baseUrl}/allocation-tx-1/resources/presence`
  );
  assert.deepEqual(JSON.parse(presenceCall.init.body), {
    resources: resourcePlan,
  });
  assert.equal(
    resourceCall.url,
    `${baseUrl}/allocation-tx-1/resources/${resourcePlan[0].contentHash}`
  );
  assert.equal(resourceCall.init.method, 'PUT');
  assert.equal(resourceCall.init.body, resourceBlob);
  assert.equal('Content-Length' in resourceCall.init.headers, false);
  assert.equal(
    projectCall.url,
    `${baseUrl}/allocation-tx-1/workspace/project-files`
  );
  assert.equal(projectCall.init.method, 'PUT');
  assert.equal(await projectCall.init.body.text(), projectFilesJson);
  assert.equal(
    finalizeCall.url,
    `${baseUrl}/allocation-tx-1/workspace/finalize`
  );
  assert.deepEqual(JSON.parse(finalizeCall.init.body), workspaceFinalization);
  assert.equal(commitCall.url, `${baseUrl}/allocation-tx-1/commit`);
  assert.deepEqual(JSON.parse(commitCall.init.body), {});
  assert.equal(statusCall.url, `${baseUrl}/allocation-tx-1`);
  assert.equal(statusCall.init.method, 'GET');
  assert.equal('body' in statusCall.init, false);
  assert.equal(recoverCall.url, `${baseUrl}/allocation-tx-1/recover`);
  assert.deepEqual(JSON.parse(recoverCall.init.body), {});
  for (const call of fetchHarness.calls) {
    assert.equal(call.init.credentials, 'same-origin');
    assert.equal(call.init.cache, 'no-store');
  }
  fetchHarness.assertDrained();
}

{
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(transaction('PREPARED')) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  assert.deepEqual(await client.getStatus(portInput), {
    phase: 'PREPARED',
    transactionId: 'allocation-tx-1',
  });
  assert.equal(fetchHarness.calls[0].url, baseUrl);
  assert.equal(fetchHarness.calls[0].init.method, 'POST');
}

{
  const transactionWithFallbackName = transaction('PREPARED', {
    name: target.gameId,
  });
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(transactionWithFallbackName) },
    { status: 201, payload: responseEnvelope(transactionWithFallbackName) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  const inputWithoutName = { ...portInput };
  delete inputWithoutName.name;
  assert.deepEqual(await client.prepare(inputWithoutName), {
    phase: 'PREPARED',
    transactionId: 'allocation-tx-1',
  });
  assert.deepEqual(await client.getStatus(inputWithoutName), {
    phase: 'PREPARED',
    transactionId: 'allocation-tx-1',
  });
  for (const call of fetchHarness.calls) {
    const body = JSON.parse(call.init.body);
    assert.equal('name' in body, false);
    assert.equal('clientId' in body, false);
  }
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 409,
      payload: {
        requestId: 'request-conflict',
        error: {
          code: 'project_id_conflict',
          message: 'gameId is occupied',
          gameId: target.gameId,
        },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  assert.deepEqual(await client.prepare(portInput), {
    phase: 'CONFLICT',
    transactionId: null,
  });
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 404,
      payload: {
        requestId: 'request-missing',
        error: {
          code: 'gdevelop_allocation_not_found',
          message: 'not found',
          txId: 'allocation-tx-1',
        },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  assert.deepEqual(
    await client.getStatus({ ...portInput, transactionId: 'allocation-tx-1' }),
    { phase: 'NOT_FOUND', transactionId: null }
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 404,
      payload: {
        error: {
          code: 'gdevelop_allocation_not_found',
          message: 'missing requestId',
        },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.getStatus({ ...portInput, transactionId: 'allocation-tx-1' }),
    error => error.status === 404
  );
}

{
  const fetchHarness = createFetchHarness([
    { status: 200, payload: responseEnvelope(transaction('CONFLICT')) },
    {
      status: 202,
      payload: responseEnvelope(transaction('COMMIT_REQUESTED')),
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  const input = { ...portInput, transactionId: 'allocation-tx-1' };
  assert.deepEqual(await client.getStatus(input), {
    phase: 'CONFLICT',
    transactionId: 'allocation-tx-1',
    conflict: {
      reason: 'target_became_occupied',
      observedAt: '2026-08-05T00:00:01.000Z',
    },
  });
  await assert.rejects(client.getStatus(input), error => error.status === 202);
}

{
  const fetchHarness = createFetchHarness([
    { status: 409, payload: responseEnvelope(transaction('CONFLICT')) },
    {
      status: 200,
      payload: responseEnvelope(
        transaction('ABORTED', {
          conflict: {
            reason: 'staging_changed',
            observedAt: '2026-08-05T00:00:01.000Z',
          },
        })
      ),
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  const input = { ...portInput, transactionId: 'allocation-tx-1' };
  assert.deepEqual(await client.commit(input), {
    phase: 'CONFLICT',
    transactionId: 'allocation-tx-1',
    conflict: {
      reason: 'target_became_occupied',
      observedAt: '2026-08-05T00:00:01.000Z',
    },
  });
  assert.deepEqual(await client.abort(input), {
    phase: 'ABORTED',
    transactionId: 'allocation-tx-1',
    conflict: {
      reason: 'staging_changed',
      observedAt: '2026-08-05T00:00:01.000Z',
    },
  });
}

{
  const legacyProjectConfig = {
    schemaVersion: 1,
    gameId: target.gameId,
    revision: 1,
    gameType: 'single',
    updatedAt: '2026-08-05T00:00:00.000Z',
  };
  const fetchHarness = createFetchHarness([
    {
      status: 201,
      payload: responseEnvelope(
        transaction('PREPARED', {
          allocationEvidence: allocationEvidenceForConfig(legacyProjectConfig),
        })
      ),
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.prepare(portInput),
    error => error.code === 'invalid_response'
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 201,
      payload: responseEnvelope(
        transaction('PREPARED', {
          allocationEvidence: allocationEvidenceForConfig({
            ...currentHostProjectConfig,
            unexpected: true,
          }),
        })
      ),
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.prepare(portInput),
    error => error.code === 'invalid_response'
  );
}

{
  const invalidTransaction = {
    ...transaction('PREPARED'),
    unexpected: true,
  };
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(invalidTransaction) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.prepare(portInput),
    error => error.code === 'invalid_response'
  );
}

{
  const missingNullableKey = transaction('PREPARED');
  delete missingNullableKey.retainedUntil;
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(missingNullableKey) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.prepare(portInput),
    error => error.code === 'invalid_response'
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 202,
      payload: responseEnvelope(transaction('WORKSPACE_FINALIZED')),
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.commit({ ...portInput, transactionId: 'allocation-tx-1' }),
    error => error.code === 'invalid_response'
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 409,
      payload: {
        ...responseEnvelope(transaction('CONFLICT')),
        error: {
          code: 'gdevelop_allocation_ack_mismatch',
          message: 'ambiguous response',
        },
      },
    },
    {
      status: 409,
      payload: {
        requestId: 'request-ack-mismatch',
        error: {
          code: 'gdevelop_allocation_ack_mismatch',
          message: 'ack mismatch',
        },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  const input = { ...portInput, transactionId: 'allocation-tx-1' };
  await assert.rejects(
    client.commit(input),
    error => error.code === 'gdevelop_allocation_ack_mismatch'
  );
  await assert.rejects(
    client.commit(input),
    error => error.code === 'gdevelop_allocation_ack_mismatch'
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 409,
      payload: {
        requestId: 'request-malformed-conflict',
        error: { message: 'missing stable code' },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.prepare(portInput),
    error =>
      error instanceof
        allocation.PlaymeshPortableImportAllocationRequestError &&
      error.status === 409
  );
}

{
  const fetchHarness = createFetchHarness([
    {
      status: 200,
      payload: {
        requestId: 'request-resource',
        resource: { hash: resourcePlan[0].contentHash, bytes: 4 },
      },
    },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
  });
  await assert.rejects(
    client.uploadResource(
      { ...portInput, transactionId: 'allocation-tx-1' },
      {
        contentHash: resourcePlan[0].contentHash,
        blob: new Blob(['abc']),
      }
    ),
    error => error.code === 'invalid_response'
  );
}

{
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: async () => {
      throw new Error('Finalize mismatch must not issue a request.');
    },
  });
  assert.throws(
    () => client.finalizeWorkspace(
      { ...portInput, transactionId: 'allocation-tx-1' },
      { ...workspaceFinalization, projectUuid: 'wrong-project-uuid' }
    ),
    error => error.code === 'invalid_response'
  );
}

{
  const configuredTransaction = transaction('PREPARED', {
    clientId: 'playmesh-webide',
  });
  const fetchHarness = createFetchHarness([
    { status: 201, payload: responseEnvelope(configuredTransaction) },
  ]);
  const client = allocation.createPlaymeshPortableImportAllocationClient({
    fetchImpl: fetchHarness.fetchImpl,
    clientId: 'playmesh-webide',
  });
  await client.prepare(portInput);
  assert.equal(
    JSON.parse(fetchHarness.calls[0].init.body).clientId,
    'playmesh-webide'
  );
}

assert.equal('browserPrepared' in allocation.playmeshPortableImportAllocationClient, false);
process.stdout.write(
  'GDevelop portable import allocation client tests passed.\n'
);
