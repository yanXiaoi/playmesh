import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const runnerPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiOfficialLocalEditorRunners.js'
);
const toolsPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiJfxrYarnTools.js'
);
const resourceWriterPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiExternalEditorResourceWriter.js'
);
const toolsContractPath = path.resolve(testDirectory, '../runtime/ai/tools.json');
const externalEditorsManifestPath = path.resolve(
  testDirectory,
  '../../official/external-editors.json'
);
const externalEditorsDirectory = path.resolve(
  testDirectory,
  '../../official/external-editors'
);
const runnerSource = await readFile(runnerPath, 'utf8');

assert.match(runnerSource, /external\/jfxr\/jfxr-editor\/index\.html/);
assert.match(runnerSource, /external\/yarn\/yarn-editor\/index\.html/);
assert.match(runnerSource, /getSound\(\)\.parse\(serializedSound\)/);
assert.match(
  runnerSource,
  /if \(!jfxr\.getSound\(\)\) \{\s*jfxr\.applyPreset\(jfxr\.presets\[0\]\);\s*\}/
);
assert.match(runnerSource, /loaded\.editor\.synth\.run\(\)/);
assert.match(
  runnerSource,
  /yarnData\.loadData\(JSON\.stringify\(yarnJson\), 'json', true\)/
);
assert.match(runnerSource, /loaded\.editor\.getSaveData\('json'\)/);
assert.match(
  runnerSource,
  /event\.mainCtrl\.getSound instanceof editorFrame\.contentWindow\.Function/
);
assert.match(
  runnerSource,
  /event\.document === editorFrame\.contentDocument/
);
assert.doesNotMatch(runnerSource, /https?:\/\//);

const toolsContract = JSON.parse(await readFile(toolsContractPath, 'utf8'));
const jfxrTool = toolsContract.tools.find(
  tool => tool.name === 'create_or_update_jfxr_sound'
);
const yarnTool = toolsContract.tools.find(
  tool => tool.name === 'create_or_update_yarn_dialogue'
);
assert.deepEqual(
  {
    implementation: jfxrTool?.implementation,
    officialImplementationName: jfxrTool?.officialImplementationName,
    modifiesProject: jfxrTool?.modifiesProject,
    approvalRequired: jfxrTool?.approvalRequired,
    executionKind: jfxrTool?.executionKind,
  },
  {
    implementation: 'playmesh_wrapper',
    officialImplementationName: 'jfxr-app/Sound.parse+synth.run',
    modifiesProject: true,
    approvalRequired: true,
    executionKind: 'editor_function',
  }
);
assert.deepEqual(
  {
    implementation: yarnTool?.implementation,
    officialImplementationName: yarnTool?.officialImplementationName,
    modifiesProject: yarnTool?.modifiesProject,
    approvalRequired: yarnTool?.approvalRequired,
    executionKind: yarnTool?.executionKind,
  },
  {
    implementation: 'playmesh_wrapper',
    officialImplementationName: 'yarn-app/loadData+getSaveData',
    modifiesProject: true,
    approvalRequired: true,
    executionKind: 'editor_function',
  }
);
assert.equal(
  jfxrTool.argumentsSchema.properties.serialized_sound.type,
  'string'
);
assert.equal(yarnTool.argumentsSchema.properties.yarn_json.type, 'array');
const yarnNodeSchema = yarnTool.argumentsSchema.properties.yarn_json.items;
assert.equal(yarnNodeSchema.additionalProperties, false);
assert.deepEqual(yarnNodeSchema.required, [
  'title',
  'body',
  'tags',
  'position',
  'colorID',
]);
assert.equal(yarnNodeSchema.properties.position.additionalProperties, false);
assert.deepEqual(yarnNodeSchema.properties.position.required, ['x', 'y']);
assert.equal('binaryStaging' in jfxrTool, false);
assert.equal('binaryStaging' in yarnTool, false);

const externalEditorsManifest = JSON.parse(
  await readFile(externalEditorsManifestPath, 'utf8')
);
assert.equal(
  externalEditorsManifest.editors.find(editor => editor.name === 'jfxr')
    ?.version,
  '5.0.0-beta55'
);
assert.equal(
  externalEditorsManifest.editors.find(editor => editor.name === 'yarn')
    ?.version,
  '5.0.134'
);
const officialJfxrSourceMap = await readFile(
  path.join(
    externalEditorsDirectory,
    'jfxr/jfxr-editor/419d227b2992f0e1b41a.js.map'
  ),
  'utf8'
);
assert.match(officialJfxrSourceMap, /Sound\.prototype\.parse/);
assert.match(officialJfxrSourceMap, /Sound\.prototype\.serialize/);
assert.match(officialJfxrSourceMap, /synth\.run/);
const officialYarnBundle = await readFile(
  path.join(
    externalEditorsDirectory,
    'yarn/yarn-editor/js/main.80b352588636fbc67c02.js'
  ),
  'utf8'
);
assert.match(officialYarnBundle, /loadData/);
assert.match(officialYarnBundle, /getSaveData/);

const listeners = new Map();
const windowObject = {
  addEventListener(name, listener) {
    listeners.set(name, listener);
  },
  removeEventListener(name, listener) {
    if (listeners.get(name) === listener) listeners.delete(name);
  },
};

let lastFrame = null;
const calls = [];
const jfxrSound = {
  parse(value) {
    calls.push(['jfxr.parse', value]);
  },
  serialize() {
    calls.push(['jfxr.serialize']);
    return '{"_version":1,"frequency":880}';
  },
};
let currentJfxrSound = null;
const jfxr = {
  autoplay: true,
  presets: [{ name: 'pickupCoin' }],
  getSound: () => {
    calls.push(['jfxr.getSound']);
    return currentJfxrSound;
  },
  applyPreset: preset => {
    calls.push(['jfxr.applyPreset', preset]);
    currentJfxrSound = jfxrSound;
  },
  synth: {
    async run() {
      calls.push(['jfxr.synth.run']);
      return {
        toWavBytes() {
          calls.push(['jfxr.clip.toWavBytes']);
          return new Uint8Array([82, 73, 70, 70]);
        },
      };
    },
  },
};
const yarnData = {
  restoreFromLocalStorage(value) {
    calls.push(['yarn.restoreFromLocalStorage', value]);
  },
  editingPath(value) {
    calls.push(['yarn.editingPath', value]);
  },
  editingType(value) {
    calls.push(['yarn.editingType', value]);
  },
  loadData(value, type, replace) {
    calls.push(['yarn.loadData', value, type, replace]);
  },
  getSaveData(type) {
    calls.push(['yarn.getSaveData', type]);
    return '{"nodes":[{"title":"Start"}]}';
  },
};

const body = {
  appendChild(frame) {
    lastFrame = frame;
    frame.parentNode = body;
    queueMicrotask(() => {
      if (frame.src.includes('/jfxr/')) {
        listeners.get('jfxrReady')?.({
          mainCtrl: { getSound: null },
        });
        listeners.get('jfxrReady')?.({ mainCtrl: jfxr });
      } else {
        listeners.get('yarnReady')?.({
          data: { getSaveData: () => 'unrelated' },
          document: {},
        });
        listeners.get('yarnReady')?.({
          data: yarnData,
          document: frame.contentDocument,
        });
      }
    });
  },
  removeChild(frame) {
    assert.equal(frame, lastFrame);
    frame.parentNode = null;
  },
};
const documentObject = {
  body,
  createElement(name) {
    assert.equal(name, 'iframe');
    return {
      hidden: false,
      tabIndex: 0,
      parentNode: null,
      contentWindow: { Function },
      contentDocument: {},
      setAttribute(name, value) {
        calls.push(['frame.attribute', name, value]);
      },
      src: '',
    };
  },
};

globalThis.window = windowObject;
globalThis.document = documentObject;
const runner = await import(
  `data:text/javascript;base64,${Buffer.from(runnerSource).toString('base64')}`
);

const jfxrOutput = await runner.runOfficialJfxrSound(
  '{"_version":1,"frequency":880}'
);
assert.equal(jfxr.autoplay, false);
assert.deepEqual(jfxrOutput, {
  serializedSound: '{"_version":1,"frequency":880}',
  wavBytes: new Uint8Array([82, 73, 70, 70]),
});
assert.deepEqual(
  calls.filter(call => call[0].startsWith('jfxr.')),
  [
    ['jfxr.getSound'],
    ['jfxr.applyPreset', jfxr.presets[0]],
    ['jfxr.getSound'],
    ['jfxr.parse', '{"_version":1,"frequency":880}'],
    ['jfxr.synth.run'],
    ['jfxr.getSound'],
    ['jfxr.serialize'],
    ['jfxr.clip.toWavBytes'],
  ]
);
assert.equal(lastFrame.parentNode, null);

const yarnInput = [
  {
    title: 'Start',
    tags: '',
    body: 'Hello',
    position: { x: 0, y: 0 },
    colorID: 0,
  },
];
const yarnOutput = await runner.runOfficialYarnDialogue(yarnInput);
assert.equal(yarnOutput, '{"nodes":[{"title":"Start"}]}');
assert.deepEqual(
  calls.filter(call => call[0].startsWith('yarn.')),
  [
    ['yarn.restoreFromLocalStorage', false],
    ['yarn.editingPath', ''],
    ['yarn.editingType', 'json'],
    ['yarn.loadData', JSON.stringify(yarnInput), 'json', true],
    ['yarn.getSaveData', 'json'],
  ]
);
assert.equal(lastFrame.parentNode, null);
assert.equal(listeners.size, 0);

const resourceWrites = [];
const generatedBlobs = [];
globalThis.__playmeshJfxrYarnToolDeps = {
  convertBlobToDataURL: async blob => {
    generatedBlobs.push(blob);
    return `data:${blob.type};base64,dGVzdA==`;
  },
  writePlaymeshAiExternalEditorOutput: async options => {
    resourceWrites.push(options);
    return {
      resources: [{ name: options.externalEditorOutput.baseNameForNewResources }],
      newName: options.externalEditorOutput.baseNameForNewResources,
      newMetadata: {
        [options.metadataKey]: options.externalEditorOutput.externalEditorData,
      },
    };
  },
  runOfficialJfxrSound: async serializedSound => ({
    serializedSound,
    wavBytes: new Uint8Array([82, 73, 70, 70]),
  }),
  runOfficialYarnDialogue: async yarnJson => JSON.stringify(yarnJson),
};
let toolsSource = await readFile(toolsPath, 'utf8');
assert.doesNotMatch(toolsSource, /Sound\.prototype|Synth\.prototype/);
assert.doesNotMatch(toolsSource, /getSaveData\s*[:=]\s*function/);
toolsSource = toolsSource.replace(
  /^import[\s\S]*?^\*\/\r?\n/m,
  `const {
    convertBlobToDataURL,
    writePlaymeshAiExternalEditorOutput,
    runOfficialJfxrSound,
    runOfficialYarnDialogue,
  } = globalThis.__playmeshJfxrYarnToolDeps;\n`
);
const toolsModule = await import(
  `data:text/javascript;base64,${Buffer.from(toolsSource).toString('base64')}`
);

const resources = new Map([
  ['laser', { getKind: () => 'audio' }],
  ['dialogue', { getKind: () => 'image' }],
]);
const project = {
  getResourcesManager: () => ({
    hasResource: name => resources.has(name),
    getResource: name => resources.get(name),
  }),
};
const onNewResourcesAdded = () => {};
const onFetchNewlyAddedResources = async () => {};
const projectMutationBoundaries = [];
const beforeProjectMutation = () => projectMutationBoundaries.push('commit');
const tools = toolsModule.createPlaymeshAiJfxrYarnTools({
  beforeProjectMutation,
  onFetchNewlyAddedResources,
  onNewResourcesAdded,
});
const soundResult = await tools.create_or_update_jfxr_sound({
  call: {
    callId: 'sound-call',
    arguments: {
      resource_name: 'laser',
      serialized_sound: '{"_version":1,"frequency":880}',
    },
  },
  project,
});
assert.equal(soundResult.result.didModifyProject, true);
assert.deepEqual(soundResult.result.output, {
  resource_name: 'laser',
  resource_kind: 'audio',
  serialized_sound: '{"_version":1,"frequency":880}',
});
assert.equal(generatedBlobs[0].type, 'audio/wav');
assert.equal(resourceWrites[0].resourceKind, 'audio');
assert.equal(resourceWrites[0].metadataKey, 'jfxr');
assert.equal(
  resourceWrites[0].onFetchNewlyAddedResources,
  onFetchNewlyAddedResources
);
assert.equal(resourceWrites[0].onNewResourcesAdded, onNewResourcesAdded);
assert.deepEqual(resourceWrites[0].externalEditorOutput, {
  resources: [
    {
      name: 'laser',
      extension: '.wav',
      dataUrl: 'data:audio/wav;base64,dGVzdA==',
    },
  ],
  baseNameForNewResources: 'laser',
  externalEditorData: {
    data: '{"_version":1,"frequency":880}',
    name: 'laser',
  },
});

const yarnInputForTool = [
  {
    title: 'Start',
    tags: '',
    body: 'Hello',
    position: { x: 0, y: 0 },
    colorID: 0,
  },
];
const yarnResult = await tools.create_or_update_yarn_dialogue({
  call: {
    callId: 'yarn-call',
    arguments: {
      resource_name: 'dialogue',
      yarn_json: yarnInputForTool,
    },
  },
  project,
});
assert.equal(yarnResult.result.didModifyProject, true);
assert.deepEqual(yarnResult.result.output, {
  resource_name: 'dialogue',
  resource_kind: 'json',
  yarn_json: yarnInputForTool,
});
assert.equal(generatedBlobs[1].type, 'application/json');
assert.equal(await generatedBlobs[1].text(), JSON.stringify(yarnInputForTool));
assert.equal(resourceWrites[1].resourceKind, 'json');
assert.equal(resourceWrites[1].metadataKey, 'yarn');
assert.equal(resourceWrites[1].resourceMetadata, null);
assert.equal(
  resourceWrites[1].onFetchNewlyAddedResources,
  onFetchNewlyAddedResources
);
assert.equal(resourceWrites[1].onNewResourcesAdded, onNewResourcesAdded);
assert.deepEqual(projectMutationBoundaries, ['commit', 'commit']);
assert.deepEqual(resourceWrites[1].externalEditorOutput, {
  resources: [
    {
      extension: '.json',
      dataUrl: 'data:application/json;base64,dGVzdA==',
    },
  ],
  baseNameForNewResources: 'dialogue',
  externalEditorData: null,
});

const mutationBoundaryFailure = new Error('mutation-boundary-rejected');
let boundaryProjectReads = 0;
let boundaryEncodes = 0;
let boundaryWrites = 0;
const rejectedBoundaryTools = toolsModule.createPlaymeshAiJfxrYarnTools({
  beforeProjectMutation: () => {
    throw mutationBoundaryFailure;
  },
  convertBlobToDataUrl: async () => {
    boundaryEncodes++;
    return 'data:application/octet-stream;base64,dGVzdA==';
  },
  writeExternalEditorOutput: async () => {
    boundaryWrites++;
    throw new Error('a rejected boundary must not write a project resource');
  },
  runJfxrSound: async serializedSound => ({
    serializedSound,
    wavBytes: new Uint8Array([82, 73, 70, 70]),
  }),
  runYarnDialogue: async yarnJson => JSON.stringify(yarnJson),
});
const rejectedBoundaryProject = {
  getResourcesManager: () => {
    boundaryProjectReads++;
    throw new Error('a rejected boundary must not read the stale project');
  },
};
await assert.rejects(
  rejectedBoundaryTools.create_or_update_jfxr_sound({
    call: {
      callId: 'rejected-boundary-sound',
      arguments: {
        resource_name: 'laser',
        serialized_sound: '{"_version":1}',
      },
    },
    project: rejectedBoundaryProject,
  }),
  error => error === mutationBoundaryFailure
);
await assert.rejects(
  rejectedBoundaryTools.create_or_update_yarn_dialogue({
    call: {
      callId: 'rejected-boundary-yarn',
      arguments: {
        resource_name: 'dialogue',
        yarn_json: yarnInputForTool,
      },
    },
    project: rejectedBoundaryProject,
  }),
  error => error === mutationBoundaryFailure
);
assert.equal(boundaryEncodes, 2);
assert.equal(boundaryProjectReads, 0);
assert.equal(boundaryWrites, 0);

const writerLifecycle = [];
globalThis.__playmeshJfxrYarnWriterDeps = {
  freeBlobsAndUpdateMetadata: () => writerLifecycle.push('free'),
  patchExternalEditorMetadataWithResourcesNamesIfNecessary: () =>
    writerLifecycle.push('patch'),
  saveBlobUrlsFromExternalEditorBase64Resources: async options => {
    writerLifecycle.push('save');
    const outputResource = options.resources[0];
    const resourceName = outputResource.name || options.baseNameForNewResources;
    return [
      {
        resource: {
          getName: () => resourceName,
          getFile: () => `resources/${resourceName}`,
        },
        originalIndex: 0,
      },
    ];
  },
  triggerOnResourceExternallyChanged: () => writerLifecycle.push('changed'),
};
let resourceWriterSource = await readFile(resourceWriterPath, 'utf8');
assert.doesNotMatch(resourceWriterSource, /fetchPlaymeshLocalResources/);
resourceWriterSource = resourceWriterSource.replace(
  /import \{[\s\S]*?\} from '\.\.\/ResourcesList\/ResourceExternalEditor';\nimport \{ triggerOnResourceExternallyChanged \} from '\.\.\/MainFrame\/ResourcesWatcher';/,
  `const {
    freeBlobsAndUpdateMetadata,
    patchExternalEditorMetadataWithResourcesNamesIfNecessary,
    saveBlobUrlsFromExternalEditorBase64Resources,
    triggerOnResourceExternallyChanged,
  } = globalThis.__playmeshJfxrYarnWriterDeps;`
);
const resourceWriterModule = await import(
  `data:text/javascript;base64,${Buffer.from(resourceWriterSource).toString(
    'base64'
  )}`
);
const writerResourcesManager = {
  hasResource: () => true,
  getResource: name => ({
    getName: () => name,
    getFile: () => `resources/${name}`,
  }),
};
const writerProject = {
  getResourcesManager: () => writerResourcesManager,
};
const recordNewResource = () => writerLifecycle.push('new');
await resourceWriterModule.writePlaymeshAiExternalEditorOutput({
  ...resourceWrites[0],
  project: writerProject,
  onFetchNewlyAddedResources: async () => writerLifecycle.push('fetch'),
  onNewResourcesAdded: recordNewResource,
});
assert.deepEqual(writerLifecycle, [
  'save',
  'fetch',
  'free',
  'patch',
  'changed',
]);
writerLifecycle.length = 0;
await resourceWriterModule.writePlaymeshAiExternalEditorOutput({
  ...resourceWrites[1],
  project: writerProject,
  onFetchNewlyAddedResources: async () => writerLifecycle.push('fetch'),
  onNewResourcesAdded: recordNewResource,
});
assert.deepEqual(writerLifecycle, [
  'save',
  'fetch',
  'free',
  'new',
  'patch',
  'changed',
]);

writerLifecycle.length = 0;
const fetchFailure = new Error('official-fetch-failure');
const loggedFetchFailures = [];
const originalConsoleError = console.error;
console.error = (...args) => loggedFetchFailures.push(args);
try {
  await resourceWriterModule.writePlaymeshAiExternalEditorOutput({
    ...resourceWrites[1],
    project: writerProject,
    onFetchNewlyAddedResources: async () => {
      writerLifecycle.push('fetch-failed');
      throw fetchFailure;
    },
    onNewResourcesAdded: recordNewResource,
  });
} finally {
  console.error = originalConsoleError;
}
assert.deepEqual(writerLifecycle, [
  'save',
  'fetch-failed',
  'free',
  'new',
  'patch',
  'changed',
]);
assert.equal(loggedFetchFailures.length, 1);
assert.equal(loggedFetchFailures[0][1], fetchFailure);

const runnerFailure = new Error('official-runner-sentinel');
const noFallbackTools = toolsModule.createPlaymeshAiJfxrYarnTools({
  runJfxrSound: async () => {
    throw runnerFailure;
  },
  runYarnDialogue: async () => {
    throw runnerFailure;
  },
});
await assert.rejects(
  noFallbackTools.create_or_update_jfxr_sound({
    call: {
      callId: 'failed-sound-call',
      arguments: {
        resource_name: 'laser',
        serialized_sound: '{"_version":1}',
      },
    },
    project,
  }),
  error => error === runnerFailure
);
await assert.rejects(
  noFallbackTools.create_or_update_yarn_dialogue({
    call: {
      callId: 'failed-yarn-call',
      arguments: {
        resource_name: 'dialogue',
        yarn_json: yarnInputForTool,
      },
    },
    project,
  }),
  error => error === runnerFailure
);
assert.equal(
  resourceWrites.length,
  2,
  'a failed official runner must never fall back to a local serializer or write a resource'
);

process.stdout.write(
  'Bundled Jfxr/Yarn AI runners and resource bridges reuse the pinned official editor APIs.\n'
);
