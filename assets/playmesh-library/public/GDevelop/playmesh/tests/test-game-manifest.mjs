import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { runInNewContext } from 'node:vm';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const require = createRequire(import.meta.url);
const manifestModulePath = path.resolve(
  repositoryRoot,
  'assets/playmesh-library/public/developer/playmesh-game-manifest.js'
);
const manifestSource = await readFile(manifestModulePath, 'utf8');
const manifestApi = require(manifestModulePath);
const fixtures = JSON.parse(
  await readFile(
    path.resolve(
      repositoryRoot,
      'test/fixtures/playmesh_game_manifest_parity.json'
    ),
    'utf8'
  )
);

const clone = value => JSON.parse(JSON.stringify(value));
const setPath = (target, dottedPath, value) => {
  const parts = dottedPath.split('.');
  let current = target;
  for (const part of parts.slice(0, -1)) current = current[part];
  current[parts.at(-1)] = value;
};
const fixtureManifest = fixture => {
  const manifest = clone(fixtures.baseManifest);
  for (const [key, value] of Object.entries(fixture.set || {})) {
    manifest[key] = clone(value);
  }
  for (const [key, value] of Object.entries(fixture.add || {})) {
    manifest[key] = clone(value);
  }
  if (fixture.repeat) {
    setPath(
      manifest,
      fixture.repeat.path,
      fixture.repeat.character.repeat(fixture.repeat.count)
    );
  }
  return manifest;
};
const listJavaScriptFiles = async directory => {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listJavaScriptFiles(entryPath)));
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      files.push(entryPath);
    }
  }
  return files;
};

for (const fixture of fixtures.builderCases) {
  const manifest = manifestApi.buildGameManifest(fixture.input);
  assert.deepEqual(manifest, fixture.manifest, fixture.name);
  assert.equal(
    manifestApi.validateGameManifest(manifest).valid,
    true,
    fixture.name
  );
}
const opaqueConfig = {
  webRuntime: { multithreading: true },
  futureRuntime: { untouched: ['value'] },
};
const configManifest = manifestApi.buildGameManifest({
  ...fixtures.builderCases[0].input,
  config: opaqueConfig,
});
assert.deepEqual(configManifest.config, opaqueConfig);
assert.equal(manifestApi.validateGameManifest(configManifest).valid, true);
assert.equal(
  manifestApi.readGameManifestConfigValue(opaqueConfig, [
    'webRuntime',
    'multithreading',
  ]),
  true
);
for (const [config, path] of [
  [null, ['webRuntime']],
  ['opaque', ['webRuntime']],
  [opaqueConfig, []],
  [opaqueConfig, ['webRuntime', 'missing']],
]) {
  assert.equal(manifestApi.readGameManifestConfigValue(config, path), null);
}
for (const fixture of fixtures.validationCases) {
  const result = manifestApi.validateGameManifest(fixtureManifest(fixture));
  assert.equal(result.valid, fixture.valid, fixture.name);
}

const fill = value => bytes => bytes.fill(value);
const browserCryptoCalls = [];
const browserWindow = {
  crypto: {
    getRandomValues: bytes => {
      browserCryptoCalls.push(bytes.length);
      return bytes.fill(1);
    },
  },
};
runInNewContext(manifestSource, { window: browserWindow });
assert.deepEqual(
  Object.keys(browserWindow.PlaymeshGameManifest).sort(),
  Object.keys(manifestApi).sort()
);
assert.equal(
  browserWindow.PlaymeshGameManifest.generateGameId({ profile: 'source' }),
  'com.playmesh.game-bbbbbbbbbb'
);
assert.deepEqual(browserCryptoCalls, [10]);
assert.equal(
  manifestApi.generateGameId({ profile: 'source', randomValues: fill(0) }),
  'com.playmesh.game-aaaaaaaaaa'
);
const androidGameId = manifestApi.generateGameId({
  profile: 'android',
  randomValues: fill(0),
});
assert.equal(androidGameId, 'com.playmesh.game.gaaaaaaaaaa');
const newProjectIdFixture = JSON.parse(
  await readFile(
    path.resolve(repositoryRoot, 'test/fixtures/new_project_game_id.json'),
    'utf8'
  )
);
for (const value of newProjectIdFixture.valid) {
  assert.equal(manifestApi.isValidNewProjectGameId(value), true, value);
}
for (const value of newProjectIdFixture.invalid) {
  assert.equal(manifestApi.isValidNewProjectGameId(value), false, value);
}
const boundaryProjectId =
  newProjectIdFixture.boundary.prefix +
  newProjectIdFixture.boundary.segmentCharacter.repeat(
    newProjectIdFixture.maxLength -
      newProjectIdFixture.boundary.prefix.length
  );
assert.equal(manifestApi.isValidNewProjectGameId(boundaryProjectId), true);
assert.equal(
  manifestApi.isValidNewProjectGameId(
    boundaryProjectId + newProjectIdFixture.boundary.segmentCharacter
  ),
  false
);
assert.equal(
  manifestApi.isValidNewProjectGameId(
    manifestApi.generateGameId({ profile: 'android', randomValues: fill(2) })
  ),
  true
);

const controllerPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshManifest/PlaymeshGDevelopManifestController.js'
);
const runtimeInjectionPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection.js'
);
const runtimeInjectionSource = await readFile(runtimeInjectionPath, 'utf8');
const runtimeInjection = await import(`data:text/javascript;base64,${Buffer.from(
  runtimeInjectionSource
).toString('base64')}`);
const controllerCanonicalSource = await readFile(controllerPath, 'utf8');
let controllerSource = controllerCanonicalSource;
globalThis.__playmeshManifestApi = manifestApi;
globalThis.__playmeshRuntimeInjection = runtimeInjection;
controllerSource = controllerSource.replace(
  "import PlaymeshGameManifest from '../PlaymeshShared/GameManifest';",
  'const PlaymeshGameManifest = globalThis.__playmeshManifestApi;'
);
controllerSource = controllerSource.replace(
  `import {
  detectGDevelopMultiplayerActivation,
  ensureSdkPlaceholder,
  GDEVELOP_AUTHORITY_ENTRY,
  getPlaymeshMultiplayerRuntimeScriptTags,
  getPlaymeshMultiplayerRuntimeTextFiles,
  injectMultiplayerCompatibility,
  shouldInjectPlaymeshMultiplayerRuntime,
} from '../PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection';`,
  `const {
  detectGDevelopMultiplayerActivation,
  ensureSdkPlaceholder,
  GDEVELOP_AUTHORITY_ENTRY,
  getPlaymeshMultiplayerRuntimeScriptTags,
  getPlaymeshMultiplayerRuntimeTextFiles,
  injectMultiplayerCompatibility,
  shouldInjectPlaymeshMultiplayerRuntime,
} = globalThis.__playmeshRuntimeInjection;`
);
const controller = await import(`data:text/javascript;base64,${Buffer.from(
  controllerSource
).toString('base64')}`);

const overlaySourceRoot = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src'
);
const packageBuilderDefinitions = [];
for (const filePath of await listJavaScriptFiles(overlaySourceRoot)) {
  const source = await readFile(filePath, 'utf8');
  for (const match of source.matchAll(
    /\bexport const (createPlaymeshPackage(?:FileMap|Files))\b/g
  )) {
    packageBuilderDefinitions.push({
      name: match[1],
      relativePath: path
        .relative(overlaySourceRoot, filePath)
        .replace(/\\/g, '/'),
    });
  }
}
assert.deepEqual(packageBuilderDefinitions, [
  {
    name: 'createPlaymeshPackageFileMap',
    relativePath: 'PlaymeshManifest/PlaymeshGDevelopManifestController.js',
  },
]);
assert.doesNotMatch(controllerCanonicalSource, /createPlaymeshPackageFiles/);
assert.doesNotMatch(controllerCanonicalSource, /runtimeInjection/);

const projectState = {
  packageName: controller.GDEVELOP_DEFAULT_PACKAGE_NAME,
  version: '1.0.0',
  orientation: 'landscape',
};
const project = {
  getPackageName: () => projectState.packageName,
  setPackageName: value => {
    projectState.packageName = value;
  },
  getName: () => 'Visual Game',
  getAuthor: () => 'Visual Author',
  getDescription: () => 'Visual description',
  getVersion: () => projectState.version,
  getOrientation: () => projectState.orientation,
  getGameResolutionWidth: () => 1280,
  getGameResolutionHeight: () => 720,
};
const firstGameId = controller.ensureGDevelopGameId(project, {
  randomValues: fill(0),
});
assert.equal(firstGameId, 'com.playmesh.game.gaaaaaaaaaa');
assert.equal(controller.ensureGDevelopGameId(project), firstGameId);
assert.equal(project.getPackageName(), firstGameId);
assert.equal(
  controller.generateCopiedGDevelopGameId({ randomValues: fill(1) }),
  'com.playmesh.game.gbbbbbbbbbb'
);

const firstManifest = controller.buildGDevelopGameManifest({
  project,
  sdkVersion: '4.1.0',
  appSdkVersion: '3.3.0',
  lastModifiedAt: 10,
});
projectState.version = '1.0.1';
const updatedManifest = controller.buildGDevelopGameManifest({
  project,
  sdkVersion: '4.1.0',
  appSdkVersion: '3.3.0',
  lastModifiedAt: 11,
});
assert.equal(firstManifest.id, firstGameId);
assert.equal(updatedManifest.id, firstGameId);
assert.equal(updatedManifest.version, '1.0.1');
assert.deepEqual(updatedManifest.config, {
  webRuntime: { multithreading: false },
});
const threadedManifest = controller.buildGDevelopGameManifest({
  project,
  sdkVersion: '4.1.0',
  appSdkVersion: '3.3.0',
  webRuntimeMultithreading: true,
});
assert.deepEqual(threadedManifest.config, {
  webRuntime: { multithreading: true },
});
const stableMetadataGameId = 'com.playmesh.game.gmetadata01';
const metadataManifest = controller.buildGDevelopGameManifest({
  project,
  gameId: stableMetadataGameId,
  sdkVersion: '4.1.0',
  appSdkVersion: '3.3.0',
});
assert.equal(metadataManifest.id, stableMetadataGameId);
assert.equal(
  project.getPackageName(),
  firstGameId,
  'stable fileMetadata gameId must not rewrite the packageName draft'
);

projectState.orientation = 'default';
assert.equal(
  controller.getPlaymeshOrientationFromGDevelop(project),
  'landscape'
);
projectState.orientation = 'landscape';

globalThis.global.gd = {
  UsedExtensionsFinder: {
    scanProject: () => ({
      getUsedExtensions: () => ({
        toNewVectorString: () => ({
          toJSArray: () => ['BuiltinObject', 'Multiplayer'],
        }),
      }),
    }),
  },
};
assert.equal(controller.isGDevelopMultiplayerProject(project), true);
globalThis.global.gd.UsedExtensionsFinder.scanProject = () => ({
  getUsedExtensions: () => ({
    toNewVectorString: () => ({
      toJSArray: () => ['BuiltinObject'],
    }),
  }),
});
assert.equal(
  controller.isGDevelopMultiplayerProject(project),
  false,
  '明确 disabled 必须发布纯单机包'
);
globalThis.global.gd.UsedExtensionsFinder.scanProject = () => {
  throw new Error('upstream scan failed');
};
assert.equal(
  controller.isGDevelopMultiplayerProject(project),
  false,
  '探测异常返回 unknown，但不能把清单提升为多人'
);
assert.equal(
  controller.resolveGDevelopMultiplayerManifestMode({
    multiplayerActivation: 'unknown',
  }),
  'solo'
);
assert.equal(
  controller.resolveGDevelopMultiplayerManifestMode({
    multiplayerActivation: 'unknown',
    explicitMultiplayer: true,
  }),
  'multiplayer'
);
assert.equal(
  controller.resolveGDevelopMultiplayerManifestMode({
    multiplayerActivation: 'enabled',
  }),
  'multiplayer'
);
assert.equal(
  controller.resolveGDevelopMultiplayerManifestMode({
    multiplayerActivation: 'disabled',
    explicitMultiplayer: false,
  }),
  'solo'
);
assert.equal(
  controller.resolveGDevelopRuntimeActivation({
    multiplayerActivation: 'unknown',
  }),
  'unknown'
);

const htmlBlob = new Blob([new Uint8Array([1, 2, 3])], {
  type: 'application/octet-stream',
});
const authorityBootstrapSource =
  '(function(){globalThis.playmeshGDevelopAuthorityBootstrap={};})();';
const multiplayerBridgeSource =
  '(function(){Symbol.for("playmesh.runtime.backends.v1");Symbol.for("playmesh.gdevelop.multiplayer.coordinator.v1");})();';
const fpsProbeSource =
  '(function(){Symbol.for("playmesh.gdevelop.fps-probe.v1");const performanceApi={reportFrame(){}};performanceApi.reportFrame();})();';
const exportedRuntimeScriptNames = [
  'gdjs.js',
  'data.js',
  'code0.js',
  'code3.js',
  'code12.js',
];
const exportedRuntimeHtml =
  '<!doctype html><html><head>' +
  exportedRuntimeScriptNames
    .map(name => `<script src="${name}"></script>`)
    .join('') +
  '</head><body><script>new gdjs.RuntimeGame(gdjs.projectData);</script>' +
  '</body></html>';
const fileMap = controller.createPlaymeshPackageFileMap({
  resourcesDownloadOutput: {
    textFiles: [
      {
        filePath: '/export/index.html',
        text: exportedRuntimeHtml,
      },
      ...exportedRuntimeScriptNames.map(name => ({
        filePath: `/export/${name}`,
        text: `// ${name}`,
      })),
    ],
    blobFiles: [{ filePath: '/export/assets/game.bin', blob: htmlBlob }],
  },
  manifest: updatedManifest,
  fpsProbeSource,
  multiplayerBridgeSource,
  authorityBootstrapSource,
});
assert.deepEqual([...fileMap.keys()].sort(), [
  'app/assets/game.bin',
  'app/code0.js',
  'app/code12.js',
  'app/code3.js',
  'app/data.js',
  'app/gdjs.js',
  'app/index.html',
  'app/static/js/service/index.js',
  'app/static/js/service/playmesh-gdevelop-fps-probe.js',
  'app/static/js/service/playmesh-multiplayer-bridge.js',
  'main.json',
]);
assert.equal(fileMap.get('app/index.html').kind, 'text');
assert.equal(fileMap.get('app/assets/game.bin').blob, htmlBlob);
assert.equal(fileMap.has('game.json'), false);
assert.equal(JSON.parse(fileMap.get('main.json').text).id, firstGameId);
const soloHtml = fileMap.get('app/index.html').text;
const runtimeGameConstructionIndex = soloHtml.indexOf(
  'new gdjs.RuntimeGame'
);
assert.notEqual(runtimeGameConstructionIndex, -1);
const generatedProjectScripts = [...fileMap.keys()].filter(filePath =>
  /^app\/(?:data|code\d+)\.js$/.test(filePath)
);
assert.equal(
  generatedProjectScripts.some(filePath => /^app\/code\d+\.js$/.test(filePath)),
  true,
  'the contract fixture must exercise generated scene code without assuming only code0.js'
);
for (const filePath of generatedProjectScripts) {
  const relativePath = filePath.slice('app/'.length);
  const scriptPosition = soloHtml.search(
    new RegExp(`<script\\s+[^>]*src=["']${relativePath}["'][^>]*>`, 'i')
  );
  assert.notEqual(
    scriptPosition,
    -1,
    `${relativePath} must be referenced by the exported index.html`
  );
  assert.ok(
    scriptPosition < runtimeGameConstructionIndex,
    `${relativePath} must load before gdjs.RuntimeGame is constructed`
  );
}
const localScriptReferences = [...soloHtml.matchAll(
  /<script\b[^>]*\bsrc\s*=\s*(["'])(.*?)\1[^>]*>/gi
)]
  .map(match => match[2].split(/[?#]/, 1)[0])
  .filter(
    scriptPath =>
      !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(scriptPath) &&
      scriptPath !== runtimeInjection.PLAYMESH_MAIN_SDK_SCRIPT_PATH
  );
for (const scriptPath of localScriptReferences) {
  const packagePath = `app/${scriptPath.replace(/^\.\//, '').replace(/^\//, '')}`;
  assert.equal(
    fileMap.has(packagePath),
    true,
    `exported index.html references missing local script ${scriptPath}`
  );
}
const allRuntimeScriptTags = runtimeInjection.getPlaymeshMultiplayerRuntimeScriptTags();
allRuntimeScriptTags.forEach(tag => {
  assert.equal(soloHtml.split(tag).length - 1, 1);
});
assert.equal(
  [...fileMap.keys()].some(filePath =>
    /playmesh-multiplayer-bridge|static\/js\/service\/index\.js/.test(filePath)
  ),
  true,
  'Playmesh 单机发布也必须携带空操作兼容层'
);
const explicitSoloFileMap = controller.createPlaymeshPackageFileMap({
  resourcesDownloadOutput: {
    textFiles: [
      {
        filePath: '/export/index.html',
        text:
          '<!doctype html><html><head><script src="gdjs.js"></script></head>' +
          '<body><script>new gdjs.RuntimeGame();</script></body></html>',
      },
    ],
    blobFiles: [],
  },
  manifest: updatedManifest,
  fpsProbeSource,
  multiplayerBridgeSource,
  authorityBootstrapSource,
});
const explicitSoloManifest = JSON.parse(
  explicitSoloFileMap.get('main.json').text
);
assert.deepEqual(explicitSoloManifest.modes, ['solo']);
assert.equal(explicitSoloManifest.authority, undefined);
assert.equal(
  explicitSoloFileMap.has(
    'app/static/js/service/playmesh-multiplayer-bridge.js'
  ),
  true
);
assert.equal(explicitSoloFileMap.has('app/static/js/service/index.js'), true);
assert.equal(
  explicitSoloFileMap.has(
    'app/static/js/service/playmesh-gdevelop-fps-probe.js'
  ),
  true
);
runtimeInjection.getPlaymeshMultiplayerRuntimeScriptTags().forEach(tag => {
  assert.equal(
    explicitSoloFileMap.get('app/index.html').text.split(tag).length - 1,
    1
  );
});
for (const tag of runtimeInjection
  .getPlaymeshMultiplayerRuntimeScriptTags()
  .filter(tag => tag !== runtimeInjection.getPlaymeshSdkPlaceholderTag())) {
  const relativePath = tag.match(/src="([^"]+)"/)?.[1];
  assert.ok(relativePath, 'Playmesh 兼容层标签必须包含相对路径');
  assert.equal(
    explicitSoloFileMap.has(`app/${relativePath}`),
    true,
    `单机发布的 ${relativePath} 必须实际存在，避免 404`
  );
}
const producer = controller.createPlaymeshPackageEntryProducer(fileMap);
assert.equal(producer.fileCount, 11);
assert.equal([...producer.entries()].length, 11);
assert.throws(
  () =>
    controller.createPlaymeshPackageFileMap({
      resourcesDownloadOutput: {
        textFiles: [{ filePath: '/outside/index.html', text: '' }],
        blobFiles: [],
      },
      manifest: updatedManifest,
      fpsProbeSource,
      multiplayerBridgeSource,
      authorityBootstrapSource,
    }),
  /不在 \/export\//
);

const multiplayerManifest = controller.buildGDevelopGameManifest({
  project,
  sdkVersion: '4.1.0',
  appSdkVersion: '3.3.0',
  lastModifiedAt: 12,
  mode: 'multiplayer',
  displayMode: 'multi_screen',
  minPlayers: 2,
  maxPlayers: 5,
  authorityEntry: controller.GDEVELOP_AUTHORITY_ENTRY,
});
const multiplayerFileMap = controller.createPlaymeshPackageFileMap({
  resourcesDownloadOutput: {
    textFiles: [
      {
        filePath: '/export/index.html',
        text:
          '<!doctype html><html><head><script src="gdjs.js"></script></head>' +
          '<body><script>new gdjs.RuntimeGame();</script></body></html>',
      },
    ],
    blobFiles: [],
  },
  manifest: multiplayerManifest,
  fpsProbeSource,
  multiplayerBridgeSource,
  authorityBootstrapSource,
});
assert.equal(
  multiplayerFileMap.get('app/static/js/service/index.js').text,
  authorityBootstrapSource
);
assert.equal(
  multiplayerFileMap.get('app/static/js/service/playmesh-multiplayer-bridge.js')
    .text,
  multiplayerBridgeSource
);
const multiplayerHtml = multiplayerFileMap.get('app/index.html').text;
const runtimeScriptTags = runtimeInjection.getPlaymeshMultiplayerRuntimeScriptTags();
runtimeScriptTags.forEach(tag => {
  assert.equal(multiplayerHtml.split(tag).length - 1, 1);
});
for (const tag of runtimeScriptTags.filter(
  tag => tag !== runtimeInjection.getPlaymeshSdkPlaceholderTag()
)) {
  const relativePath = tag.match(/src="([^"]+)"/)?.[1];
  assert.ok(relativePath, 'Playmesh 兼容层标签必须包含相对路径');
  assert.equal(
    multiplayerFileMap.has(`app/${relativePath}`),
    true,
    `多人发布的 ${relativePath} 必须实际存在，避免 404`
  );
}
for (let index = 1; index < runtimeScriptTags.length; index++) {
  assert.ok(
    multiplayerHtml.indexOf(runtimeScriptTags[index - 1]) <
      multiplayerHtml.indexOf(runtimeScriptTags[index])
  );
}
assert.ok(
  multiplayerHtml.indexOf('gdjs.js') <
    multiplayerHtml.indexOf(runtimeScriptTags[0])
);
assert.ok(
  multiplayerHtml.indexOf(runtimeScriptTags.at(-1)) <
    multiplayerHtml.indexOf('</head>')
);
assert.ok(
  multiplayerHtml.indexOf(runtimeScriptTags.at(-1)) <
    multiplayerHtml.indexOf('new gdjs.RuntimeGame')
);
assert.equal(
  JSON.parse(multiplayerFileMap.get('main.json').text).authority.entry,
  'static/js/service/index.js'
);
const reinjectedHtml = runtimeInjection.injectMultiplayerCompatibility({
  html: runtimeInjection.ensureSdkPlaceholder({ html: multiplayerHtml }),
  activation: 'enabled',
});
assert.equal(reinjectedHtml, multiplayerHtml, '多人运行层重复注入必须幂等');
const repeatedFileMap = controller.createPlaymeshPackageFileMap({
  resourcesDownloadOutput: {
    textFiles: [
      {
        filePath: '/export/index.html',
        text:
          '<!doctype html><html><head><script src="gdjs.js"></script></head>' +
          '<body><script>new gdjs.RuntimeGame();</script></body></html>',
      },
    ],
    blobFiles: [],
  },
  manifest: multiplayerManifest,
  fpsProbeSource,
  multiplayerBridgeSource,
  authorityBootstrapSource,
});
assert.deepEqual(
  [...repeatedFileMap].map(([filePath, entry]) => [
    filePath,
    entry.kind,
    entry.text,
  ]),
  [...multiplayerFileMap].map(([filePath, entry]) => [
    filePath,
    entry.kind,
    entry.text,
  ])
);

// Installed packages are mutable user/runtime data, not a deterministic test
// fixture. Validate them only when a caller explicitly opts into a corpus.
const installedPackagesRoot = process.env.PLAYMESH_GAME_MANIFEST_CORPUS_ROOT
  ? path.resolve(process.env.PLAYMESH_GAME_MANIFEST_CORPUS_ROOT)
  : null;
let corpusCount = 0;
if (installedPackagesRoot) {
  try {
    for (const directory of await readdir(installedPackagesRoot, {
      withFileTypes: true,
    })) {
      if (!directory.isDirectory()) continue;
      try {
        const manifest = JSON.parse(
          await readFile(
            path.resolve(installedPackagesRoot, directory.name, 'main.json'),
            'utf8'
          )
        );
        assert.equal(manifestApi.validateGameManifest(manifest).valid, true);
        corpusCount += 1;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}

process.stdout.write(
  `Playmesh shared/GDevelop manifest tests passed; compatible installed corpus: ${corpusCount}.\n`
);
