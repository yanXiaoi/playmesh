import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const overlayDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi'
);
const dataModule = source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);

const runnerSource = await readFile(
  path.join(overlayDirectory, 'PlaymeshAiPiskelRunner.js'),
  'utf8'
);
assert.match(
  runnerSource,
  /pskl\.app\.importService\.newPiskelFromImage\(/
);
assert.match(runnerSource, /piskelController\.renderFrameAt\(index, true\)/);
assert.doesNotMatch(runnerSource, /createImagesFromSheet_|SuperGif|parseGIF/);
const runnerModule = await dataModule(runnerSource);

const importCalls = [];
let currentFrames = [];
const piskelController = {
  setPiskel: piskel => {
    currentFrames = piskel.frames;
  },
  getLayerAt: () => ({
    getFrameAt: index => currentFrames[index],
  }),
  getFrameCount: () => currentFrames.length,
  renderFrameAt: index => ({
    toDataURL: type => `${type};base64,frame-${index}`,
  }),
  getPiskel: () => ({ layers: [{}] }),
  getFPS: () => 12,
};
class FakeImage {
  constructor() {
    this.width = 96;
    this.height = 48;
  }

  set src(value) {
    this.source = value;
    queueMicrotask(() => this.onload());
  }
}
const piskelWindow = {
  Image: FakeImage,
  pskl: {
    app: {
      importService: {
        newPiskelFromImage: (image, options, onComplete) => {
          importCalls.push({ image, options });
          onComplete({
            frames:
              options.importType === 'sheet'
                ? [{}, {}, {}]
                : [{}, {}],
          });
        },
      },
      piskelController,
    },
    utils: {
      serialization: {
        Serializer: { serialize: () => 'unused-one-layer-piskel' },
      },
    },
  },
};

const sheetOutput = await runnerModule.importPiskelImageWithWindow(
  piskelWindow,
  {
    kind: 'spritesheet',
    dataUrl: 'data:image/png;base64,sheet',
    name: 'Walk',
    frameWidth: 32,
    frameHeight: 16,
    frameOffsetX: 2,
    frameOffsetY: 3,
  }
);
assert.deepEqual(importCalls[0].options, {
  importType: 'sheet',
  name: 'Walk',
  smoothing: false,
  frameSizeX: 32,
  frameSizeY: 16,
  frameOffsetX: 2,
  frameOffsetY: 3,
});
assert.equal(sheetOutput.resources.length, 3);
assert.deepEqual(
  sheetOutput.resources.map(resource => resource.dataUrl),
  [
    'image/png;base64,frame-0',
    'image/png;base64,frame-1',
    'image/png;base64,frame-2',
  ]
);

const gifOutput = await runnerModule.importPiskelImageWithWindow(
  piskelWindow,
  {
    kind: 'gif',
    dataUrl: 'data:image/gif;base64,animated',
    name: 'Idle',
  }
);
assert.deepEqual(importCalls[1].options, {
  importType: 'single',
  name: 'Idle',
  smoothing: false,
  frameSizeX: 96,
  frameSizeY: 48,
  frameOffsetX: 0,
  frameOffsetY: 0,
});
assert.equal(gifOutput.resources.length, 2);

const officialPiskelBundle = await readFile(
  path.resolve(
    testDirectory,
    '../../official/external-editors/piskel/piskel-editor/js/piskel-packaged-2025-04-07-05-19.js'
  ),
  'utf8'
);
assert.match(
  officialPiskelBundle,
  /ImportService\.prototype\.newPiskelFromImage = function/
);
assert.match(
  officialPiskelBundle,
  /this\.createImagesFromSheet_\(images\[0\], frameSizeX, frameSizeY, frameOffsetX, frameOffsetY\)/
);
assert.match(
  officialPiskelBundle,
  /gifLoader\.getFrames\(\)\.map\(function \(frame\)/
);

const resourceLifecycle = [];
const resource = {
  getName: () => 'Walk',
  getFile: () => 'blob:stable-walk',
};
globalThis.__playmeshPiskelWriterDeps = {
  freeBlobsAndUpdateMetadata: ({ modifiedResources }) => {
    resourceLifecycle.push(['free', modifiedResources]);
  },
  patchExternalEditorMetadataWithResourcesNamesIfNecessary: names => {
    resourceLifecycle.push(['patch', names]);
  },
  saveBlobUrlsFromExternalEditorBase64Resources: async options => {
    resourceLifecycle.push(['save', options]);
    return [{ resource, blobUrl: 'blob:temporary-walk' }];
  },
  triggerOnResourceExternallyChanged: options => {
    resourceLifecycle.push(['changed', options]);
  },
};
let writerSource = await readFile(
  path.join(overlayDirectory, 'PlaymeshAiExternalEditorResourceWriter.js'),
  'utf8'
);
assert.doesNotMatch(writerSource, /fetchPlaymeshLocalResources/);
writerSource = writerSource.replace(
  /import \{[\s\S]*?\} from '\.\.\/ResourcesList\/ResourceExternalEditor';\nimport \{ triggerOnResourceExternallyChanged \} from '\.\.\/MainFrame\/ResourcesWatcher';/,
  `const {
    freeBlobsAndUpdateMetadata,
    patchExternalEditorMetadataWithResourcesNamesIfNecessary,
    saveBlobUrlsFromExternalEditorBase64Resources,
    triggerOnResourceExternallyChanged,
  } = globalThis.__playmeshPiskelWriterDeps;`
);
const writerModule = await dataModule(writerSource);
const project = {
  getResourcesManager: () => ({
    hasResource: name => name === 'Walk',
    getResource: () => resource,
  }),
};
const written = await writerModule.writePlaymeshAiExternalEditorOutput({
  project,
  externalEditorOutput: sheetOutput,
  resourceKind: 'image',
  metadataKey: 'pskl',
  onFetchNewlyAddedResources: async () =>
    resourceLifecycle.push(['fetch']),
  onNewResourcesAdded: () => resourceLifecycle.push(['new']),
});
assert.deepEqual(
  resourceLifecycle.map(entry => entry[0]),
  ['save', 'fetch', 'free', 'new', 'patch', 'changed']
);
assert.deepEqual(written.resources, [
  { name: 'Walk', originalIndex: undefined },
]);
assert.deepEqual(written.newMetadata, { pskl: {} });

const toolDependencies = {
  convertBlobToDataURL: async () => 'data:image/png;base64,staged-sheet',
  addAnimationFrame: (_animations, direction, frameResource, onSpriteAdded) => {
    const sprite = {
      setFullImageCollisionMask: () => {},
      setCustomCollisionMask: () => {},
    };
    onSpriteAdded(sprite);
    direction.frames.push(frameResource.getName());
  },
  getFirstAnimationFrame: () => null,
  runPlaymeshAiPiskelImport: async () => {
    throw new Error('the injected runner must be used');
  },
  writePlaymeshAiExternalEditorOutput: async options => {
    toolDependencies.writerOptions = options;
    return {
      resources: [{ name: 'Walk' }, { name: 'Walk2' }],
      newName: 'Walk',
      newMetadata: { pskl: {} },
    };
  },
};
const storedAnimations = [];
class FakeAnimation {
  constructor() {
    this.direction = {
      frames: [],
      setTimeBetweenFrames: value => {
        this.direction.timeBetweenFrames = value;
      },
      setLoop: value => {
        this.direction.looping = value;
      },
      setMetadata: value => {
        this.direction.metadata = value;
      },
    };
  }

  setName(name) {
    this.name = name;
  }

  setDirectionsCount() {}

  getDirection() {
    return this.direction;
  }

  delete() {}
}
const animations = {
  adaptCollisionMaskAutomatically: () => false,
  addAnimation: animation =>
    storedAnimations.push({
      name: animation.name,
      direction: {
        frames: [...animation.direction.frames],
        timeBetweenFrames: animation.direction.timeBetweenFrames,
        looping: animation.direction.looping,
        metadata: animation.direction.metadata,
      },
    }),
  getAnimationsCount: () => storedAnimations.length,
};
toolDependencies.gd = {
  Animation: FakeAnimation,
  asSpriteConfiguration: configuration => configuration,
};
globalThis.__playmeshPiskelToolDeps = toolDependencies;
let toolSource = await readFile(
  path.join(overlayDirectory, 'PlaymeshAiPiskelTool.js'),
  'utf8'
);
toolSource = toolSource.replace(
  /import \{ convertBlobToDataURL \}[\s\S]*?const gd \/\*: libGDevelop \*\/ = global\.gd;/,
  `const {
    convertBlobToDataURL,
    addAnimationFrame,
    getFirstAnimationFrame,
    runPlaymeshAiPiskelImport,
    writePlaymeshAiExternalEditorOutput,
    gd,
  } = globalThis.__playmeshPiskelToolDeps;`
);
const toolModule = await dataModule(toolSource);
const runPiskelOptions = [];
const piskelMutationLifecycle = [];
const onFetchNewlyAddedResources = async () => {};
const piskelWrappers = toolModule.createPlaymeshAiPiskelToolWrappers({
  stagedResource: { blob: new Blob(['sheet']) },
  beforeProjectMutation: () => piskelMutationLifecycle.push('commit'),
  onFetchNewlyAddedResources,
  runPiskelImport: async options => {
    runPiskelOptions.push(options);
    piskelMutationLifecycle.push('runner');
    return {
      resources: sheetOutput.resources,
      externalEditorData: {},
      baseNameForNewResources: 'Walk',
      fps: 12,
    };
  },
});
const scene = {
  getObjects: () => ({
    hasObjectNamed: name => name === 'Hero',
    getObject: () => ({
      getType: () => 'Sprite',
      getConfiguration: () => ({ getAnimations: () => animations }),
    }),
  }),
};
const objectNotifications = [];
const toolResult = await piskelWrappers.import_sprite_sheet_animation({
  call: {
    callId: 'piskel-call-1',
    arguments: {
      scene_name: 'Game',
      object_name: 'Hero',
      target_object_scope: 'scene',
      animation_name: 'Walk',
      frame_width: 32,
      frame_height: 16,
      frame_offset_x: 2,
      frame_offset_y: 3,
      fps: 8,
      looping: true,
    },
  },
  project: {
    hasLayoutNamed: name => name === 'Game',
    getLayout: () => scene,
    getObjects: () => ({ hasObjectNamed: () => false }),
    getResourcesManager: () => ({
      getResource: name => ({ getName: () => name }),
    }),
  },
  runnerOptions: {
    onObjectsModifiedOutsideEditor: changes =>
      objectNotifications.push(changes),
  },
});
assert.deepEqual(runPiskelOptions[0], {
  kind: 'spritesheet',
  dataUrl: 'data:image/png;base64,staged-sheet',
  name: 'Walk',
  frameWidth: 32,
  frameHeight: 16,
  frameOffsetX: 2,
  frameOffsetY: 3,
});
assert.deepEqual(storedAnimations, [
  {
    name: 'Walk',
    direction: {
      frames: ['Walk', 'Walk2'],
      timeBetweenFrames: 0.125,
      looping: true,
      metadata: '{"pskl":{}}',
    },
  },
]);
assert.equal(toolResult.result.success, true);
assert.equal(toolResult.result.output.frame_count, 2);
assert.equal(toolResult.result.output.target_object_scope, 'scene');
assert.deepEqual(piskelMutationLifecycle, ['runner', 'commit']);
assert.equal(
  toolDependencies.writerOptions.onFetchNewlyAddedResources,
  onFetchNewlyAddedResources
);
assert.deepEqual(objectNotifications, [
  { scene, isNewObjectTypeUsed: false },
]);

const piskelBoundaryFailure = new Error('piskel-mutation-boundary-rejected');
let rejectedPiskelProjectReads = 0;
const writerOptionsBeforeRejectedBoundary = toolDependencies.writerOptions;
const rejectedPiskelWrappers = toolModule.createPlaymeshAiPiskelToolWrappers({
  stagedResource: { blob: new Blob(['sheet']) },
  beforeProjectMutation: () => {
    throw piskelBoundaryFailure;
  },
  runPiskelImport: async () => ({
    resources: sheetOutput.resources,
    externalEditorData: {},
    baseNameForNewResources: 'Walk',
    fps: 12,
  }),
});
await assert.rejects(
  rejectedPiskelWrappers.import_sprite_sheet_animation({
    call: {
      callId: 'piskel-rejected-boundary',
      arguments: {
        scene_name: 'Game',
        object_name: 'Hero',
        target_object_scope: 'scene',
        animation_name: 'Walk',
        frame_width: 32,
        frame_height: 16,
      },
    },
    project: {
      hasLayoutNamed: () => {
        rejectedPiskelProjectReads++;
        throw new Error('a rejected boundary must not read the stale project');
      },
    },
    runnerOptions: {},
  }),
  error => error === piskelBoundaryFailure
);
assert.equal(rejectedPiskelProjectReads, 0);
assert.equal(
  toolDependencies.writerOptions,
  writerOptionsBeforeRejectedBoundary
);

const globalScene = {
  getObjects: () => ({
    hasObjectNamed: name => name === 'Hero',
    getObject: () => ({ getType: () => 'NotSprite' }),
  }),
};
const globalResult = await piskelWrappers.import_gif_animation({
  call: {
    callId: 'piskel-call-2',
    arguments: {
      scene_name: 'Game',
      object_name: 'Hero',
      target_object_scope: 'global',
      animation_name: 'Idle',
      looping: false,
    },
  },
  project: {
    hasLayoutNamed: name => name === 'Game',
    getLayout: () => globalScene,
    getObjects: () => ({
      hasObjectNamed: name => name === 'Hero',
      getObject: () => ({
        getType: () => 'Sprite',
        getConfiguration: () => ({ getAnimations: () => animations }),
      }),
    }),
    getResourcesManager: () => ({
      getResource: name => ({ getName: () => name }),
    }),
  },
  runnerOptions: {
    onObjectsModifiedOutsideEditor: changes =>
      objectNotifications.push(changes),
  },
});
assert.equal(globalResult.result.output.target_object_scope, 'global');
assert.deepEqual(piskelMutationLifecycle, [
  'runner',
  'commit',
  'runner',
  'commit',
]);
assert.equal(storedAnimations[1].name, 'Idle');
assert.equal(storedAnimations[1].direction.looping, false);
assert.deepEqual(objectNotifications[1], {
  scene: globalScene,
  isNewObjectTypeUsed: false,
});

const contract = JSON.parse(
  await readFile(path.resolve(testDirectory, '../runtime/ai/tools.json'), 'utf8')
);
for (const name of [
  'import_sprite_sheet_animation',
  'import_gif_animation',
]) {
  const tool = contract.tools.find(candidate => candidate.name === name);
  assert.ok(tool, `${name} must be present in the AI tools contract`);
  assert.equal(tool.implementation, 'playmesh_wrapper');
  assert.equal(tool.executionKind, 'agent_resource_cas');
  assert.equal(tool.approvalRequired, true);
  assert.equal(tool.binaryStaging.loopbackOnly, false);
  assert.match(tool.binaryStaging.path, /resource-staging\/\{contentHash\}$/);
  assert.ok(tool.argumentsSchema.required.includes('target_object_scope'));
  assert.deepEqual(tool.argumentsSchema.properties.target_object_scope.enum, [
    'scene',
    'global',
  ]);
  assert.equal(
    tool.officialImplementationName,
    'pskl.app.importService.newPiskelFromImage'
  );
}
assert.deepEqual(
  contract.tools.find(tool => tool.name === 'import_sprite_sheet_animation')
    .argumentsSchema.required.slice(-2),
  ['frame_width', 'frame_height']
);

console.log('PlayMesh bundled Piskel AI tool tests passed.');
