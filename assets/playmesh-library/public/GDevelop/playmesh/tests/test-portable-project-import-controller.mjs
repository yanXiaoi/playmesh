import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshProjectImport/PlaymeshPortableProjectImportController.js'
);
const source = (await readFile(sourcePath, 'utf8'))
  .replace(/^import .*;\r?\n/gm, '')
  .replace(
    '// @flow',
    `// @flow
const importPlaymeshPortableProject = globalThis.__portableImportControllerMocks.importProject;
const generateCopiedGDevelopGameId = globalThis.__portableImportControllerMocks.generatePackageName;`
  );

const loadController = async ({ importProject, generatePackageName }) => {
  globalThis.__portableImportControllerMocks = {
    importProject,
    generatePackageName,
  };
  return import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}#${Math.random()}`);
};

const archiveBlob = new Blob(['portable-project']);

{
  const calls = [];
  const controller = await loadController({
    importProject: async options => {
      calls.push(options);
      return { status: 'imported', fileMetadata: { fileIdentifier: 'a' } };
    },
    generatePackageName: () => 'com.playmesh.unused',
  });
  let confirmed = false;
  const result = await controller.importPortableProjectWithCopyDecision({
    archiveBlob,
    confirmCopy: () => {
      confirmed = true;
      return true;
    },
  });
  assert.equal(result.status, 'imported');
  assert.equal(confirmed, false);
  assert.deepEqual(calls, [{ archiveBlob }]);
}

{
  const projectJsonBlob = new Blob(['{"properties":{}}'], {
    type: 'application/json',
  });
  const calls = [];
  const controller = await loadController({
    importProject: async options => {
      calls.push(options);
      return calls.length === 1
        ? {
            status: 'needsNewPackageName',
            reason: 'allocation_conflict',
            sourcePackageName: 'com.example.original',
          }
        : {
            status: 'imported',
            identityMode: 'copy',
            packageName: options.packageName,
          };
    },
    generatePackageName: () => 'com.playmesh.rawcopy',
  });
  const result = await controller.importPortableProjectWithCopyDecision({
    projectJsonBlob,
    confirmCopy: () => true,
  });
  assert.equal(result.status, 'imported');
  assert.deepEqual(calls, [
    { projectJsonBlob },
    {
      projectJsonBlob,
      packageName: 'com.playmesh.rawcopy',
      identityMode: 'copy',
    },
  ]);
}

{
  const calls = [];
  const controller = await loadController({
    importProject: async options => {
      calls.push(options);
      return {
        status: 'needsNewPackageName',
        reason: 'allocation_conflict',
        sourcePackageName: 'com.example.original',
      };
    },
    generatePackageName: () => 'com.playmesh.copy',
  });
  const result = await controller.importPortableProjectWithCopyDecision({
    archiveBlob,
    confirmCopy: decision => {
      assert.deepEqual(decision, {
        reason: 'allocation_conflict',
        sourcePackageName: 'com.example.original',
        suggestedPackageName: 'com.playmesh.copy',
      });
      return false;
    },
  });
  assert.deepEqual(result, { status: 'cancelled' });
  assert.deepEqual(calls, [{ archiveBlob }]);
}

{
  const calls = [];
  const controller = await loadController({
    importProject: async options => {
      calls.push(options);
      return calls.length === 1
        ? {
            status: 'needsNewPackageName',
            reason: 'allocation_conflict',
            sourcePackageName: 'com.example.original',
          }
        : {
            status: 'imported',
            identityMode: 'copy',
            packageName: options.packageName,
            projectUuid: 'new-project-uuid',
          };
    },
    generatePackageName: () => 'com.playmesh.copy',
  });
  const result = await controller.importPortableProjectWithCopyDecision({
    archiveBlob,
    confirmCopy: () => true,
  });
  assert.equal(result.status, 'imported');
  assert.equal(result.identityMode, 'copy');
  assert.deepEqual(calls, [
    { archiveBlob },
    {
      archiveBlob,
      packageName: 'com.playmesh.copy',
      identityMode: 'copy',
    },
  ]);
}

{
  const controller = await loadController({
    importProject: async () => ({ status: 'recovering' }),
    generatePackageName: () => 'com.playmesh.copy',
  });
  const result = await controller.importPortableProjectWithCopyDecision({
    archiveBlob,
    confirmCopy: () => true,
  });
  assert.equal(result.status, 'recovering');
}

process.stdout.write(
  'GDevelop portable project import controller tests passed.\n'
);
