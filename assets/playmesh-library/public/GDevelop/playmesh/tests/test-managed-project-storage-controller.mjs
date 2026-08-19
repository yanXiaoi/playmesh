import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshManagedProjectStorageController.js'
  ),
  'utf8'
);
const controllerModule = await import(`data:text/javascript;base64,${Buffer.from(
  source
).toString('base64')}`);
const commitFactorySource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshAuthoritativeProjectCommit.js'
  ),
  'utf8'
);
const commitFactoryModule = await import(
  `data:text/javascript;base64,${Buffer.from(
    commitFactorySource.replace(/^\/\/ @flow\s*/, '')
  ).toString('base64')}`
);

const createHarness = ({
  listFailure = false,
  openFailure = false,
  commitFailure = false,
} = {}) => {
  const calls = [];
  const statuses = [];
  const authoritativeProjects = [{ id: 'remote', gameId: 'com.example.a' }];
  const activeGameId = 'com.example.a';
  const authoritativeDiagnostics = [
    {
      code: 'project_metadata_invalid',
      entry: 'broken-project',
      gameId: null,
      messageKey: 'gdevelop.projectList.diagnostics.project_metadata_invalid',
    },
  ];
  const remoteOpen = {
    content: { source: 'app-current' },
    storedProject: { id: 'remote' },
  };
  const prepared = {
    fileMetadata: { fileIdentifier: 'remote', gameId: 'com.example.a' },
    snapshot: {
      projectFiles: [{ path: 'game.json', content: {} }],
      resources: [],
    },
    storedProject: { id: 'remote' },
  };
  const controller = controllerModule.createPlaymeshManagedProjectStorageController(
    {
      listAuthoritativeProjects: async () => {
        calls.push('list-app');
        if (listFailure) throw new Error('App unavailable');
        return {
          activeGameId,
          projects: authoritativeProjects,
          diagnostics: authoritativeDiagnostics,
        };
      },
      openAuthoritativeProject: async () => {
        calls.push('open-app');
        if (openFailure) throw new Error('current unavailable');
        return remoteOpen;
      },
      prepareProject: async () => {
        calls.push('prepare');
        return prepared;
      },
      commitAuthoritativeProject: async () => {
        calls.push('commit-app');
        if (commitFailure) throw new Error('Gateway commit failed');
        return { revision: 2 };
      },
      reportStatus: status => statuses.push(status),
    }
  );
  return {
    controller,
    calls,
    statuses,
    authoritativeProjects,
    activeGameId,
    authoritativeDiagnostics,
    remoteOpen,
  };
};

{
  const harness = createHarness();
  assert.deepEqual(await harness.controller.listProjects(), {
    activeGameId: harness.activeGameId,
    projects: harness.authoritativeProjects,
    diagnostics: harness.authoritativeDiagnostics,
    source: 'authoritative',
  });
  assert.deepEqual(harness.calls, ['list-app']);
}

assert.equal(
  controllerModule.selectPlaymeshInitialProject,
  undefined,
  'startup must never select an active or sole project automatically'
);

{
  const harness = createHarness({ listFailure: true });
  await assert.rejects(harness.controller.listProjects(), /App unavailable/);
  assert.deepEqual(harness.calls, ['list-app']);
}

{
  const harness = createHarness();
  const opened = await harness.controller.openProject({
    fileIdentifier: 'remote',
    gameId: 'com.example.a',
  });
  assert.equal(opened, harness.remoteOpen);
  assert.deepEqual(harness.calls, ['open-app']);
}

{
  const harness = createHarness({ openFailure: true });
  await assert.rejects(
    harness.controller.openProject({
      fileIdentifier: 'remote',
      gameId: 'com.example.a',
    }),
    /current unavailable/
  );
  assert.deepEqual(harness.calls, ['open-app']);
}

{
  const calls = [];
  let openCalls = 0;
  const opened = { source: 'authoritative-current' };
  const result = await controllerModule.openPlaymeshProjectWithPreparedRestoreRecovery(
    {
      openProject: async () => {
        calls.push('open');
        openCalls++;
        if (openCalls === 1) {
          throw Object.assign(new Error('project locked'), {
            code: 'gdevelop_project_mutation_locked',
          });
        }
        return opened;
      },
      recoverPreparedRestore: async () => {
        calls.push('recover:PREPARED');
        calls.push('abort:ABORTED');
        return true;
      },
    }
  );
  assert.equal(result, opened);
  assert.deepEqual(calls, [
    'open',
    'recover:PREPARED',
    'abort:ABORTED',
    'open',
  ]);
}

{
  const calls = [];
  const locked = Object.assign(new Error('commit already requested'), {
    code: 'gdevelop_project_mutation_locked',
  });
  await assert.rejects(
    controllerModule.openPlaymeshProjectWithPreparedRestoreRecovery({
      openProject: async () => {
        calls.push('open');
        throw locked;
      },
      recoverPreparedRestore: async () => {
        calls.push('recover:COMMIT_REQUESTED');
        return false;
      },
    }),
    error => error === locked
  );
  assert.deepEqual(calls, ['open', 'recover:COMMIT_REQUESTED']);
}

{
  const calls = [];
  const unavailable = Object.assign(new Error('gateway unavailable'), {
    code: 'history_network_error',
  });
  await assert.rejects(
    controllerModule.openPlaymeshProjectWithPreparedRestoreRecovery({
      openProject: async () => {
        calls.push('open');
        throw unavailable;
      },
      recoverPreparedRestore: async () => {
        calls.push('recover');
        return true;
      },
    }),
    error => error === unavailable
  );
  assert.deepEqual(calls, ['open']);
}

{
  const harness = createHarness();
  const saved = await harness.controller.saveProject({});
  assert.equal(saved.authoritativeResult.revision, 2);
  assert.deepEqual(harness.calls, ['prepare', 'commit-app']);
}

{
  const lifecycleCalls = [];
  const historyResult = {
    historyCreated: false,
    deduplicated: false,
    version: { revision: 7 },
  };
  const commitAuthoritativeProject = commitFactoryModule.createPlaymeshAuthoritativeProjectCommit(
    {
      createProjectRef: gameId => ({ gameId }),
      ensureGameId: () => 'com.example.fallback',
      commitNewProjectAllocation: async () => {
        throw new Error('open autosave must not allocate');
      },
      commitLifecycleAndHistory: async options => {
        lifecycleCalls.push(options);
        return historyResult;
      },
    }
  );
  const prepared = {
    fileMetadata: {
      fileIdentifier: 'autosave-file',
      gameId: 'com.example.autosave',
    },
    snapshot: { projectFiles: [], resources: [] },
  };
  const controller = controllerModule.createPlaymeshManagedProjectStorageController(
    {
      listAuthoritativeProjects: async () => ({
        activeGameId: null,
        projects: [],
        diagnostics: [],
      }),
      openAuthoritativeProject: async () => ({}),
      prepareProject: async () => prepared,
      commitAuthoritativeProject,
      reportStatus() {},
    }
  );
  const saved = await controller.saveProject({
    project: {},
    fileMetadata: prepared.fileMetadata,
    origin: 'open',
    source: 'system',
    reason: 'autosave',
    mutationLease: { epoch: 1 },
    shouldBindFileIdentifier: false,
  });
  assert.equal(
    saved.authoritativeResult,
    historyResult,
    'the real provider commit adapter must return historyCreated to the managed controller'
  );
  assert.equal(lifecycleCalls.length, 1);
  assert.equal(lifecycleCalls[0].reason, 'autosave');
  assert.equal(lifecycleCalls[0].source, 'system');
}

{
  const harness = createHarness({ commitFailure: true });
  await assert.rejects(
    harness.controller.saveProject({}),
    /Gateway commit failed/
  );
  assert.deepEqual(harness.calls, ['prepare', 'commit-app']);
  assert.equal(
    harness.statuses.some(status => status.operation === 'save'),
    false,
    'Gateway 失败时不能发布保存成功状态'
  );
}

process.stdout.write(
  'GDevelop managed project storage controller tests passed.\n'
);
