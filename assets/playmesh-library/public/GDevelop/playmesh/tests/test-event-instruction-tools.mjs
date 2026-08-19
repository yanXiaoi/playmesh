import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const wrapperPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiLocalToolWrappers.js'
);

let source = await readFile(wrapperPath, 'utf8');
assert.match(source, /import \{ serializeToJSObject \} from '\.\.\/Utils\/Serializer'/);
assert.match(source, /enumerateAllInstructions/);
assert.match(source, /enumerateAllExpressions/);
assert.match(source, /enumerateEventsMetadata/);
assert.match(source, /import \{ formatExpressionCall \}/);
assert.doesNotMatch(source, /Multiplayer::|LastJoinedPlayerNumber/);
assert.doesNotMatch(
  source,
  /BuiltinCommonInstructions::(?:Repeat|ForEach|While)/
);
assert.doesNotMatch(
  source,
  /(?:instructions|matches)\.(?:slice|splice)\(|truncateEventInstructions/i
);
source = source
  .replace(
    "import { swapAsset } from '../AssetStore/AssetSwapper';",
    'const swapAsset = () => false;'
  )
  .replace(
    "import PixiResourcesLoader from '../ObjectsRendering/PixiResourcesLoader';",
    'const PixiResourcesLoader = {};'
  )
  .replace(
    "import { addSerializedExtensionsToProject } from '../AssetStore/ExtensionStore/InstallExtension';",
    'const addSerializedExtensionsToProject = async () => {};'
  )
  .replace(
    "import { createNewResource } from '../ResourcesList/ResourceSource';",
    'const createNewResource = () => null;'
  )
  .replace(
    "import { applyResourceDefaults } from '../ResourcesList/ResourceUtils';",
    'const applyResourceDefaults = () => {};'
  )
  .replace(
    "import { serializeToJSObject } from '../Utils/Serializer';",
    'const serializeToJSObject = (...args) => globalThis.__serializeEvents(...args);'
  )
  .replace(
    "import { enumerateAllInstructions } from '../InstructionOrExpression/EnumerateInstructions';",
    'const enumerateAllInstructions = (...args) => globalThis.__enumerateInstructions(...args);'
  )
  .replace(
    "import { enumerateAllExpressions } from '../InstructionOrExpression/EnumerateExpressions';",
    'const enumerateAllExpressions = (...args) => globalThis.__enumerateExpressions(...args);'
  )
  .replace(
    "import { enumerateEventsMetadata } from '../EventsSheet/EnumerateEventsMetadata';",
    'const enumerateEventsMetadata = () => globalThis.__enumerateEventsMetadata();'
  )
  .replace(
    "import { formatExpressionCall } from '../EventsSheet/ParameterFields/GenericExpressionField/FormatExpressionCall';",
    'const formatExpressionCall = (...args) => globalThis.__formatExpressionCall(...args);'
  )
  .replace(
    "import { playmeshAiRuntimeDebuggerTools } from './PlaymeshAiRuntimeDebuggerTools';",
    'const playmeshAiRuntimeDebuggerTools = { wrappers: {} };'
  )
  .replace(
    "import { createPlaymeshAiPiskelToolWrappers } from './PlaymeshAiPiskelTool';",
    'const createPlaymeshAiPiskelToolWrappers = () => ({});'
  )
  .replace(
    "import { createPlaymeshAiJfxrYarnTools } from './PlaymeshAiJfxrYarnTools';",
    'const createPlaymeshAiJfxrYarnTools = () => ({});'
  )
  .replace(
    "import { playmeshResourceObjectUrlRegistry } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshResourceObjectUrlRegistry';",
    "const playmeshResourceObjectUrlRegistry = { acquire: () => { throw new Error('resource registry is not used by event instruction tests'); } };"
  );

const createdEventLists = [];
class MockEventsList {
  constructor() {
    this.eventTypes = [];
    this.deleted = false;
    createdEventLists.push(this);
  }

  insertNewEvent(project, eventType, index) {
    assert.strictEqual(project, globalThis.__eventTemplateProject);
    this.eventTypes.splice(index, 0, eventType);
  }

  delete() {
    this.deleted = true;
  }
}
globalThis.gd = { EventsList: MockEventsList };

const localTools = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`
);

const valueType = ({
  name,
  extraInfo = '',
  optional = false,
  defaultValue = '',
  object = false,
  behavior = false,
  number = false,
  string = false,
  variable = false,
  resource = false,
}) => ({
  getName: () => name,
  getExtraInfo: () => extraInfo,
  isOptional: () => optional,
  getDefaultValue: () => defaultValue,
  isObject: () => object,
  isBehavior: () => behavior,
  isNumber: () => number,
  isString: () => string,
  isVariable: () => variable,
  isResource: () => resource,
});

const parameter = ({
  name,
  type,
  description,
  longDescription = '',
  hint = '',
  extraInfo = '',
  optional = false,
  codeOnly = false,
  defaultValue = '',
  valueTypeMetadata,
}) => ({
  getName: () => name,
  getType: () => type,
  getDescription: () => description,
  getLongDescription: () => longDescription,
  getHint: () => hint,
  getExtraInfo: () => extraInfo,
  isOptional: () => optional,
  isCodeOnly: () => codeOnly,
  getDefaultValue: () => defaultValue,
  getValueTypeMetadata: () => valueTypeMetadata,
});

const instruction = ({
  type,
  fullName,
  description,
  group,
  scope,
  parameters,
  sentence = '',
  hint = '',
  hidden = false,
  privateInstruction = false,
}) => {
  const metadata = {
    getFullName: () => fullName,
    getDescription: () => description,
    getGroup: () => group,
    getSentence: () => sentence,
    getHint: () => hint,
    getIconFilename: () => 'icon.svg',
    getSmallIconFilename: () => 'small-icon.svg',
    getHelpPath: () => '/events/reference',
    canHaveSubInstructions: () => false,
    getUsageComplexity: () => 2,
    isHidden: () => hidden,
    getDeprecationMessage: () => '',
    isPrivate: () => privateInstruction,
    isAsync: () => false,
    isOptionallyAsync: () => true,
    isRelevantForLayoutEvents: () => true,
    isRelevantForFunctionEvents: () => true,
    isRelevantForAsynchronousFunctionEvents: () => true,
    isRelevantForCustomObjectEvents: () => false,
    getParametersCount: () => parameters.length,
    getParameter: index => parameters[index],
  };
  return { type, metadata, scope };
};

const objectParameter = parameter({
  name: 'Object',
  type: 'objectListOrEmptyIfJustDeclared',
  description: 'Object to create.',
  longDescription: 'The object list receiving the new instance.',
  extraInfo: 'Sprite',
  valueTypeMetadata: valueType({
    name: 'object',
    extraInfo: 'Sprite',
    object: true,
  }),
});
const xParameter = parameter({
  name: 'X',
  type: 'expression',
  description: 'X position.',
  hint: 'A scene expression.',
  defaultValue: '0',
  valueTypeMetadata: valueType({
    name: 'number',
    defaultValue: '0',
    number: true,
  }),
});
const yParameter = parameter({
  name: 'Y',
  type: 'expression',
  description: 'Y position.',
  defaultValue: '0',
  valueTypeMetadata: valueType({
    name: 'number',
    defaultValue: '0',
    number: true,
  }),
});
const layerParameter = parameter({
  name: 'Layer',
  type: 'layer',
  description: 'Layer.',
  optional: true,
  defaultValue: '""',
  valueTypeMetadata: valueType({
    name: 'string',
    optional: true,
    defaultValue: '""',
    string: true,
  }),
});
const objectsContextParameter = parameter({
  name: 'Objects context',
  type: 'objectsContext',
  description: '',
  codeOnly: true,
  valueTypeMetadata: valueType({ name: 'objectsContext' }),
});
const playerNumberParameter = parameter({
  name: 'Player number',
  type: 'expression',
  description: 'The player owning the object.',
  valueTypeMetadata: valueType({ name: 'number', number: true }),
});
const ownershipObjectParameter = parameter({
  name: 'Object',
  type: 'object',
  description: 'Object receiving ownership.',
  valueTypeMetadata: valueType({ name: 'object', object: true }),
});
const behaviorParameter = parameter({
  name: 'Behavior',
  type: 'behavior',
  description: 'Multiplayer object behavior.',
  extraInfo: 'MultiplayerObjectBehavior',
  valueTypeMetadata: valueType({
    name: 'behavior',
    extraInfo: 'MultiplayerObjectBehavior',
    behavior: true,
  }),
});
const operatorParameter = parameter({
  name: 'Modification sign',
  type: 'operator',
  description: 'Assignment operator.',
  defaultValue: '=',
  valueTypeMetadata: valueType({ name: 'operator', defaultValue: '=' }),
});

const createFromObjectScope = instruction({
  type: 'Create',
  fullName: 'Create an object',
  description: 'Create an instance at a position.',
  group: 'Objects',
  sentence: 'Create _PARAM1_ at _PARAM2_; _PARAM3_',
  parameters: [
    parameter({
      name: 'Scene',
      type: 'currentScene',
      description: 'Current scene.',
      codeOnly: true,
      valueTypeMetadata: valueType({ name: 'scene' }),
    }),
    objectParameter,
    xParameter,
  ],
  scope: {
    extension: { name: 'BuiltinObject' },
    objectMetadata: { name: 'Sprite', isPrivate: false },
  },
});
const createFromFreeScope = instruction({
  type: 'Create',
  fullName: 'Create an object',
  description: 'Create an instance at a position.',
  group: 'Objects',
  parameters: [
    objectsContextParameter,
    objectParameter,
    xParameter,
    yParameter,
    layerParameter,
  ],
  scope: { extension: { name: 'BuiltinObject' } },
});
const ownershipAction = instruction({
  type:
    'Multiplayer::MultiplayerObjectBehavior::SetPlayerObjectOwnership',
  fullName: 'Set player object ownership',
  description: 'Give ownership of an object to a player.',
  group: 'Multiplayer',
  parameters: [
    ownershipObjectParameter,
    behaviorParameter,
    operatorParameter,
    playerNumberParameter,
  ],
  scope: {
    extension: { name: 'Multiplayer' },
    behaviorMetadata: {
      name: 'MultiplayerObjectBehavior',
      isPrivate: false,
    },
  },
});
const anyPlayerJoinedCondition = instruction({
  type: 'Multiplayer::HasAnyPlayerJoined',
  fullName: 'Any player has joined',
  description: 'Check whether any player joined.',
  group: 'Multiplayer',
  parameters: [],
  scope: { extension: { name: 'Multiplayer' } },
});
const playerJoinedCondition = instruction({
  type: 'Multiplayer::HasPlayerJoined',
  fullName: 'A player has joined',
  description: 'Check whether a player joined.',
  group: 'Multiplayer',
  parameters: [playerNumberParameter],
  scope: { extension: { name: 'Multiplayer' } },
});

const lastJoinedExpressionMetadata = {
  getReturnType: () => 'number',
  getFullName: () => 'Last joined player number',
  getDescription: () => 'Return the number of the last player who joined.',
  getGroup: () => 'Multiplayer',
  isShown: () => true,
  isPrivate: () => false,
  isDeprecated: () => false,
  isRelevantForLayoutEvents: () => true,
  getSmallIconFilename: () => 'multiplayer.svg',
  getHelpPath: () => '/multiplayer/last-joined-player-number',
  getDeprecationMessage: () => '',
  getFunctionName: () => 'LastJoinedPlayerNumber',
  isRelevantForFunctionEvents: () => true,
  isRelevantForAsynchronousFunctionEvents: () => true,
  isRelevantForCustomObjectEvents: () => true,
  getParametersCount: () => 1,
  getParameter: () =>
    parameter({
      name: 'Scene',
      type: 'currentScene',
      description: 'Current scene.',
      codeOnly: true,
      valueTypeMetadata: valueType({ name: 'scene' }),
    }),
};
const lastJoinedExpression = {
  type: 'Multiplayer::LastJoinedPlayerNumber',
  metadata: lastJoinedExpressionMetadata,
  scope: { extension: { name: 'Multiplayer' } },
};
const makeScopedExpression = ({ type, scope, parameters }) => ({
  type,
  name: type,
  scope,
  metadata: {
    ...lastJoinedExpressionMetadata,
    getFullName: () => 'Scoped value',
    getDescription: () => 'Return a scoped value.',
    getGroup: () => 'Scoped expressions',
    getFunctionName: () => 'Value',
    getParametersCount: () => parameters.length,
    getParameter: index => parameters[index],
  },
});
const sharedObjectExpression = makeScopedExpression({
  type: 'Shared::Value',
  scope: {
    extension: { name: 'Shared' },
    objectMetadata: { name: 'Sprite', isPrivate: false },
  },
  parameters: [objectParameter, xParameter],
});
const sharedBehaviorExpression = makeScopedExpression({
  type: 'Shared::Value',
  scope: {
    extension: { name: 'Shared' },
    behaviorMetadata: { name: 'Movement', isPrivate: false },
  },
  parameters: [
    objectParameter,
    parameter({
      name: 'Behavior',
      type: 'behavior',
      description: 'Behavior name.',
      valueTypeMetadata: valueType({ name: 'behavior', behavior: true }),
    }),
    xParameter,
  ],
});

const actions = [
  createFromObjectScope,
  createFromFreeScope,
  ownershipAction,
];
const conditions = [anyPlayerJoinedCondition, playerJoinedCondition];
const enumerateCalls = [];
globalThis.__enumerateInstructions = (isCondition, project, i18n) => {
  enumerateCalls.push({ isCondition, project, i18n });
  return isCondition ? conditions : actions;
};
const expressionCalls = [];
globalThis.__enumerateExpressions = (type, project, i18n) => {
  expressionCalls.push({ type, project, i18n });
  // The official string enumeration also includes number expressions. The
  // wrapper must merge both passes without returning duplicates.
  return [
    lastJoinedExpression,
    sharedObjectExpression,
    sharedBehaviorExpression,
  ];
};
const formatCalls = [];
globalThis.__formatExpressionCall = (
  expression,
  parameterValues,
  options
) => {
  formatCalls.push({ expression, parameterValues, options });
  const formatted = `${expression.type}(${parameterValues.join('|')})`;
  return options.shouldConvertToString
    ? `ToString(${formatted})`
    : formatted;
};

const canonicalEventTemplate = eventType => ({
  type: eventType,
  disabled: false,
  folded: false,
  conditions: [],
  actions: [],
  events: [],
  variables: [],
});
globalThis.__enumerateEventsMetadata = () => [
  {
    type: 'BuiltinCommonInstructions::Standard',
    fullName: 'Standard event',
    description: 'An event with conditions and actions.',
  },
  {
    type: 'BuiltinCommonInstructions::Repeat',
    fullName: 'Repeat',
    description: 'Repeat actions and sub-events.',
  },
  {
    type: 'BuiltinCommonInstructions::ForEach',
    fullName: 'For each object',
    description: 'Repeat for each picked object.',
  },
  {
    type: 'BuiltinCommonInstructions::While',
    fullName: 'While',
    description: 'Repeat while conditions are true.',
  },
];

const serializedEvents = Array.from({ length: 4096 }, (_, index) => ({
  type: 'BuiltinCommonInstructions::Standard',
  conditions: [],
  actions: [{ type: { value: 'Create' }, parameters: [`Object${index}`] }],
}));
const sceneEvents = { marker: 'official-events-list' };
const serializationCalls = [];
globalThis.__serializeEvents = (events, methodName, options) => {
  serializationCalls.push({ events, methodName, options });
  if (events === sceneEvents) return serializedEvents;
  assert.ok(events instanceof MockEventsList);
  return events.eventTypes.map(canonicalEventTemplate);
};

const wrappers = localTools.createPlaymeshAiLocalToolWrappers();
const project = {
  hasLayoutNamed: name => name === 'Game',
  getLayout: name => {
    assert.equal(name, 'Game');
    return { getEvents: () => sceneEvents };
  },
};
globalThis.__eventTemplateProject = project;
const i18n = { _: value => value };

const eventTypesResult = await wrappers.list_event_types({
  call: {
    callId: 'list-event-types',
    toolName: 'list_event_types',
    arguments: {},
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(eventTypesResult.result.output.eventTypes, [
  {
    type: 'BuiltinCommonInstructions::Standard',
    fullName: 'Standard event',
    description: 'An event with conditions and actions.',
  },
  {
    type: 'BuiltinCommonInstructions::Repeat',
    fullName: 'Repeat',
    description: 'Repeat actions and sub-events.',
  },
  {
    type: 'BuiltinCommonInstructions::ForEach',
    fullName: 'For each object',
    description: 'Repeat for each picked object.',
  },
  {
    type: 'BuiltinCommonInstructions::While',
    fullName: 'While',
    description: 'Repeat while conditions are true.',
  },
]);

const eventTypeDetails = await wrappers.get_event_type_details({
  call: {
    callId: 'standard-event-details',
    toolName: 'get_event_type_details',
    arguments: { event_type: 'BuiltinCommonInstructions::Standard' },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(eventTypeDetails.result.output, {
  status: 'available',
  eventType: 'BuiltinCommonInstructions::Standard',
  fullName: 'Standard event',
  description: 'An event with conditions and actions.',
  canonicalEmptyEventJson: canonicalEventTemplate(
    'BuiltinCommonInstructions::Standard'
  ),
  serialization: 'gd.EventsList/5.6.276-canonical',
});
assert.deepEqual(serializationCalls[0], {
  events: createdEventLists[0],
  methodName: 'serializeTo',
  options: { canonicalEventSerialization: true },
});
assert.equal(createdEventLists[0].deleted, true);

for (const complexEventType of [
  'BuiltinCommonInstructions::Repeat',
  'BuiltinCommonInstructions::ForEach',
  'BuiltinCommonInstructions::While',
]) {
  const complexEventDetails = await wrappers.get_event_type_details({
    call: {
      callId: `complex-event-${complexEventType}`,
      toolName: 'get_event_type_details',
      arguments: { event_type: complexEventType },
    },
    project,
    runnerOptions: { i18n },
  });
  assert.equal(complexEventDetails.result.output.status, 'available');
  assert.equal(
    complexEventDetails.result.output.canonicalEmptyEventJson.type,
    complexEventType
  );
  assert.equal(createdEventLists.at(-1).deleted, true);
}

const missingEventType = await wrappers.get_event_type_details({
  call: {
    callId: 'missing-event-details',
    toolName: 'get_event_type_details',
    arguments: { event_type: 'Missing::Event' },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(missingEventType.result.output, {
  status: 'not-found',
  eventType: 'Missing::Event',
});
assert.equal(createdEventLists.length, 4);

const readResult = await wrappers.read_scene_events_json({
  call: {
    callId: 'read-events',
    toolName: 'read_scene_events_json',
    arguments: { scene_name: 'Game' },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(readResult.result.output.serialization, 'gd.EventsList/5.6.276');
assert.strictEqual(readResult.result.output.eventsJson, serializedEvents);
assert.equal(readResult.result.output.eventsJson.length, 4096);
assert.equal(
  readResult.result.output.eventsJson.at(-1).actions[0].parameters[0],
  'Object4095'
);

const listResult = await wrappers.list_event_instructions({
  call: {
    callId: 'list-instructions',
    toolName: 'list_event_instructions',
    arguments: { kind: 'all', query: 'player' },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(listResult.result.success, true);
assert.equal(listResult.result.output.instructions.length, 4);
assert.deepEqual(
  listResult.result.output.instructions.map(item => [
    item.kind,
    item.canonicalType,
  ]),
  [
    [
      'action',
      'Multiplayer::MultiplayerObjectBehavior::SetPlayerObjectOwnership',
    ],
    ['condition', 'Multiplayer::HasAnyPlayerJoined'],
    ['condition', 'Multiplayer::HasPlayerJoined'],
    ['expression', 'Multiplayer::LastJoinedPlayerNumber'],
  ]
);
assert.equal(listResult.result.output.instructions[3].returnType, 'number');
assert.equal('parameters' in listResult.result.output.instructions[0], false);
assert.deepEqual(
  enumerateCalls.map(call => call.isCondition),
  [false, true]
);
assert.strictEqual(enumerateCalls[0].project, project);
assert.strictEqual(enumerateCalls[0].i18n, i18n);
assert.deepEqual(
  expressionCalls.map(call => call.type),
  ['number', 'string']
);

const filteredResult = await wrappers.list_event_instructions({
  call: {
    callId: 'find-multiplayer',
    toolName: 'list_event_instructions',
    arguments: { kind: 'all', query: 'PLAYER JOINED' },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(
  filteredResult.result.output.instructions.map(item => item.canonicalType),
  ['Multiplayer::HasAnyPlayerJoined', 'Multiplayer::HasPlayerJoined']
);

const detailsResult = await wrappers.get_event_instruction_details({
  call: {
    callId: 'create-details',
    toolName: 'get_event_instruction_details',
    arguments: { kind: 'action', instruction_type: 'Create' },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(detailsResult.result.output.status, 'available');
assert.equal(detailsResult.result.output.matches.length, 2);
assert.deepEqual(
  detailsResult.result.output.matches.map(match => match.scope),
  [
    {
      extensionName: 'BuiltinObject',
      object: { name: 'Sprite', isPrivate: false },
      behavior: null,
    },
    {
      extensionName: 'BuiltinObject',
      object: null,
      behavior: null,
    },
  ]
);
assert.deepEqual(
  detailsResult.result.output.matches[0].parameters.map(item => item.index),
  [0, 1, 2]
);
assert.deepEqual(detailsResult.result.output.matches[0].parameters[2], {
  index: 2,
  name: 'X',
  type: 'expression',
  description: 'X position.',
  longDescription: '',
  hint: 'A scene expression.',
  extraInfo: '',
  optional: false,
  codeOnly: false,
  defaultValue: '0',
  valueType: {
    name: 'number',
    extraInfo: '',
    optional: false,
    defaultValue: '0',
    object: false,
    behavior: false,
    number: true,
    string: false,
    variable: false,
    resource: false,
  },
});

const anyPlayerJoinedDetails = await wrappers.get_event_instruction_details({
  call: {
    callId: 'any-player-joined-details',
    toolName: 'get_event_instruction_details',
    arguments: {
      kind: 'condition',
      instruction_type: 'Multiplayer::HasAnyPlayerJoined',
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(
  anyPlayerJoinedDetails.result.output.matches[0].parameters.length,
  0
);

const playerJoinedDetails = await wrappers.get_event_instruction_details({
  call: {
    callId: 'player-joined-details',
    toolName: 'get_event_instruction_details',
    arguments: {
      kind: 'condition',
      instruction_type: 'Multiplayer::HasPlayerJoined',
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(
  playerJoinedDetails.result.output.matches[0].parameters.map(item => item.type),
  ['expression']
);

const ownershipDetails = await wrappers.get_event_instruction_details({
  call: {
    callId: 'ownership-details',
    toolName: 'get_event_instruction_details',
    arguments: {
      kind: 'action',
      instruction_type:
        'Multiplayer::MultiplayerObjectBehavior::SetPlayerObjectOwnership',
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(
  ownershipDetails.result.output.matches[0].parameters.map(item => item.type),
  ['object', 'behavior', 'operator', 'expression']
);
assert.equal(
  ownershipDetails.result.output.matches[0].scope.behavior.name,
  'MultiplayerObjectBehavior'
);

const missingResult = await wrappers.get_event_instruction_details({
  call: {
    callId: 'missing-details',
    toolName: 'get_event_instruction_details',
    arguments: { kind: 'condition', instruction_type: 'Missing::Condition' },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(missingResult.result.output.matches, []);
assert.equal(missingResult.result.output.status, 'not-found');

const expressionDetails = await wrappers.get_event_instruction_details({
  call: {
    callId: 'last-player-details',
    toolName: 'get_event_instruction_details',
    arguments: {
      kind: 'expression',
      instruction_type: 'Multiplayer::LastJoinedPlayerNumber',
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(expressionDetails.result.output.matches.length, 1);
assert.equal(expressionDetails.result.output.matches[0].returnType, 'number');
assert.equal(expressionDetails.result.output.matches[0].parameters.length, 1);
assert.equal(
  expressionDetails.result.output.matches[0].parameters[0]
    .visibleInExpressionCall,
  false
);
assert.equal(
  expressionDetails.result.output.matches[0].parameters[0].codeOnly,
  true
);

const formattedExpression = await wrappers.format_event_expression({
  call: {
    callId: 'format-last-player',
    toolName: 'format_event_expression',
    arguments: {
      instruction_type: 'Multiplayer::LastJoinedPlayerNumber',
      parameter_values: [''],
      should_convert_to_string: true,
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.deepEqual(formattedExpression.result.output, {
  status: 'formatted',
  instructionType: 'Multiplayer::LastJoinedPlayerNumber',
  scope: {
    extensionName: 'Multiplayer',
    object: null,
    behavior: null,
  },
  returnType: 'number',
  expressionText: 'ToString(Multiplayer::LastJoinedPlayerNumber())',
});
assert.strictEqual(formatCalls[0].expression, lastJoinedExpression);
assert.deepEqual(formatCalls[0].parameterValues, ['']);
assert.deepEqual(formatCalls[0].options, { shouldConvertToString: true });

// Evidence for the complete official construction chain: begin with the
// Standard event created by gd.EventsList.insertNewEvent, then use only exact
// canonical instruction types, ordered parameters and formatted expressions
// returned by the discovery tools.
const officialCreateDetails = detailsResult.result.output.matches.find(
  match => match.parameters.length === 5
);
assert.ok(officialCreateDetails);
assert.deepEqual(
  officialCreateDetails.parameters.map(item => [item.type, item.codeOnly]),
  [
    ['objectsContext', true],
    ['objectListOrEmptyIfJustDeclared', false],
    ['expression', false],
    ['expression', false],
    ['layer', false],
  ]
);
const generatedStandardEvent = structuredClone(
  eventTypeDetails.result.output.canonicalEmptyEventJson
);
generatedStandardEvent.conditions.push({
  type: {
    value: anyPlayerJoinedDetails.result.output.matches[0].canonicalType,
    inverted: false,
    await: false,
  },
  parameters: [],
  subInstructions: [],
});
generatedStandardEvent.actions.push(
  {
    type: {
      value: officialCreateDetails.canonicalType,
      inverted: false,
      await: false,
    },
    parameters: ['', 'Player', '100', '200', '""'],
    subInstructions: [],
  },
  {
    type: {
      value: ownershipDetails.result.output.matches[0].canonicalType,
      inverted: false,
      await: false,
    },
    parameters: [
      'Player',
      'MultiplayerObject',
      '=',
      formattedExpression.result.output.expressionText.replace(
        /^ToString\((.*)\)$/,
        '$1'
      ),
    ],
    subInstructions: [],
  }
);
assert.deepEqual(generatedStandardEvent.conditions[0].parameters, []);
assert.deepEqual(generatedStandardEvent.actions[0].parameters, [
  '',
  'Player',
  '100',
  '200',
  '""',
]);
assert.deepEqual(generatedStandardEvent.actions[1], {
  type: {
    value:
      'Multiplayer::MultiplayerObjectBehavior::SetPlayerObjectOwnership',
    inverted: false,
    await: false,
  },
  parameters: [
    'Player',
    'MultiplayerObject',
    '=',
    'Multiplayer::LastJoinedPlayerNumber()',
  ],
  subInstructions: [],
});

const ambiguousExpression = await wrappers.format_event_expression({
  call: {
    callId: 'format-ambiguous',
    toolName: 'format_event_expression',
    arguments: {
      instruction_type: 'Shared::Value',
      parameter_values: ['Player', '2'],
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(ambiguousExpression.result.output.status, 'ambiguous');
assert.equal(ambiguousExpression.result.output.matches.length, 2);
assert.deepEqual(
  ambiguousExpression.result.output.matches.map(match => match.scope),
  [
    {
      extensionName: 'Shared',
      object: { name: 'Sprite', isPrivate: false },
      behavior: null,
    },
    {
      extensionName: 'Shared',
      object: null,
      behavior: { name: 'Movement', isPrivate: false },
    },
  ]
);
assert.equal(formatCalls.length, 1);

const scopedExpression = await wrappers.format_event_expression({
  call: {
    callId: 'format-scoped',
    toolName: 'format_event_expression',
    arguments: {
      instruction_type: 'Shared::Value',
      parameter_values: ['Player', '2'],
      should_convert_to_string: false,
      scope: {
        extension_name: 'Shared',
        object_name: 'Sprite',
      },
    },
  },
  project,
  runnerOptions: { i18n },
});
assert.equal(scopedExpression.result.output.status, 'formatted');
assert.equal(scopedExpression.result.output.expressionText, 'Shared::Value(Player|2)');
assert.strictEqual(formatCalls[1].expression, sharedObjectExpression);
assert.deepEqual(formatCalls[1].parameterValues, ['Player', '2']);
assert.deepEqual(formatCalls[1].options, { shouldConvertToString: false });

await assert.rejects(
  wrappers.format_event_expression({
    call: {
      callId: 'format-wrong-count',
      toolName: 'format_event_expression',
      arguments: {
        instruction_type: 'Shared::Value',
        parameter_values: ['Player'],
        scope: {
          extension_name: 'Shared',
          object_name: 'Sprite',
          behavior_name: null,
        },
      },
    },
    project,
    runnerOptions: { i18n },
  }),
  error => error.code === 'event_expression_parameter_count_mismatch'
);
await assert.rejects(
  wrappers.format_event_expression({
    call: {
      callId: 'format-incomplete-scope',
      toolName: 'format_event_expression',
      arguments: {
        instruction_type: 'Shared::Value',
        parameter_values: ['Player', '2'],
        scope: {
          extension_name: 'Shared',
          object_name: 42,
        },
      },
    },
    project,
    runnerOptions: { i18n },
  }),
  error => error.code === 'invalid_event_expression_scope'
);

await assert.rejects(
  wrappers.list_event_instructions({
    call: {
      callId: 'unsupported-kind',
      arguments: { kind: 'invalid', query: 'anything' },
    },
    project,
    runnerOptions: { i18n },
  }),
  error => error.code === 'invalid_event_instruction_kind'
);
await assert.rejects(
  wrappers.list_event_instructions({
    call: {
      callId: 'missing-query',
      arguments: { kind: 'all' },
    },
    project,
    runnerOptions: { i18n },
  }),
  error => error.code === 'invalid_event_instruction_query'
);
await assert.rejects(
  wrappers.get_event_instruction_details({
    call: {
      callId: 'ambiguous-kind',
      arguments: { kind: 'all', instruction_type: 'Create' },
    },
    project,
    runnerOptions: { i18n },
  }),
  error => error.code === 'invalid_event_instruction_kind'
);

console.log('GDevelop event instruction wrapper tests passed.');
