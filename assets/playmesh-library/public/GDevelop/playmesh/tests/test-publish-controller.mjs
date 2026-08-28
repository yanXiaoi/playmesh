import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
let source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/ExportAndShare/PlaymeshPublishController.js'
  ),
  'utf8'
);

const fullPlan = {
  target: 'publish',
  bundlePresence: 'full',
  runtimeActivation: 'active',
  presentation: 'game',
  manifestMode: 'multiplayer',
  connectCore: true,
  blockBeforeExport: false,
  warning: null,
  reason: 'explicit_online',
};
const nonePlan = {
  target: 'publish',
  bundlePresence: 'full',
  runtimeActivation: 'inactive',
  presentation: 'game',
  manifestMode: 'solo',
  connectCore: false,
  blockBeforeExport: false,
  warning: null,
  reason: 'explicit_single_scan_disabled',
};
const blockedPlan = {
  ...nonePlan,
  blockBeforeExport: true,
  reason: 'explicit_single_scan_enabled',
};
const state = {
  plan: fullPlan,
  resolverInput: null,
  manifestInput: null,
  pipelineCalls: [],
  packageArgs: null,
  statusCalls: 0,
};
const mocks = {
  browserHTML5ExportPipeline: null,
  GDevelopAuthorityBootstrapSource:
    '(function(){globalThis.playmeshGDevelopAuthorityBootstrap={};})();',
  GDevelopFpsProbeSource:
    '(function(){Symbol.for("playmesh.gdevelop.fps-probe.v1");const performanceApi={reportFrame(){}};performanceApi.reportFrame();})();',
  GDevelopMultiplayerBridgeSource:
    '(function(){Symbol.for("playmesh.runtime.backends.v1");Symbol.for("playmesh.gdevelop.multiplayer.coordinator.v1");})();',
  GDEVELOP_AUTHORITY_ENTRY: 'static/js/service/index.js',
  resolvePlaymeshProjectRuntimePlan: async input => {
    state.resolverInput = input;
    return {
      configStatus:
        state.plan.runtimeActivation === 'active' ? 'online' : 'single',
      scanActivation:
        state.plan.reason === 'explicit_single_scan_enabled'
          ? 'enabled'
          : 'disabled',
      config: {
        minPlayers: 3,
        maxPlayers: 8,
        tags: ['party'],
        webRuntimeMultithreading: true,
      },
      plan: state.plan,
    };
  },
  getPlaymeshMessage: key => key,
  playmeshMessages: {
    projectConfigPublishBlocked: 'publish-blocked',
    projectConfigScanUnknownWarning: 'scan-unknown',
  },
  buildGDevelopGameManifest: input => {
    state.manifestInput = input;
    const manifest = {
      id: input.gameId,
      name: 'Published',
      version: '1.0.0',
      sdkVersion: input.sdkVersion,
      appSdkVersion: input.appSdkVersion,
      orientation: 'landscape',
      modes: [input.mode],
      displayModes: ['multi_screen'],
      players: { min: input.minPlayers, max: input.maxPlayers },
      entries: { game: 'index.html' },
      tags: [],
    };
    if (input.mode === 'multiplayer') {
      manifest.authority = { entry: input.authorityEntry };
    }
    return manifest;
  },
  createPlaymeshPackageFileMap: args => {
    state.packageArgs = args;
    return new Map([
      ['app/index.html', args.resourcesDownloadOutput.textFiles[0]],
      ['main.json', { text: JSON.stringify(args.manifest) }],
    ]);
  },
  createPlaymeshPackageEntryProducer: fileMap => ({
    fileCount: fileMap.size,
    entries: () => fileMap.values(),
  }),
};
globalThis.__playmeshPublishMocks = mocks;
source = source
  .replace(
    /import GDevelopFpsProbeSource from '[^']+';/,
    'const { GDevelopFpsProbeSource } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import GDevelopMultiplayerBridgeSource from '[^']+';/,
    'const { GDevelopMultiplayerBridgeSource } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import GDevelopAuthorityBootstrapSource from '[^']+';/,
    'const { GDevelopAuthorityBootstrapSource } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import \{ browserHTML5ExportPipeline \} from '[^']+';/,
    'const { browserHTML5ExportPipeline } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/PlaymeshManifest\/PlaymeshGDevelopManifestController';/,
    `const {
  buildGDevelopGameManifest,
  createPlaymeshPackageEntryProducer,
  createPlaymeshPackageFileMap,
  GDEVELOP_AUTHORITY_ENTRY,
} = globalThis.__playmeshPublishMocks;`
  )
  .replace(
    /import \{ resolvePlaymeshProjectRuntimePlan \} from '[^']+';/,
    'const { resolvePlaymeshProjectRuntimePlan } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import \{ getPlaymeshMessage \} from '[^']+';/,
    'const { getPlaymeshMessage } = globalThis.__playmeshPublishMocks;'
  )
  .replace(
    /import \{ playmeshMessages \} from '[^']+';/,
    'const { playmeshMessages } = globalThis.__playmeshPublishMocks;'
  );
const publish = await import(`data:text/javascript;base64,${Buffer.from(
  source
).toString('base64')}`);

const pipeline = {
  getInitialExportState: project => {
    state.pipelineCalls.push('initial');
    return { project };
  },
  prepareExporter: async () => {
    state.pipelineCalls.push('prepare');
    return {};
  },
  launchExport: async () => {
    state.pipelineCalls.push('export');
    return {};
  },
  launchResourcesDownload: async () => {
    state.pipelineCalls.push('resources');
    return {
      textFiles: [
        {
          filePath: '/export/index.html',
          text: '<html><head></head><body></body></html>',
        },
      ],
      blobFiles: [],
    };
  },
};
const gameId = 'com.playmesh.game.gpublish001';
const project = {};
const statusLoader = async () => {
  state.statusCalls++;
  return { gameSdkVersion: '4.1.0', appSdkVersion: '3.3.0' };
};
const reset = plan => {
  state.plan = plan;
  state.resolverInput = null;
  state.manifestInput = null;
  state.pipelineCalls = [];
  state.packageArgs = null;
  state.statusCalls = 0;
};

reset(fullPlan);
const online = await publish.createPlaymeshGDevelopPublishFileMap({
  project,
  gameId,
  i18n: {},
  pipeline,
  statusLoader,
  runtimePlanLoader: mocks.resolvePlaymeshProjectRuntimePlan,
});
assert.equal(state.resolverInput.gameId, gameId);
assert.equal(state.resolverInput.project, project);
assert.equal(state.resolverInput.target, 'publish');
assert.deepEqual(state.pipelineCalls, [
  'initial',
  'prepare',
  'export',
  'resources',
]);
assert.equal(state.manifestInput.gameId, gameId);
assert.equal(state.manifestInput.mode, 'multiplayer');
assert.equal(state.manifestInput.authorityEntry, 'static/js/service/index.js');
assert.equal(state.manifestInput.webRuntimeMultithreading, true);
assert.equal('runtimeInjection' in state.packageArgs, false);
assert.match(
  state.packageArgs.fpsProbeSource,
  /playmesh\.gdevelop\.fps-probe\.v1/
);
assert.equal(state.packageArgs.injectPlaymeshRuntime, undefined);
assert.match(
  state.packageArgs.authorityBootstrapSource,
  /playmeshGDevelopAuthorityBootstrap/
);
assert.match(
  state.packageArgs.fpsProbeSource,
  /playmesh\.gdevelop\.fps-probe\.v1/
);
assert.equal(state.packageArgs.injectPlaymeshRuntime, undefined);
assert.match(
  state.packageArgs.multiplayerBridgeSource,
  /playmesh\.runtime\.backends\.v1/
);
assert.equal(online.gameId, gameId);
assert.equal(online.runtimePlan.plan.connectCore, true);

reset(nonePlan);
const solo = await publish.createPlaymeshGDevelopPublishFileMap({
  project,
  gameId,
  i18n: {},
  pipeline,
  statusLoader,
  runtimePlanLoader: mocks.resolvePlaymeshProjectRuntimePlan,
});
assert.equal(state.manifestInput.mode, 'solo');
assert.equal(state.manifestInput.authorityEntry, undefined);
assert.equal('runtimeInjection' in state.packageArgs, false);
assert.match(
  state.packageArgs.authorityBootstrapSource,
  /playmeshGDevelopAuthorityBootstrap/
);
assert.match(
  state.packageArgs.multiplayerBridgeSource,
  /playmesh\.runtime\.backends\.v1/
);
assert.equal(solo.runtimePlan.plan.bundlePresence, 'full');
assert.equal(solo.runtimePlan.plan.runtimeActivation, 'inactive');
assert.equal(solo.runtimePlan.plan.connectCore, false);

reset(blockedPlan);
await assert.rejects(
  publish.createPlaymeshGDevelopPublishFileMap({
    project,
    gameId,
    i18n: {},
    pipeline,
    statusLoader,
    runtimePlanLoader: mocks.resolvePlaymeshProjectRuntimePlan,
  }),
  error =>
    error instanceof publish.PlaymeshPublishError &&
    error.code === 'project_config_blocks_multiplayer_publish'
);
assert.deepEqual(
  state.pipelineCalls,
  [],
  'blocked publish must stop before export'
);
assert.equal(
  state.statusCalls,
  0,
  'blocked publish must stop before SDK lookup'
);
assert.equal(state.manifestInput, null);
assert.equal(state.packageArgs, null);

assert.doesNotMatch(source, /explicitMultiplayer|multiplayerActivation/);
assert.doesNotMatch(source, /\/dev\/api\/packages\/import/);
assert.doesNotMatch(source, /releaseId/);
assert.doesNotMatch(source, /launchCompression\(/);
process.stdout.write('GDevelop publish file-map controller tests passed.\n');
