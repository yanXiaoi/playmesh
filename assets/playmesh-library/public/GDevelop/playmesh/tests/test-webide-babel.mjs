import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const dependencyCacheRoot = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/cache/deps'
);
const dependencyCaches = existsSync(dependencyCacheRoot)
  ? await readdir(dependencyCacheRoot)
  : [];
const productionAppPackage = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/profiles/default/build-source/newIDE/app/package.json'
);
const appPackage = [
  productionAppPackage,
  ...dependencyCaches.map(entry =>
    path.join(dependencyCacheRoot, entry, 'package.json')
  ),
].find(candidate =>
  existsSync(
    path.join(path.dirname(candidate), 'node_modules/@babel/core/package.json')
  )
);

assert.ok(
  appPackage && existsSync(appPackage),
  'the fixed WebIDE dependency cache is required for Flow executable contracts'
);

const appRequire = createRequire(appPackage);
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const craEslintParser = appRequire('@babel/eslint-parser');
const craProductionPreset = appRequire.resolve('babel-preset-react-app/prod');
export const transformFlow = source =>
  transformSync(source, {
    babelrc: false,
    configFile: false,
    plugins: [[flowStripPlugin, { all: true }]],
    sourceType: 'module',
  }).code;

const historyClientPath = path.resolve(
  repositoryRoot,
  'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryClient.js'
);

const embeddedExternalEditorWindowPath = path.resolve(
  repositoryRoot,
  'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src/ResourcesList/PlaymeshEmbeddedExternalEditorWindow.js'
);
const embeddedExternalEditorWindowSource = readFileSync(
  embeddedExternalEditorWindowPath,
  'utf8'
);
assert.doesNotThrow(
  () => transformFlow(embeddedExternalEditorWindowSource),
  'PlaymeshEmbeddedExternalEditorWindow.js must parse after Flow stripping'
);
assert.doesNotThrow(
  () =>
    transformSync(embeddedExternalEditorWindowSource, {
      babelrc: false,
      configFile: false,
      filename: embeddedExternalEditorWindowPath,
      presets: [craProductionPreset],
      sourceType: 'module',
    }),
  'PlaymeshEmbeddedExternalEditorWindow.js must compile with the exact CRA production preset'
);
assert.doesNotThrow(
  () => transformFlow(readFileSync(historyClientPath, 'utf8')),
  'PlaymeshHistoryClient.js must parse after Flow stripping'
);

for (const relativePath of [
  'PlaymeshHistory/PlaymeshHistoryRestoreClient.js',
  'PlaymeshHistory/PlaymeshHistoryRestoreCoordinator.js',
  'PlaymeshHistory/PlaymeshHistoryRestoreProtocol.js',
  'PlaymeshProjectConfig/PlaymeshProjectConfigProtocol.js',
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshAuthoritativeProjectCommit.js',
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshLocalResourceFetcher.js',
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshManagedProjectStorageController.js',
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectFiles.js',
]) {
  const filePath = path.resolve(
    repositoryRoot,
    'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src',
    relativePath
  );
  assert.doesNotThrow(
    () => transformFlow(readFileSync(filePath, 'utf8')),
    `${relativePath} must parse after Flow stripping`
  );
}

for (const relativePath of [
  'ProjectsStorage/PlaymeshLocalStorageProvider/index.js',
]) {
  const filePath = path.resolve(
    repositoryRoot,
    'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src',
    relativePath
  );
  assert.doesNotThrow(
    () =>
      transformSync(readFileSync(filePath, 'utf8'), {
        babelrc: false,
        configFile: false,
        filename: path.resolve(
          path.dirname(appPackage),
          'src',
          relativePath
        ),
        presets: [craProductionPreset],
        sourceType: 'module',
      }),
    `${relativePath} must compile with the exact CRA production preset`
  );
}

for (const fileName of [
  'PlaymeshAiOfficialLocalEditorRunners.js',
  'PlaymeshAiJfxrYarnTools.js',
  'PlaymeshAiPiskelRunner.js',
  'PlaymeshAiExternalEditorResourceWriter.js',
  'PlaymeshAiPiskelTool.js',
]) {
  const filePath = path.resolve(
    repositoryRoot,
    'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src/PlaymeshAi',
    fileName
  );
  assert.doesNotThrow(
    () => transformFlow(readFileSync(filePath, 'utf8')),
    `${fileName} must parse after Flow stripping`
  );
}

const playmeshAiIntegrationPath = path.resolve(
  repositoryRoot,
  'assets/playmesh-library/public/GDevelop/playmesh/overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiIntegration.js'
);
const playmeshAiIntegrationSource = readFileSync(
  playmeshAiIntegrationPath,
  'utf8'
);
const craProductionParserOptions = {
  sourceType: 'module',
  requireConfigFile: false,
  filePath: playmeshAiIntegrationPath,
  babelOptions: {
    filename: playmeshAiIntegrationPath,
    presets: [craProductionPreset],
  },
};

assert.doesNotThrow(
  () =>
    craEslintParser.parseForESLint(
      playmeshAiIntegrationSource,
      craProductionParserOptions
    ),
  'PlaymeshAiIntegration.js must parse with the exact CRA production ESLint parser configuration'
);
