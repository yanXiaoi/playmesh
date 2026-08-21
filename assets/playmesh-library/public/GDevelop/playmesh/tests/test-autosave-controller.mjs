import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshProjectMutation/PlaymeshAutosaveController.js'
  ),
  'utf8'
);
const executableSource = transformFlow(source);
const preferenceSource = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshLocalization/PlaymeshAutosavePreference.js'
  ),
  'utf8'
);
assert.doesNotThrow(() => transformFlow(preferenceSource));
const controllerModule = await import(
  `data:text/javascript;base64,${Buffer.from(
    executableSource
  ).toString('base64')}`
);

const project = {};

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  let writes = 0;
  const save = async () => {
    writes += 1;
  };

  assert.deepEqual(
    await controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 1,
      save,
    }),
    { saved: true, generation: 1 }
  );
  assert.deepEqual(
    await controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 1,
      save,
    }),
    { skipped: 'unchanged' }
  );
  assert.equal(writes, 1, 'an unchanged minute tick must not write again');

  assert.deepEqual(
    await controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 2,
      save,
    }),
    { saved: true, generation: 2 }
  );
  assert.equal(writes, 2, 'a new edit generation must create a new snapshot');
}

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  let releaseWrite;
  const pendingWrite = new Promise(resolve => {
    releaseWrite = resolve;
  });
  const first = controller.autosave({
    project,
    fileIdentifier: 'project-a',
    generation: 4,
    save: () => pendingWrite,
  });
  assert.deepEqual(
    await controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 5,
      save: async () => {},
    }),
    { skipped: 'autosave_in_progress' },
    'preview and timer triggers must share one in-flight write'
  );
  releaseWrite();
  assert.deepEqual(await first, { saved: true, generation: 4 });

  assert.deepEqual(
    await controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 5,
      save: async () => {},
    }),
    { saved: true, generation: 5 },
    'edits arriving during a write must remain for the next autosave'
  );
}

for (const skipped of ['project_mutation_locked', 'history_not_created']) {
  const controller = controllerModule.createPlaymeshAutosaveController();
  let writes = 0;
  const attempt = () =>
    controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 8,
      save: async () => {
        writes += 1;
        return writes === 1 ? { skipped } : undefined;
      },
    });
  assert.deepEqual(await attempt(), { skipped });
  assert.deepEqual(await attempt(), { saved: true, generation: 8 });
  assert.equal(writes, 2, `${skipped} must not advance the success cursor`);
}

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  let writes = 0;
  const periodicAttempt = generation =>
    controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation,
      trigger: 'periodic',
      save: async () => {
        writes += 1;
        if (writes === 1) {
          throw Object.assign(new Error('conflict'), {
            code: 'gdevelop_revision_conflict',
          });
        }
      },
    });
  await assert.rejects(() => periodicAttempt(13), /conflict/);
  assert.deepEqual(await periodicAttempt(13), {
    skipped: 'revision_conflict',
  });
  assert.equal(
    writes,
    1,
    'the timer must not automatically rebase and replay a conflicted generation'
  );
  assert.deepEqual(await periodicAttempt(14), {
    saved: true,
    generation: 14,
  });
  assert.equal(writes, 2, 'a new local edit generation may save after conflict');
}

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  let writes = 0;
  const attempt = () =>
    controller.autosave({
      project,
      fileIdentifier: 'project-a',
      generation: 15,
      trigger: 'periodic',
      save: async () => {
        writes += 1;
        if (writes === 1) throw new Error('temporary failure');
      },
    });
  await assert.rejects(attempt, /temporary failure/);
  assert.deepEqual(await attempt(), { saved: true, generation: 15 });
  assert.equal(writes, 2, 'a non-conflict failure must remain retryable');
}

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  const projectA = {};
  const projectB = {};
  let projectAWrites = 0;
  await assert.rejects(() =>
    controller.autosave({
      project: projectA,
      fileIdentifier: 'shared-file',
      generation: 16,
      trigger: 'periodic',
      save: async () => {
        projectAWrites += 1;
        throw Object.assign(new Error('conflict'), {
          code: 'gdevelop_revision_conflict',
        });
      },
    })
  );
  assert.deepEqual(
    await controller.autosave({
      project: projectA,
      fileIdentifier: 'shared-file',
      generation: 16,
      trigger: 'preview',
      save: async () => {
        projectAWrites += 1;
      },
    }),
    { skipped: 'revision_conflict' },
    'preview must not replay a generation blocked by a timer conflict'
  );
  assert.equal(projectAWrites, 1);

  let projectBWrites = 0;
  assert.deepEqual(
    await controller.autosave({
      project: projectB,
      fileIdentifier: 'shared-file',
      generation: 16,
      trigger: 'periodic',
      save: async () => {
        projectBWrites += 1;
      },
    }),
    { saved: true, generation: 16 },
    'a conflict must not block another project with the same file identifier'
  );
  assert.equal(projectBWrites, 1);

  let otherFileWrites = 0;
  assert.deepEqual(
    await controller.autosave({
      project: projectA,
      fileIdentifier: 'other-file',
      generation: 16,
      trigger: 'preview',
      save: async () => {
        otherFileWrites += 1;
      },
    }),
    { saved: true, generation: 16 },
    'a conflict must not block another file identifier in the same project'
  );
  assert.equal(otherFileWrites, 1);
  assert.deepEqual(
    await controller.autosave({
      project: projectA,
      fileIdentifier: 'shared-file',
      generation: 16,
      trigger: 'periodic',
      save: async () => {
        projectAWrites += 1;
      },
    }),
    { skipped: 'revision_conflict' },
    'saving another project/file must not erase the original conflict cursor'
  );
  assert.equal(projectAWrites, 1);
  assert.deepEqual(
    await controller.autosave({
      project: projectA,
      fileIdentifier: 'shared-file',
      generation: 17,
      trigger: 'preview',
      save: async () => {
        projectAWrites += 1;
      },
    }),
    { saved: true, generation: 17 },
    'a newer generation may resume autosave after a conflict'
  );
  assert.equal(projectAWrites, 2);
}

{
  const controller = controllerModule.createPlaymeshAutosaveController();
  const sameProjectAfterManualSeal = project;
  await controller.autosave({
    project: sameProjectAfterManualSeal,
    fileIdentifier: 'project-a',
    generation: 20,
    save: async () => {},
  });
  assert.deepEqual(
    await controller.autosave({
      project: sameProjectAfterManualSeal,
      fileIdentifier: 'project-a',
      generation: 21,
      save: async () => {},
    }),
    { saved: true, generation: 21 },
    'the monotonic generation must survive the official dirty-count seal'
  );
}

process.stdout.write('GDevelop autosave controller tests passed.\n');
