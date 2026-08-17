import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const importSource = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}`);

let controllerSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjectRekey/PlaymeshProjectRekeyController.js'
  ),
  'utf8'
);
controllerSource = controllerSource.replace(
  /import(?: type)?[\s\S]*? from '[^']+';\r?\n/g,
  ''
);
controllerSource = `
class PlaymeshProjectRekeyCoordinatorError extends Error {
  constructor(code, message, { rollbackCompleted = false, blocked = false } = {}) {
    super(message);
    this.code = code;
    this.rollbackCompleted = rollbackCompleted;
    this.blocked = blocked;
  }
}
export { PlaymeshProjectRekeyCoordinatorError };
const rekeyPlaymeshProjectLocalIdentity = options => globalThis.__executeRekey(options);
const recoverPlaymeshProjectRekeyLocalIdentity = options => globalThis.__recoverRekey(options);
const readPlaymeshProjectRekeyBrowserState = fileIdentifier =>
  globalThis.__readBrowserState(fileIdentifier);
${controllerSource}`;
const controllerModule = await importSource(transformFlow(controllerSource));

const oldGameId = 'com.playmesh.game.old001';
const newGameId = 'com.playmesh.game.new001';
const fileMetadata = {
  fileIdentifier: 'file-a',
  name: 'Source',
  gameId: oldGameId,
  lastModifiedDate: 1,
};
const prepared = gameId => ({
  fileMetadata: { ...fileMetadata, gameId },
  snapshot: { project: {}, resources: [] },
  storedProject: {
    id: fileMetadata.fileIdentifier,
    name: gameId === oldGameId ? 'Source' : 'Target',
    gameId,
    projectJson: '{}',
    resources: [],
    savedAt: 1,
  },
});
const committedResult = {
  outcome: 'committed',
  fileMetadata: { ...fileMetadata, gameId: newGameId },
};
const rolledBackResult = {
  outcome: 'rolled_back',
  fileMetadata,
};

const executionOptions = overrides => {
  let currentGameId = oldGameId;
  const calls = [];
  return {
    calls,
    options: {
      oldGameId,
      newGameId,
      fileMetadata,
      async prepareCurrentProject(metadata) {
        calls.push(['prepare', metadata.gameId]);
        return prepared(currentGameId);
      },
      async applyTargetProperties() {
        calls.push(['apply']);
        currentGameId = newGameId;
      },
      async restoreSourceProperties() {
        calls.push(['restore']);
        currentGameId = oldGameId;
      },
      ...overrides,
    },
  };
};

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  const states = [];
  controller.subscribe(state => states.push(state));
  globalThis.__executeRekey = async options => {
    options.dependencies.notify('persisting_source');
    options.dependencies.notify('preparing');
    options.dependencies.notify('committing');
    options.dependencies.notify('switching_browser');
    options.dependencies.notify('acknowledging');
    return committedResult;
  };
  const execution = executionOptions();
  const result = await controller.execute(execution.options);
  assert.equal(result.outcome, 'committed');
  assert.equal(controller.getState().status, 'succeeded');
  assert.equal(controller.getState().canClose, true);
  assert.equal(
    states.filter(state => state.busy).every(state => state.canClose === false),
    true
  );
  assert.deepEqual(execution.calls, [
    ['prepare', oldGameId],
    ['apply'],
    ['prepare', newGameId],
  ]);
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  globalThis.__executeRekey = async options => {
    options.dependencies.notify('rolling_back');
    return rolledBackResult;
  };
  const execution = executionOptions();
  const result = await controller.execute(execution.options);
  assert.equal(result.outcome, 'rolled_back');
  assert.equal(controller.getState().status, 'rolled_back');
  assert.equal(controller.getState().rollbackCompleted, true);
  assert.equal(controller.getState().canClose, true);
  assert.equal(execution.calls.some(([name]) => name === 'restore'), true);
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  globalThis.__executeRekey = async () => {
    throw new controllerModule.PlaymeshProjectRekeyCoordinatorError(
      'browser_source_restore_failed',
      'blocked',
      { blocked: true }
    );
  };
  const execution = executionOptions();
  await assert.rejects(controller.execute(execution.options));
  assert.equal(controller.getState().status, 'blocked');
  assert.equal(controller.getState().canClose, false);
  assert.equal(execution.calls.some(([name]) => name === 'restore'), false);

  let reloaded = false;
  globalThis.__recoverRekey = async options => {
    options.dependencies.notify('recovering');
    return rolledBackResult;
  };
  const recovered = await controller.recover({
    fileMetadata,
    reload: () => {
      reloaded = true;
    },
  });
  assert.equal(recovered.outcome, 'rolled_back');
  assert.equal(reloaded, true);
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  let release;
  globalThis.__executeRekey = () =>
    new Promise(resolve => {
      release = resolve;
    });
  const first = controller.execute(executionOptions().options);
  await Promise.resolve();
  await assert.rejects(
    controller.execute(executionOptions().options),
    error => error.code === 'rekey_already_running'
  );
  release(committedResult);
  await first;
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  globalThis.__executeRekey = async () => {
    throw new controllerModule.PlaymeshProjectRekeyCoordinatorError(
      'browser_target_write_failed',
      'rolled back',
      { rollbackCompleted: true }
    );
  };
  const execution = executionOptions();
  await assert.rejects(controller.execute(execution.options));
  assert.equal(controller.getState().status, 'failed');
  assert.equal(controller.getState().rollbackCompleted, true);
  assert.equal(controller.getState().canClose, true);
  assert.equal(execution.calls.some(([name]) => name === 'restore'), true);
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  globalThis.__executeRekey = async () => {
    throw new Error('apply failed');
  };
  const execution = executionOptions({
    async restoreSourceProperties() {
      throw new Error('live restore failed');
    },
  });
  await assert.rejects(controller.execute(execution.options));
  assert.equal(controller.getState().status, 'blocked');
  assert.equal(controller.getState().errorCode, 'live_source_restore_failed');
}

{
  const controller = new controllerModule.PlaymeshProjectRekeyController();
  let recoverCalls = 0;
  globalThis.__readBrowserState = async () => ({
    project: prepared(oldGameId).storedProject,
    journal: null,
  });
  globalThis.__recoverRekey = async () => {
    recoverCalls++;
    return committedResult;
  };
  const idle = await controller.recoverIfPending({ fileMetadata });
  assert.equal(idle, null);
  assert.equal(recoverCalls, 0);

  let reloaded = false;
  globalThis.__readBrowserState = async () => ({
    project: prepared(newGameId).storedProject,
    journal: { txId: 'tx-a' },
  });
  const recovered = await controller.recoverIfPending({
    fileMetadata,
    reload: () => {
      reloaded = true;
    },
  });
  assert.equal(recovered.outcome, 'committed');
  assert.equal(recoverCalls, 1);
  assert.equal(reloaded, true);
}

process.stdout.write('GDevelop project rekey controller tests passed.\n');
