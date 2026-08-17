import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjects/PlaymeshProjectLifecycleClient.js'
  ),
  'utf8'
);

const events = [];
const requests = [];
const responses = [];
globalThis.CustomEvent = class CustomEvent {
  constructor(type, options) {
    this.type = type;
    this.detail = options.detail;
  }
};
globalThis.window = {
  setTimeout,
  clearTimeout,
  dispatchEvent: event => events.push(event),
};
globalThis.fetch = async (url, options = {}) => {
  requests.push({ url, options });
  const next = responses.shift();
  if (!next) throw new Error(`Missing response for ${url}`);
  return next;
};

const jsonResponse = (status, body) => ({
  ok: status >= 200 && status < 300,
  status,
  headers: { get: () => null },
  json: async () => body,
});

const initialCurrentProjectList = () => ({
  requestId: 'project-list-initial-current',
  activeGameId: projectRef.gameId,
  projects: [
    {
      identity: {
        schemaVersion: 1,
        kind: 'gdevelop',
        gameId: projectRef.gameId,
        name: 'Imported official example',
        fileIdentifiers: ['example-file'],
        createdAt: '2026-08-05T00:00:00.000Z',
        updatedAt: '2026-08-05T00:01:00.000Z',
      },
      // Allocation initializes the authoritative current at revision 0.
      currentEvidence: {
        revision: 0,
        project: { contentHash: 'e'.repeat(64), size: 25611 },
        resources: [
          { contentHash: 'f'.repeat(64), size: 4096 },
        ],
      },
    },
  ],
  diagnostics: [],
});

const lifecycle = await import(`data:text/javascript;base64,${Buffer.from(
  source
).toString('base64')}`);
const projectRef = lifecycle.createPlaymeshProjectRef(
  'com.playmesh.game.gabcdefghij'
);
assert.equal(
  lifecycle.resolvePlaymeshProjectId(projectRef),
  'com.playmesh.game.gabcdefghij'
);
assert.throws(
  () => lifecycle.createPlaymeshProjectRef('../escape'),
  error => error.code === 'invalid_project_id'
);

// An imported example is immediately openable even before the first explicit
// save creates history revision 1. Reloading the page repeats the authoritative
// App list request and must keep the same project openable without IndexedDB.
responses.push(jsonResponse(200, initialCurrentProjectList()));
const initialList = await lifecycle.listPlaymeshProjects();
assert.equal(initialList.projects[0].hasCurrent, true);
assert.equal(initialList.activeGameId, projectRef.gameId);
responses.push(jsonResponse(200, initialCurrentProjectList()));
const refreshedInitialList = await lifecycle.listPlaymeshProjects();
assert.equal(refreshedInitialList.projects[0].hasCurrent, true);
responses.push(
  jsonResponse(200, {
    historyCapability: 'gdevelop.history.v2',
    project: {
      gameId: projectRef.gameId,
      created: false,
      fileIdentifiers: ['example-file'],
    },
  })
);
await lifecycle.openPlaymeshProject({
  projectRef,
  fileIdentifier: 'example-file',
});
assert.equal(
  requests.at(-1).url,
  `/dev/api/gdevelop/projects/${projectRef.gameId}/open`
);

responses.push(
  jsonResponse(200, {
    requestId: 'project-list-1',
    activeGameId: projectRef.gameId,
    projects: [
      {
        identity: {
          schemaVersion: 1,
          kind: 'gdevelop',
          gameId: projectRef.gameId,
          name: 'Managed Game',
          fileIdentifiers: ['a'],
          createdAt: '2026-08-05T00:00:00.000Z',
          updatedAt: '2026-08-05T00:01:00.000Z',
        },
        currentEvidence: {
          revision: 1,
          project: { contentHash: 'a'.repeat(64), size: 123 },
          resources: [],
        },
      },
    ],
    diagnostics: [
      {
        code: 'project_metadata_invalid',
        entry: 'damaged-entry',
        messageKey: 'gdevelop.projectList.diagnostics.project_metadata_invalid',
      },
    ],
  })
);
const listed = await lifecycle.listPlaymeshProjects();
assert.equal(requests.at(-1).url, '/dev/api/gdevelop/projects');
assert.equal(requests.at(-1).options.method, undefined);
assert.equal(listed.projects[0].identity.gameId, projectRef.gameId);
assert.equal(listed.projects[0].hasCurrent, true);
assert.equal(listed.activeGameId, projectRef.gameId);
assert.equal(listed.diagnostics[0].gameId, null);

responses.push(
  jsonResponse(200, {
    requestId: 'project-list-partial-1',
    activeGameId: 'com.playmesh.game.broken-current',
    projects: [
      {
        identity: {
          schemaVersion: 1,
          kind: 'gdevelop',
          gameId: projectRef.gameId,
          name: 'Still openable',
          fileIdentifiers: ['a'],
          createdAt: '2026-08-05T00:00:00.000Z',
          updatedAt: '2026-08-05T00:01:00.000Z',
        },
        currentEvidence: {
          revision: 2,
          project: { contentHash: 'b'.repeat(64), size: 321 },
          resources: [],
        },
      },
      {
        identity: {
          schemaVersion: 1,
          kind: 'gdevelop',
          gameId: 'com.playmesh.game.broken-current',
          name: 'Damaged current',
          fileIdentifiers: ['b'],
          createdAt: '2026-08-05T00:00:00.000Z',
          updatedAt: '2026-08-05T00:02:00.000Z',
        },
        currentEvidence: {
          revision: 3,
          project: { contentHash: 'c'.repeat(64), size: 456 },
          resources: [{ contentHash: 'not-a-hash', size: 10 }],
        },
      },
      {
        identity: {
          schemaVersion: 1,
          kind: 'gdevelop',
          gameId: '../unsafe',
          fileIdentifiers: ['unsafe'],
          createdAt: 'invalid',
          updatedAt: 'invalid',
        },
        currentEvidence: null,
      },
    ],
    diagnostics: [
      {
        code: 'project_metadata_invalid',
        entry: 'server-bad-root',
        messageKey:
          'gdevelop.projectList.diagnostics.project_metadata_invalid',
      },
      { unexpected: true },
    ],
  })
);
const partial = await lifecycle.listPlaymeshProjects();
assert.deepEqual(
  partial.projects.map(project => [
    project.identity.gameId,
    project.hasCurrent,
  ]),
  [
    [projectRef.gameId, true],
    ['com.playmesh.game.broken-current', false],
  ]
);
assert.equal(partial.activeGameId, null);
assert.deepEqual(
  partial.diagnostics.map(diagnostic => [diagnostic.code, diagnostic.entry]),
  [
    ['project_metadata_invalid', 'server-bad-root'],
    ['gdevelop_metadata_invalid', 'diagnostic-2'],
    ['gdevelop_current_evidence_unavailable', 'com.playmesh.game.broken-current'],
    ['gdevelop_metadata_invalid', 'project-3'],
  ]
);

responses.push(
  jsonResponse(200, {
    requestId: 'project-list-invalid-active-1',
    activeGameId: { invalid: true },
    projects: [],
    diagnostics: [],
  })
);
const invalidActive = await lifecycle.listPlaymeshProjects();
assert.equal(invalidActive.activeGameId, null);
assert.deepEqual(
  invalidActive.diagnostics.map(diagnostic => [
    diagnostic.code,
    diagnostic.entry,
  ]),
  [['gdevelop_metadata_invalid', 'activeGameId']]
);

responses.push(
  jsonResponse(201, {
    historyCapability: 'gdevelop.history.v2',
    project: {
      gameId: projectRef.gameId,
      created: true,
      fileIdentifiers: ['a'],
    },
  })
);
await lifecycle.createPlaymeshProject({
  projectRef,
  origin: 'create',
  fileIdentifier: 'a',
  name: 'Game',
});
assert.equal(requests.at(-1).url, '/dev/api/gdevelop/projects');
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  gameId: projectRef.gameId,
  origin: 'create',
  fileIdentifier: 'a',
  name: 'Game',
});

for (const [method, response, action, urlSuffix] of [
  [
    'POST',
    {
      historyCapability: 'gdevelop.history.v2',
      project: {
        gameId: projectRef.gameId,
        created: false,
        fileIdentifiers: ['a'],
      },
    },
    () => lifecycle.openPlaymeshProject({ projectRef, fileIdentifier: 'a' }),
    '/open',
  ],
  [
    'PATCH',
    {
      historyCapability: 'gdevelop.history.v2',
      project: {
        gameId: projectRef.gameId,
        created: false,
        fileIdentifiers: ['a'],
      },
    },
    () => lifecycle.updatePlaymeshProject({ projectRef, name: 'Renamed' }),
    '',
  ],
]) {
  responses.push(jsonResponse(200, response));
  await action();
  assert.equal(requests.at(-1).options.method, method);
  assert.equal(
    requests.at(-1).url,
    `/dev/api/gdevelop/projects/${projectRef.gameId}${urlSuffix}`
  );
}

responses.push(
  jsonResponse(200, {
    gameId: projectRef.gameId,
    projectDeleted: true,
    historyDeleted: true,
    cleanupPending: false,
  })
);
await lifecycle.deletePlaymeshProject({ projectRef });
assert.equal(requests.at(-1).options.method, 'DELETE');

responses.push(
  jsonResponse(409, {
    error: {
      code: 'project_id_conflict',
      message: 'packageName already belongs to another project',
      gameId: projectRef.gameId,
    },
  })
);
await assert.rejects(
  lifecycle.createPlaymeshProject({ projectRef, origin: 'duplicate' }),
  error =>
    error.code === 'project_id_conflict' &&
    error.message === 'packageName already belongs to another project'
);

const degraded = await lifecycle.runPlaymeshProjectLifecycleSoft({
  projectRef,
  action: async () => {
    throw new lifecycle.PlaymeshProjectLifecycleError(
      'project_id_conflict',
      '这个游戏标识已被占用。'
    );
  },
});
assert.equal(degraded.ok, false);
assert.equal(events.at(-1).detail.gameId, projectRef.gameId);
assert.equal(events.at(-1).detail.state, 'error');
assert.equal(events.at(-1).detail.error.code, 'project_id_conflict');
assert.equal(events.some(event => 'projectId' in event.detail), false);

process.stdout.write('GDevelop project lifecycle client tests passed.\n');
