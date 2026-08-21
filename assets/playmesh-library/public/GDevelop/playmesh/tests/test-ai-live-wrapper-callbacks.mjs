import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src'
);
const dataModule = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const sourceOf = relativePath =>
  readFile(path.join(overlayDirectory, relativePath), 'utf8');

let registrySource = await sourceOf(
  'ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshResourceObjectUrlRegistry.js'
);
registrySource = registrySource
  .replace(/type StoredResource = \{[\s\S]*?\n\};\n\n/, '')
  .replace(/type RegistryOptions = \{\|[\s\S]*?\|\};\n\n/, '')
  .replace(
    /export type PlaymeshResourceObjectUrlRegistry = \{\|[\s\S]*?\|\};\n\n/,
    ''
  )
  .replace(
    /const contentKey = \(resource: StoredResource\): \?string =>/,
    'const contentKey = resource =>'
  )
  .replace(
    /export const createPlaymeshResourceObjectUrlRegistry = \(\{\n  createObjectURL,\n  revokeObjectURL,\n\}: RegistryOptions\): PlaymeshResourceObjectUrlRegistry =>/,
    'export const createPlaymeshResourceObjectUrlRegistry = ({ createObjectURL, revokeObjectURL }) =>'
  )
  .replace(
    /const acquire = \(resource: StoredResource\): string =>/,
    'const acquire = resource =>'
  )
  .replace(
    /const owns = \(objectUrl: string\): boolean =>/,
    'const owns = objectUrl =>'
  )
  .replace(/const dispose = \(\): void =>/, 'const dispose = () =>')
  .replace(/new Map<string, string>\(\)/g, 'new Map()')
  .replace(/new Set<string>\(\)/g, 'new Set()');
const registryModule = await dataModule(registrySource);
const revokedObjectUrls = [];
const resourceRegistry = registryModule.createPlaymeshResourceObjectUrlRegistry({
  createObjectURL: blob => URL.createObjectURL(blob),
  revokeObjectURL: objectUrl => {
    revokedObjectUrls.push(objectUrl);
    URL.revokeObjectURL(objectUrl);
  },
});

class LocalToolError extends Error {
  constructor(code, correctable = false) {
    super(code);
    this.code = code;
    this.correctable = correctable;
  }
}

const scene = { name: 'Game', getEvents: () => ({}) };
let applyResult = { applied: 1, errors: ['one operation was skipped'] };
globalThis.__playmeshEventExecutorDeps = {
  addMissingObjectBehaviors: () => {},
  addObjectUndeclaredVariables: () => {},
  addUndeclaredVariables: () => {},
  applyEventsChanges: () => applyResult,
  PlaymeshAiLocalToolError: LocalToolError,
  getPlaymeshAiEventPayloadValidationError: () => null,
};
let eventExecutorSource = await sourceOf(
  'PlaymeshAi/PlaymeshAiEventPayloadExecutor.js'
);
eventExecutorSource = eventExecutorSource
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/EditorFunctions\/ApplyEventsChanges';/,
    `const {
      addMissingObjectBehaviors,
      addObjectUndeclaredVariables,
      addUndeclaredVariables,
      applyEventsChanges,
    } = globalThis.__playmeshEventExecutorDeps;`
  )
  .replace(
    "import { PlaymeshAiLocalToolError } from './PlaymeshAiLocalToolWrappers';",
    'const { PlaymeshAiLocalToolError } = globalThis.__playmeshEventExecutorDeps;'
  )
  .replace(
    "import { getPlaymeshAiEventPayloadValidationError } from './PlaymeshAiProtocol';",
    'const { getPlaymeshAiEventPayloadValidationError } = globalThis.__playmeshEventExecutorDeps;'
  );
const eventExecutorModule = await dataModule(eventExecutorSource);
const eventNotifications = [];
const eventContext = {
  call: {
    callId: 'event-call-1',
    arguments: { scene_name: 'Game' },
  },
  project: {
    hasLayoutNamed: name => name === 'Game',
    getLayout: () => scene,
  },
  eventPayload: {
    schemaVersion: '1.0.0',
    sceneName: 'Game',
    changes: [],
  },
  runnerOptions: {
    onSceneEventsModifiedOutsideEditor: changes =>
      eventNotifications.push(changes),
  },
};
const partialEventResult = await eventExecutorModule.applyPlaymeshAiEventPayload(
  eventContext
);
assert.equal(partialEventResult.result.output, applyResult);
assert.equal(eventNotifications.length, 1);
assert.equal(eventNotifications[0].scene, scene);
assert.deepEqual(
  [...eventNotifications[0].newOrChangedAiGeneratedEventIds],
  ['event-call-1']
);
applyResult = { applied: 0, errors: ['nothing applied'] };
await eventExecutorModule.applyPlaymeshAiEventPayload(eventContext);
assert.equal(
  eventNotifications.length,
  1,
  'an event callback must only be emitted when the official applier mutated events'
);

let swapAccepted = true;
let importedResourceFile = null;
let installedExtensionNames = new Set();
const externalEditorToolOptions = [];
const localPlaymeshHeader = {
  name: 'Playmesh',
  fullName: 'Playmesh SDK',
  shortDescription: 'Use the bundled Playmesh SDK.',
  category: 'Network',
  tags: ['playmesh', 'sdk'],
  url: '/playmesh/GDevelop/playmesh/extensions/Playmesh.json',
  tier: 'reviewed',
};
const localPlaymeshExtension = {
  name: 'Playmesh',
  fullName: 'Playmesh SDK',
  version: '2.0.0',
  gdevelopVersion: '>=5.6.276',
  eventsFunctions: [
    {
      name: 'IsAvailable',
      fullName: 'Playmesh is available',
      description: 'Check whether the SDK is available.',
      functionType: 'Condition',
    },
  ],
  eventsBasedBehaviors: [],
};
const wrapperDependencies = {
  swapAsset: () => swapAccepted,
  PixiResourcesLoader: {},
  addSerializedExtensionsToProject: async (
    _eventsFunctionsExtensionsState,
    _project,
    serializedExtensions
  ) => {
    extensionLifecycle.push(['apply', serializedExtensions.map(item => item.name)]);
    installedExtensionNames = new Set(
      serializedExtensions.map(extension => extension.name)
    );
  },
  createNewResource: () => ({
    setName: () => {},
    setFile: value => {
      importedResourceFile = value;
    },
    setOrigin: () => {},
    delete: () => {},
  }),
  applyResourceDefaults: () => {},
  playmeshResourceObjectUrlRegistry: resourceRegistry,
  serializeToJSObject: () => ({}),
  enumerateAllInstructions: () => [],
  enumerateAllExpressions: () => [],
  enumerateEventsMetadata: () => [],
  formatExpressionCall: () => '',
  getPlaymeshExtensionsRegistry: async () => ({
    headers: [localPlaymeshHeader],
  }),
  getPlaymeshBehaviorsRegistry: async () => ({ headers: [] }),
  getPlaymeshExtension: async header => {
    assert.equal(header, localPlaymeshHeader);
    return structuredClone(localPlaymeshExtension);
  },
  playmeshAiRuntimeDebuggerTools: { wrappers: {} },
  createPlaymeshAiPiskelToolWrappers: options => {
    externalEditorToolOptions.push(['piskel', options]);
    return {};
  },
  createPlaymeshAiJfxrYarnTools: options => {
    externalEditorToolOptions.push(['jfxr-yarn', options]);
    return {};
  },
  gd: {},
};
globalThis.__playmeshWrapperDeps = wrapperDependencies;
let wrappersSource = await sourceOf('PlaymeshAi/PlaymeshAiLocalToolWrappers.js');
wrappersSource = wrappersSource.replace(
  /import \{ swapAsset \}[\s\S]*?const gd \/\*: libGDevelop \*\/ = global\.gd;/,
  `const {
    swapAsset,
    PixiResourcesLoader,
    addSerializedExtensionsToProject,
    createNewResource,
    applyResourceDefaults,
    playmeshResourceObjectUrlRegistry,
    serializeToJSObject,
    enumerateAllInstructions,
    enumerateAllExpressions,
    enumerateEventsMetadata,
    formatExpressionCall,
    getPlaymeshExtensionsRegistry,
    getPlaymeshBehaviorsRegistry,
    getPlaymeshExtension,
    playmeshAiRuntimeDebuggerTools,
    createPlaymeshAiPiskelToolWrappers,
    createPlaymeshAiJfxrYarnTools,
    gd,
  } = globalThis.__playmeshWrapperDeps;`
);
const wrappersModule = await dataModule(wrappersSource);

externalEditorToolOptions.length = 0;
const beforeProjectMutation = () => {};
const onFetchNewlyAddedResources = async () => {};
const onNewResourcesAdded = () => {};
wrappersModule.createPlaymeshAiLocalToolWrappers({
  beforeProjectMutation,
  onFetchNewlyAddedResources,
  onNewResourcesAdded,
});
assert.deepEqual(
  externalEditorToolOptions.map(([name, options]) => ({
    name,
    beforeProjectMutation: options.beforeProjectMutation,
    onFetchNewlyAddedResources: options.onFetchNewlyAddedResources,
    onNewResourcesAdded: options.onNewResourcesAdded,
  })),
  [
    {
      name: 'piskel',
      beforeProjectMutation,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    },
    {
      name: 'jfxr-yarn',
      beforeProjectMutation,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    },
  ]
);

const targetObject = { getType: () => 'Sprite' };
const sourceObject = { getType: () => 'Sprite' };
const sceneObjects = {
  hasObjectNamed: name => name === 'Target' || name === 'Source',
  getObject: name => (name === 'Target' ? targetObject : sourceObject),
};
const objectScene = { getObjects: () => sceneObjects };
const emptyGlobalObjects = { hasObjectNamed: () => false };
const objectProject = {
  hasLayoutNamed: name => name === 'Game',
  getLayout: () => objectScene,
  getObjects: () => emptyGlobalObjects,
};
const objectNotifications = [];
const objectWrappers = wrappersModule.createPlaymeshAiLocalToolWrappers();
const replacement = await objectWrappers.create_or_replace_object({
  call: {
    callId: 'object-call-1',
    toolName: 'create_or_replace_object',
    arguments: {
      scene_name: 'Game',
      object_name: 'Target',
      duplicated_object_name: 'Source',
      replace_existing_object: true,
    },
  },
  project: objectProject,
  runnerOptions: {
    onObjectsModifiedOutsideEditor: changes => objectNotifications.push(changes),
  },
  runOfficial: async () => {
    throw new Error('the local replacement branch must not run the official tool');
  },
});
assert.equal(replacement.result.success, true);
assert.equal(objectNotifications.length, 1);
assert.deepEqual(objectNotifications[0], {
  scene: objectScene,
  isNewObjectTypeUsed: false,
});
swapAccepted = false;
await objectWrappers.create_or_replace_object({
  call: {
    callId: 'object-call-2',
    toolName: 'create_or_replace_object',
    arguments: {
      scene_name: 'Game',
      object_name: 'Target',
      duplicated_object_name: 'Source',
      replace_existing_object: true,
    },
  },
  project: objectProject,
  runnerOptions: {
    onObjectsModifiedOutsideEditor: changes => objectNotifications.push(changes),
  },
  runOfficial: async () => {},
});
assert.equal(objectNotifications.length, 1);

const stagedBlob = new Blob(['resource remains readable'], {
  type: 'text/plain',
});
const contentHash = 'c'.repeat(64);
const resourceWrappers = wrappersModule.createPlaymeshAiLocalToolWrappers({
  stagedResource: {
    resourceName: 'probe.txt',
    resourceKind: 'text',
    contentHash,
    mime: 'text/plain',
    size: stagedBlob.size,
    blob: stagedBlob,
  },
});
const resourceImport = await resourceWrappers.import_project_resource({
  call: {
    callId: 'resource-call-1',
    arguments: {
      resource_name: 'probe.txt',
      resource_kind: 'text',
      content_hash: contentHash,
      mime: 'text/plain',
      size: stagedBlob.size,
    },
  },
  project: {
    getResourcesManager: () => ({
      addResource: () => {},
      hasResource: name => name === 'probe.txt',
    }),
  },
});
assert.equal(resourceImport.result.success, true);
assert.deepEqual(resourceImport.transientObjectUrls, []);
assert.match(importedResourceFile, /^blob:/);
assert.equal(await (await fetch(importedResourceFile)).text(), 'resource remains readable');
assert.deepEqual(revokedObjectUrls, []);
resourceRegistry.dispose();
assert.deepEqual(revokedObjectUrls, [importedResourceFile]);
await assert.rejects(fetch(importedResourceFile));

const capabilityProject = {
  hasEventsFunctionsExtensionNamed: name => installedExtensionNames.has(name),
  getCurrentPlatform: () => ({ isExtensionLoaded: () => false }),
};
const capabilityWrappers = wrappersModule.createPlaymeshAiLocalToolWrappers();
const localSearch = await capabilityWrappers.search_gdevelop_capabilities({
  call: {
    callId: 'local-search-call-1',
    arguments: { query: 'Playmesh', kind: 'extension' },
  },
  project: capabilityProject,
});
assert.equal(localSearch.result.success, true);
assert.equal(localSearch.result.output.status, 'available');
assert.equal(localSearch.result.output.total, 1);
assert.equal(localSearch.result.output.items[0].stableId, 'Playmesh');
assert.equal(localSearch.result.output.items[0].installed, false);
const localDetails = await capabilityWrappers.get_gdevelop_capability_details({
  call: {
    callId: 'local-details-call-1',
    arguments: { type: 'extension', stable_id: 'Playmesh' },
  },
  project: capabilityProject,
});
assert.equal(localDetails.result.success, true);
assert.equal(localDetails.result.output.status, 'available');
assert.equal(localDetails.result.output.capability.stableId, 'Playmesh');
assert.equal(
  localDetails.result.output.capability.source.kind,
  'playmesh-local-extension'
);
assert.deepEqual(
  localDetails.result.output.capability.conditions.map(item => item.name),
  ['IsAvailable']
);

const originalFetch = globalThis.fetch;
const extensionLifecycle = [];
try {
  globalThis.fetch = async (url, options = {}) => {
    if (String(url).includes('/catalog/capabilities/extension/')) {
      return new Response(
        JSON.stringify({
          capability: {
            stableId: 'extension:ProbeExtension',
            type: 'extension',
            ownerExtension: 'ProbeExtension',
            dependencies: [],
            artifact: {
              id: 'probe',
              kind: 'extension',
              repository: 'fixture',
              commit: 'fixture',
              rootTreeSha: 'fixture',
              path: 'ProbeExtension.json',
              declaredBytes: 2,
              sha256: 'd'.repeat(64),
              mediaType: 'application/json',
            },
          },
        }),
        { status: 200 }
      );
    }
    if (url === '/dev/api/gdevelop/catalog/artifact' && options.method === 'POST') {
      return new Response(JSON.stringify({ name: 'ProbeExtension' }), {
        status: 200,
      });
    }
    throw new Error(`Unexpected extension fixture URL: ${url}`);
  };
  const extensionProject = capabilityProject;
  const extensionWrappers = wrappersModule.createPlaymeshAiLocalToolWrappers();
  const extensionResult = await extensionWrappers.install_gdevelop_extension({
    call: {
      callId: 'extension-call-1',
      arguments: { type: 'extension', stable_id: 'ProbeExtension' },
    },
    project: extensionProject,
    runnerOptions: {
      onWillInstallExtension: names => extensionLifecycle.push(['will', names]),
      onExtensionInstalled: names => extensionLifecycle.push(['installed', names]),
    },
  });
  assert.equal(extensionResult.result.success, true);
  assert.deepEqual(extensionLifecycle, [
    ['will', ['ProbeExtension']],
    ['apply', ['ProbeExtension']],
    ['installed', ['ProbeExtension']],
  ]);
  extensionLifecycle.length = 0;
  const localExtensionResult = await extensionWrappers.install_gdevelop_extension({
    call: {
      callId: 'extension-call-2',
      arguments: { type: 'extension', stable_id: 'Playmesh' },
    },
    project: extensionProject,
    runnerOptions: {
      onWillInstallExtension: names => extensionLifecycle.push(['will', names]),
      onExtensionInstalled: names =>
        extensionLifecycle.push(['installed', names]),
    },
  });
  assert.equal(localExtensionResult.result.success, true);
  assert.deepEqual(extensionLifecycle, [
    ['will', ['Playmesh']],
    ['apply', ['Playmesh']],
    ['installed', ['Playmesh']],
  ]);
} finally {
  globalThis.fetch = originalFetch;
}

const canonicalTools = JSON.parse(
  await readFile(path.resolve(testDirectory, '../runtime/ai/tools.json'), 'utf8')
);
assert.equal(
  canonicalTools.tools.some(tool => tool.name === 'initialize_project'),
  false
);
assert.doesNotMatch(wrappersSource, /\binitialize_project\b/);

console.log('PlayMesh AI live wrapper callback and resource lifetime tests passed.');
