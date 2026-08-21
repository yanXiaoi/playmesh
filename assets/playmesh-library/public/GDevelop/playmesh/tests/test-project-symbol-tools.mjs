import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const wrapperPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiLocalToolWrappers.js'
);
const adapterPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiEditorFunctionAdapter.js'
);

let wrapperSource = await readFile(wrapperPath, 'utf8');
assert.match(wrapperSource, /list_project_objects:/);
assert.doesNotMatch(wrapperSource, /inspect_variables:/);
const objectSummarySource = wrapperSource.slice(
  wrapperSource.indexOf('const summarizeProjectObjects ='),
  wrapperSource.indexOf('const prefabObjectType =')
);
assert.doesNotMatch(objectSummarySource, /\.(?:slice|splice)\(/);
wrapperSource = wrapperSource
  .replace(
    /import \{\s*getPlaymeshBehaviorsRegistry,\s*getPlaymeshExtension,\s*getPlaymeshExtensionsRegistry,\s*\} from '\.\.\/PlaymeshCatalog\/PlaymeshCatalogSource';\r?\n/,
    ''
  )
  .replace(/^import .*;\r?\n/gm, '')
  .replace(
    '// @flow',
    '// @flow\n' +
      'const playmeshAiRuntimeDebuggerTools = { wrappers: {} };\n' +
      'const createPlaymeshAiPiskelToolWrappers = () => ({});\n' +
      'const createPlaymeshAiJfxrYarnTools = () => ({});'
  );

const localTools = await import(
  `data:text/javascript;base64,${Buffer.from(wrapperSource).toString('base64')}`
);

const vector = values => ({ toJSArray: () => [...values] });
const behavior = (name, type) => ({
  getName: () => name,
  getTypeName: () => type,
});
const object = (name, type, behaviors = []) => {
  const behaviorByName = new Map(
    behaviors.map(item => [item.getName(), item])
  );
  return {
    getName: () => name,
    getType: () => type,
    getAllBehaviorNames: () => vector([...behaviorByName.keys()]),
    getBehavior: behaviorName => behaviorByName.get(behaviorName),
  };
};
const group = (name, members) => ({
  getName: () => name,
  getAllObjectsNames: () => vector(members),
});
const objectsContainer = (objects, groups) => ({
  getObjectsCount: () => objects.length,
  getObjectAt: index => objects[index],
  getObjectGroups: () => ({
    count: () => groups.length,
    getAt: index => groups[index],
  }),
});

const sceneObjects = [
  object('Player', 'Sprite', [
    behavior('Movement', 'PlatformBehavior::PlatformerObjectBehavior'),
    behavior('Network', 'Multiplayer::MultiplayerObject'),
  ]),
  object('UnusedMarker', 'Sprite'),
  ...Array.from({ length: 2048 }, (_, index) =>
    object(`SceneObject${index}`, 'Sprite')
  ),
];
const globalObjects = [
  object('Hud', 'TextObject::Text', [behavior('Anchor', 'AnchorBehavior')]),
  ...Array.from({ length: 1024 }, (_, index) =>
    object(`GlobalObject${index}`, 'Sprite')
  ),
];
const sceneContainer = objectsContainer(sceneObjects, [
  group('Actors', ['Player', 'UnusedMarker']),
]);
const globalContainer = objectsContainer(globalObjects, [
  group('Interface', ['Hud']),
]);
const project = {
  hasLayoutNamed: name => name === 'Game',
  getLayout: name => {
    assert.equal(name, 'Game');
    return { getObjects: () => sceneContainer };
  },
  getObjects: () => globalContainer,
};

const wrappers = localTools.createPlaymeshAiLocalToolWrappers();
const result = await wrappers.list_project_objects({
  call: {
    callId: 'list-project-objects',
    toolName: 'list_project_objects',
    arguments: { scene_name: 'Game' },
  },
  project,
});
assert.equal(result.result.success, true);
assert.equal(result.result.output.sceneName, 'Game');
assert.equal(
  result.result.output.objects.length,
  sceneObjects.length + globalObjects.length
);
assert.deepEqual(result.result.output.objects[0], {
  name: 'Player',
  type: 'Sprite',
  scope: 'scene',
  behaviors: [
    {
      name: 'Movement',
      type: 'PlatformBehavior::PlatformerObjectBehavior',
    },
    { name: 'Network', type: 'Multiplayer::MultiplayerObject' },
  ],
});
assert.deepEqual(result.result.output.objects[sceneObjects.length], {
  name: 'Hud',
  type: 'TextObject::Text',
  scope: 'global',
  behaviors: [{ name: 'Anchor', type: 'AnchorBehavior' }],
});
assert.equal(result.result.output.objects.at(-1).name, 'GlobalObject1023');
assert.deepEqual(result.result.output.objectGroups, [
  { name: 'Actors', scope: 'scene', members: ['Player', 'UnusedMarker'] },
  { name: 'Interface', scope: 'global', members: ['Hud'] },
]);

await assert.rejects(
  wrappers.list_project_objects({
    call: {
      callId: 'missing-scene',
      toolName: 'list_project_objects',
      arguments: { scene_name: 'Missing' },
    },
    project,
  }),
  error => error.code === 'project_object_scene_not_found'
);

let adapterSource = await readFile(adapterPath, 'utf8');
adapterSource = adapterSource
  .replace(
    "import { processEditorFunctionCalls } from '../EditorFunctions/EditorFunctionCallRunner';",
    'const processEditorFunctionCalls = async () => { throw new Error("unexpected default runner"); };'
  )
  .replace(
    "import { AI_ORCHESTRATOR_TOOLS_VERSION } from '../AiGeneration/Utils';",
    "const AI_ORCHESTRATOR_TOOLS_VERSION = 'v12';"
  );
const adapter = await import(
  `data:text/javascript;base64,${Buffer.from(adapterSource).toString('base64')}`
);
let officialRunnerOptions = null;
const inspectResult = await adapter.executePlaymeshAiEditorFunction({
  call: {
    callId: 'inspect-variables',
    toolName: 'inspect_variables',
    arguments: {
      variable_scope: 'group',
      scene_name: 'Game',
      object_name: 'Actors',
      variable_names_or_paths: ['health'],
    },
  },
  project,
  toolsContract: {
    tools: [
      {
        name: 'inspect_variables',
        implementation: 'official_editor_function',
        officialImplementationName: 'inspect_variables',
        // An obsolete hidden-argument field must never alter v4 direct calls.
        officialArguments: { variable_scope: 'global' },
      },
    ],
  },
  runnerOptions: {},
  runner: async options => {
    officialRunnerOptions = options;
    return {
      results: [
        {
          status: 'finished',
          call_id: 'inspect-variables',
          success: true,
          output: { variables: [] },
        },
      ],
      createdProject: null,
      createdSceneNames: [],
    };
  },
});
assert.equal(inspectResult.result.success, true);
assert.equal(officialRunnerOptions.toolsVersion, 'v12');
assert.equal(officialRunnerOptions.functionCalls.length, 1);
assert.equal(
  officialRunnerOptions.functionCalls[0].name,
  'inspect_variables'
);
assert.deepEqual(
  JSON.parse(officialRunnerOptions.functionCalls[0].arguments),
  {
    variable_scope: 'group',
    scene_name: 'Game',
    object_name: 'Actors',
    variable_names_or_paths: ['health'],
  }
);

const groupMembershipMapping = adapter.toGDevelopEditorFunctionCall({
  call: {
    callId: 'change-group-members',
    toolName: 'change_scene_properties_layers_effects_groups',
    arguments: {
      scene_name: 'Game',
      changed_groups: [
        {
          group_name: 'grp_TerrainChunks',
          objects_to_add: ['GroundTile', 'WaterTile'],
          objects_to_remove: ['OldTile'],
        },
      ],
    },
  },
  toolsContract: {
    tools: [
      {
        name: 'change_scene_properties_layers_effects_groups',
        implementation: 'official_editor_function',
        officialImplementationName:
          'change_scene_properties_layers_effects_groups',
      },
    ],
  },
});
assert.equal(
  groupMembershipMapping.functionCall.name,
  'change_scene_properties_layers_effects_groups'
);
assert.deepEqual(
  JSON.parse(groupMembershipMapping.functionCall.arguments),
  {
    scene_name: 'Game',
    changed_groups: [
      {
        group_name: 'grp_TerrainChunks',
        objects_to_add: ['GroundTile', 'WaterTile'],
        objects_to_remove: ['OldTile'],
      },
    ],
  }
);

console.log('GDevelop project symbol tool tests passed.');
