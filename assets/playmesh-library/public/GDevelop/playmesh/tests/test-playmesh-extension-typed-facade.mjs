import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const extensionPath = path.join(
  playmeshDirectory,
  'extensions',
  'Playmesh.json'
);
const descriptorSnapshotPath = path.join(
  playmeshDirectory,
  'scripts',
  'playmesh-built-in-capabilities.snapshot.json'
);

const expectedExecuteCommands = Object.freeze(`
playmesh.main.gameInfo.getCurrent
playmesh.main.session.isAuthority
playmesh.main.session.getCurrent
playmesh.main.session.start
playmesh.main.session.finish
playmesh.main.player.getCurrent
playmesh.main.player.setNickname
playmesh.main.game.submitAction
playmesh.main.rpc.request
playmesh.main.binary.createChannel
playmesh.main.binary.joinChannel
playmesh.main.sync.startAuthority
playmesh.main.sync.submitAction
playmesh.main.sync.submitState
playmesh.main.sync.requestSnapshot
playmesh.main.sync.getSnapshot
playmesh.main.storage.getBucket
playmesh.main.db.open
playmesh.main.db.select
playmesh.main.db.update
playmesh.main.db.delete
playmesh.main.db.insert
playmesh.main.db.getDDL
playmesh.main.db.beginTransaction
PlaymeshDatabaseTransaction.select
PlaymeshDatabaseTransaction.update
PlaymeshDatabaseTransaction.delete
PlaymeshDatabaseTransaction.insert
PlaymeshDatabaseTransaction.getDDL
PlaymeshDatabaseTransaction.commit
PlaymeshDatabaseTransaction.rollback
PlaymeshBinaryChannel.send
PlaymeshBinaryChannel.sendLatest
PlaymeshBinaryChannel.close
PlaymeshSyncAuthorityController.getState
PlaymeshSyncAuthorityController.setState
PlaymeshSyncAuthorityController.publish
PlaymeshSyncAuthorityController.stop
PlaymeshStorageBucket.getData
PlaymeshStorageBucket.setData
PlaymeshStorageBucket.getDataSync
PlaymeshStorageBucket.setDataSync
PlaymeshStorageBucket.removeData
PlaymeshStorageBucket.clearData
PlaymeshStorageBucket.upload
playmesh.app.isAvailable
playmesh.app.identity.getCurrent
playmesh.app.runtime.getLocale
playmesh.app.storage.getBucket
PlaymeshAppStorageBucket.getData
PlaymeshAppStorageBucket.setData
PlaymeshAppStorageBucket.getDataSync
PlaymeshAppStorageBucket.setDataSync
PlaymeshAppStorageBucket.removeData
PlaymeshAppStorageBucket.clearData
playmesh.app.performance.getFps
playmesh.app.performance.getLatency
playmesh.app.performance.getLatencyDiagnostics
playmesh.app.performance.setVisible
playmesh.app.performance.reportFrame
playmesh.app.capabilities.getRegistry
playmesh.app.capabilities.getAvailable
playmesh.app.capabilities.getDeclared
playmesh.app.capabilities.create
playmesh.app.media.open
playmesh.app.webrtc.getSignalingEndpoint
playmesh.app.device.getPlatform
playmesh.app.device.setFullscreen
playmesh.app.ui.disableSystemMenuTriggers
playmesh.app.ui.initializeBrowser
playmesh.app.ui.configure
playmesh.app.ui.showGameSidebar
playmesh.app.ui.restartGame
playmesh.app.ui.openSharePanel
playmesh.app.ui.openRuntimeLogs
playmesh.app.ui.enterFullscreen
playmesh.app.ui.exitFullscreen
playmesh.app.ui.openGameInfo
playmesh.app.ui.setPerformanceVisible
playmesh.app.ui.togglePerformance
playmesh.app.ui.exitGame
playmesh.app.lan.discoverGames
playmesh.app.lan.joinByLink
playmesh.app.lan.scanQrAndJoin
playmesh.app.lan.setPublished
playmesh.app.lan.getShareLinks
PlaymeshCapabilityHandle.invoke
PlaymeshCapabilityHandle.removeEventListener
PlaymeshCapabilityHandle.dispose
PlaymeshAppMediaSession.close
PlaymeshLanGame.join
`.trim().split(/\r?\n/u));

const expectedSubscribeCommands = Object.freeze(`
playmesh.main.session.onStateChange
playmesh.main.session.onPlayerJoin
playmesh.main.session.onPlayerLeave
playmesh.main.session.onPlayerReconnect
playmesh.main.game.onMessage
playmesh.main.game.onEvent
playmesh.main.sync.observe
playmesh.main.lifecycle.onChange
playmesh.main.lifecycle.onPause
playmesh.main.lifecycle.onResume
playmesh.main.lifecycle.onExit
PlaymeshBinaryChannel.onMessage
playmesh.app.performance.onFps
playmesh.app.performance.onLatency
playmesh.app.device.onInput
playmesh.app.ui.onGameMenuOpen
playmesh.app.ui.onGameMenuClose
playmesh.app.ui.onSystemMenuRequest
playmesh.app.ui.onBack
PlaymeshCapabilityHandle.on
PlaymeshCapabilityHandle.addEventListener
PlaymeshCapabilityHandle.onError
`.trim().split(/\r?\n/u));

const expectedHandlerCommands = Object.freeze([
  'playmesh.main.authority.onService',
  'playmesh.main.rpc.onRequest',
  'PlaymeshBinaryChannel.onForward',
]);

const expectedCommandsByPrimitive = Object.freeze({
  execute: expectedExecuteCommands,
  subscribe: expectedSubscribeCommands,
  registerHandler: expectedHandlerCommands,
});
const expectedCommands = Object.freeze([
  ...expectedExecuteCommands,
  ...expectedSubscribeCommands,
  ...expectedHandlerCommands,
]);
assert.equal(expectedExecuteCommands.length, 91);
assert.equal(expectedSubscribeCommands.length, 22);
assert.equal(expectedHandlerCommands.length, 3);
assert.equal(expectedCommands.length, 116);
assert.equal(new Set(expectedCommands).size, 116);

const readJson = async filePath => JSON.parse(await readFile(filePath, 'utf8'));
const [extension, capabilityDescriptors] = await Promise.all([
  readJson(extensionPath),
  readJson(descriptorSnapshotPath),
]);
assert.equal(extension.name, 'Playmesh');
assert.ok(Array.isArray(extension.eventsFunctions));
assert.ok(Array.isArray(capabilityDescriptors));
assert.equal(capabilityDescriptors.length, 5);

const publicFunctions = extension.eventsFunctions.filter(
  eventsFunction => eventsFunction.private !== true
);
const functionsByName = new Map(
  extension.eventsFunctions.map(eventsFunction => [eventsFunction.name, eventsFunction])
);
assert.equal(
  functionsByName.size,
  extension.eventsFunctions.length,
  'GDevelop function names must be unique'
);

const sourceOf = eventsFunction =>
  (eventsFunction.events || [])
    .map(event => (typeof event.inlineCode === 'string' ? event.inlineCode : ''))
    .join('\n');
const literalCallsOf = eventsFunction => {
  const calls = [];
  const pattern = /extension\.(execute|callSync|subscribe|registerHandler)\(\s*(["'])([^"']+)\2/gu;
  for (const match of sourceOf(eventsFunction).matchAll(pattern)) {
    calls.push({ primitive: match[1], command: match[3] });
  }
  return calls;
};
const parameterNames = eventsFunction =>
  (eventsFunction.parameters || []).map(parameter => parameter.name);
const parameterByName = (eventsFunction, name) =>
  (eventsFunction.parameters || []).find(parameter => parameter.name === name);
const groupParts = eventsFunction => String(eventsFunction.group || '').split(' ❯ ');
const groupRoot = eventsFunction => groupParts(eventsFunction)[0];
const groupLeaf = eventsFunction => groupParts(eventsFunction)[1];
const mainRoot = 'Main SDK（游戏 SDK）';
const appRoot = 'App SDK（原生 SDK）';
const isMainCommand = command =>
  command.startsWith('playmesh.main.') ||
  command.startsWith('PlaymeshBinaryChannel.') ||
  command.startsWith('PlaymeshSyncAuthorityController.') ||
  command.startsWith('PlaymeshStorageBucket.') ||
  command.startsWith('PlaymeshDatabaseTransaction.');

const typedFunctionsByCommand = new Map();
for (const [primitive, commands] of Object.entries(expectedCommandsByPrimitive)) {
  for (const command of commands) {
    const candidates = publicFunctions.filter(eventsFunction => {
      const calls = literalCallsOf(eventsFunction);
      return (
        calls.length === 1 &&
        calls[0].command === command &&
        (primitive === 'execute'
          ? calls[0].primitive === 'execute' || calls[0].primitive === 'callSync'
          : calls[0].primitive === primitive) &&
        !parameterNames(eventsFunction).includes('Command') &&
        !parameterNames(eventsFunction).includes('ArgumentsJson')
      );
    });
    assert.ok(
      candidates.length > 0,
      `${command} must have an independent public typed wrapper with a fixed literal SDK call`
    );
    const expectedRoot = isMainCommand(command) ? mainRoot : appRoot;
    assert.ok(
      candidates.some(eventsFunction => groupRoot(eventsFunction) === expectedRoot),
      `${command} typed wrapper must be under ${expectedRoot}`
    );
    typedFunctionsByCommand.set(
      command,
      candidates.find(eventsFunction => groupRoot(eventsFunction) === expectedRoot)
    );
  }
}
assert.equal(typedFunctionsByCommand.size, 116);

for (const command of expectedSubscribeCommands) {
  const subscribeFunction = typedFunctionsByCommand.get(command);
  for (const [prefix, expectedType] of [
    ['Has', 'Condition'],
    ['Pop', 'Action'],
  ]) {
    const queueFunction = functionsByName.get(
      `${prefix}${subscribeFunction.name}Event`
    );
    assert.ok(
      queueFunction,
      `${command} must expose its queued event through a ${prefix} facade`
    );
    assert.notEqual(queueFunction.private, true);
    assert.equal(queueFunction.functionType, expectedType);
    assert.equal(queueFunction.group, subscribeFunction.group);
    if (prefix === 'Pop') {
      assert.equal(parameterByName(queueFunction, 'Result')?.type, 'variable');
    }
  }
}
for (const command of expectedHandlerCommands) {
  const handlerFunction = typedFunctionsByCommand.get(command);
  for (const [prefix, expectedType] of [
    ['Has', 'Condition'],
    ['Pop', 'Action'],
  ]) {
    const queueFunction = functionsByName.get(
      `${prefix}${handlerFunction.name}Request`
    );
    assert.ok(
      queueFunction,
      `${command} must expose its queued request through a ${prefix} facade`
    );
    assert.notEqual(queueFunction.private, true);
    assert.equal(queueFunction.functionType, expectedType);
    assert.equal(queueFunction.group, handlerFunction.group);
    if (prefix === 'Pop') {
      assert.equal(parameterByName(queueFunction, 'Result')?.type, 'variable');
    }
  }
}

for (const eventsFunction of publicFunctions) {
  const [, leaf] = groupParts(eventsFunction);
  assert.notEqual(leaf, '原生能力', `${eventsFunction.name} uses an ambiguous leaf`);
  assert.notEqual(leaf, '设备', `${eventsFunction.name} uses an ambiguous leaf`);
  if (
    parameterNames(eventsFunction).includes('Command') ||
    parameterNames(eventsFunction).includes('ArgumentsJson')
  ) {
    assert.match(
      leaf || '',
      /高级/u,
      `${eventsFunction.name} exposes a generic command/JSON entry outside an advanced group`
    );
  }
}
for (const command of [
  'playmesh.app.device.getPlatform',
  'playmesh.app.device.setFullscreen',
  'playmesh.app.device.onInput',
]) {
  assert.equal(
    groupLeaf(typedFunctionsByCommand.get(command)),
    '设备环境',
    `${command} belongs to app.device and must not be merged with capabilities`
  );
}

const dynamicFacadeNames = Object.freeze([
  'CreateDynamicCapability',
  'InvokeDynamicCapability',
  'RemoveDynamicCapabilityEventListener',
  'DisposeDynamicCapability',
  'SubscribeDynamicCapabilityEvent',
  'AddDynamicCapabilityEventListener',
  'SubscribeDynamicCapabilityError',
]);
for (const name of dynamicFacadeNames) {
  const eventsFunction = functionsByName.get(name);
  assert.ok(eventsFunction, `missing open-world dynamic capability entry: ${name}`);
  assert.notEqual(eventsFunction.private, true, `${name} must stay public`);
  assert.equal(groupRoot(eventsFunction), appRoot, `${name} must stay under App SDK`);
  assert.equal(
    groupLeaf(eventsFunction),
    '动态能力（高级）',
    `${name} must stay isolated in the advanced dynamic capability group`
  );
}

const assertExactParameterNames = (functionName, expectedNames) => {
  const eventsFunction = functionsByName.get(functionName);
  assert.ok(eventsFunction, `missing typed facade: ${functionName}`);
  assert.deepEqual(parameterNames(eventsFunction), expectedNames, functionName);
};
assertExactParameterNames('GetAppIdentity', ['Result', 'OperationId']);
assertExactParameterNames('DiscoverLanGames', ['Result', 'OperationId']);
assertExactParameterNames('JoinGameByInvitationLink', [
  'InvitationUrl',
  'OperationId',
]);
assertExactParameterNames('ScanQrAndJoinGame', ['OperationId']);
assertExactParameterNames('PublishLanGame', ['OperationId']);
assertExactParameterNames('GetLanShareLinks', ['Result', 'OperationId']);
assertExactParameterNames('JoinDiscoveredLanGame', ['HandleId', 'OperationId']);
assertExactParameterNames('OpenAppMediaSession', [
  'SourceHandleId',
  'UseAbortSignal',
  'AbortHandleId',
  'Result',
  'OperationId',
]);
assertExactParameterNames('CloseAppMediaSession', ['HandleId', 'OperationId']);

const assertPresencePair = (functionName, useName, valueName) => {
  const eventsFunction = functionsByName.get(functionName);
  assert.ok(eventsFunction, `missing optional-argument facade: ${functionName}`);
  const useParameter = parameterByName(eventsFunction, useName);
  const valueParameter = parameterByName(eventsFunction, valueName);
  assert.ok(useParameter, `${functionName} is missing ${useName}`);
  assert.ok(valueParameter, `${functionName} is missing ${valueName}`);
  assert.equal(useParameter.type, 'yesorno', `${functionName}.${useName}`);
  assert.notEqual(
    useParameter.optional,
    true,
    `${functionName}.${useName} must be explicit because omitted yesorno becomes false`
  );
  if (valueParameter.type !== 'variable') {
    assert.equal(
      valueParameter.optional,
      true,
      `${functionName}.${valueName} should remain visually optional behind ${useName}`
    );
  }
  const source = sourceOf(eventsFunction);
  assert.ok(
    source.includes(`getArgument(${JSON.stringify(useName)})`),
    `${functionName} does not branch on ${useName}`
  );
  assert.ok(
    source.includes(`getArgument(${JSON.stringify(valueName)})`),
    `${functionName} does not read ${valueName}`
  );
};

const fixedOptionalPairs = Object.freeze({
  SubmitGameAction: [['UseNamespace', 'Namespace']],
  StartAuthoritySync: [
    ['UseStateType', 'StateType'],
    ['UseTickRate', 'TickRate'],
    ['UseOnInputHandler', 'OnInputHandlerId'],
    ['UseOnTickHandler', 'OnTickHandlerId'],
    ['UseCallbackTimeout', 'CallbackTimeoutMs'],
  ],
  SubmitSyncState: [['UseRateHz', 'RateHz']],
  SetAuthoritySyncState: [['UsePublish', 'Publish']],
  ReportAppFrame: [['UseTimestamp', 'Timestamp']],
  OpenAppMediaSession: [['UseAbortSignal', 'AbortHandleId']],
  SetDeviceFullscreen: [['UseOrientation', 'Orientation']],
  ConfigureAppUi: [
    ['UseFallbackUi', 'FallbackUi'],
    ['UseFloatingButton', 'FloatingButton'],
  ],
  EnterUiFullscreen: [['UseOrientation', 'Orientation']],
  SubscribeLifecycleExit: [
    ['UseHandler', 'HandlerId'],
    ['UseCallbackTimeout', 'CallbackTimeoutMs'],
  ],
  RegisterAuthorityService: [
    ['UseNamespace', 'Namespace'],
    ['UseCallbackTimeout', 'CallbackTimeoutMs'],
  ],
  RegisterBinaryForwardHandler: [['UseCallbackTimeout', 'CallbackTimeoutMs']],
});
for (const [functionName, pairs] of Object.entries(fixedOptionalPairs)) {
  for (const [useName, valueName] of pairs) {
    assertPresencePair(functionName, useName, valueName);
  }
}

const quotedLiteral = value => JSON.stringify(value);
const fixedFunction = (command, literal, expectedLeaf) => {
  const candidates = publicFunctions.filter(eventsFunction => {
    const calls = literalCallsOf(eventsFunction);
    return (
      calls.some(call => call.command === command) &&
      sourceOf(eventsFunction).includes(quotedLiteral(literal)) &&
      (!expectedLeaf || groupLeaf(eventsFunction) === expectedLeaf)
    );
  });
  assert.ok(
    candidates.length > 0,
    `missing fixed typed wrapper for ${command} / ${literal}`
  );
  return candidates[0];
};

const pascalCase = name => name.charAt(0).toUpperCase() + name.slice(1);
const parseSelector = parameter => {
  const source = parameter?.supplementaryInformation;
  if (Array.isArray(source)) return source;
  if (typeof source !== 'string' || !source) return [];
  const value = JSON.parse(source);
  return Array.isArray(value) ? value : [];
};
const expectedParameterType = schema => {
  if (Array.isArray(schema?.enum)) return 'stringWithSelector';
  if (schema?.type === 'string') return 'string';
  if (schema?.type === 'integer' || schema?.type === 'number') return 'expression';
  if (schema?.type === 'boolean') return 'yesorno';
  if (schema?.type === 'array' || schema?.type === 'object') return 'variable';
  assert.fail(`unsupported built-in capability parameter schema: ${JSON.stringify(schema)}`);
};
const schemaConstraintValues = schema => {
  const values = [];
  for (const key of [
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'exclusiveMaximum',
    'minLength',
    'maxLength',
    'minItems',
    'maxItems',
  ]) {
    if (typeof schema?.[key] === 'number') values.push(schema[key]);
  }
  if (schema?.items && typeof schema.items === 'object') {
    values.push(...schemaConstraintValues(schema.items));
  }
  return values;
};
const infrastructureParameters = new Set([
  'HandleId',
  'OperationId',
  'Result',
  'SubscriptionId',
  'HandlerId',
]);
const assertSchemaParameters = (eventsFunction, schema, context) => {
  assert.equal(schema?.type, 'object', `${context} arguments/options schema`);
  const properties = schema.properties || {};
  const required = new Set(schema.required || []);
  const expectedPayloadNames = new Set();
  for (const [propertyName, propertySchema] of Object.entries(properties)) {
    const parameterName = pascalCase(propertyName);
    expectedPayloadNames.add(parameterName);
    const parameter = parameterByName(eventsFunction, parameterName);
    assert.ok(parameter, `${context} is missing parameter ${parameterName}`);
    assert.equal(
      parameter.type,
      expectedParameterType(propertySchema),
      `${context}.${parameterName} type`
    );
    if (required.has(propertyName)) {
      assert.notEqual(parameter.optional, true, `${context}.${parameterName} is required`);
      assert.equal(
        parameterByName(eventsFunction, `Use${parameterName}`),
        undefined,
        `${context}.${propertyName} is required and must not have an omission switch`
      );
    } else {
      expectedPayloadNames.add(`Use${parameterName}`);
      assertPresencePair(eventsFunction.name, `Use${parameterName}`, parameterName);
    }
    if (Array.isArray(propertySchema.enum)) {
      assert.deepEqual(
        parseSelector(parameter),
        propertySchema.enum,
        `${context}.${parameterName} enum choices`
      );
    }
    for (const constraint of schemaConstraintValues(propertySchema)) {
      const description = String(parameter.description || '');
      assert.ok(
        description.includes(String(constraint)) ||
          (constraint === 0 && description.includes('非负')),
        `${context}.${parameterName} description must expose constraint ${constraint}`
      );
    }
  }
  const actualPayloadNames = parameterNames(eventsFunction).filter(
    name => !infrastructureParameters.has(name)
  );
  assert.deepEqual(
    [...new Set(actualPayloadNames)].sort(),
    [...expectedPayloadNames].sort(),
    `${context} must expose exactly the descriptor arguments/options`
  );
};

const builtInLeaves = new Map();
for (const descriptor of capabilityDescriptors) {
  assert.equal(typeof descriptor.code, 'string');
  const createFunction = fixedFunction(
    'playmesh.app.capabilities.create',
    descriptor.code
  );
  assert.equal(groupRoot(createFunction), appRoot, `${descriptor.code} create root`);
  const leaf = groupLeaf(createFunction);
  assert.match(leaf || '', /[\u3400-\u9fff]/u, `${descriptor.code} semantic leaf`);
  assert.ok(
    ![
      '原生能力',
      '设备',
      '设备环境',
      '能力注册表',
      '动态能力（高级）',
    ].includes(leaf),
    `${descriptor.code} must have its own semantic built-in capability group`
  );
  assert.equal(
    builtInLeaves.has(leaf),
    false,
    `${descriptor.code} shares the built-in capability group ${leaf}`
  );
  builtInLeaves.set(leaf, descriptor.code);
  assertSchemaParameters(
    createFunction,
    descriptor.optionsSchema,
    `${descriptor.code}.create`
  );

  for (const method of descriptor.methods || []) {
    const methodFunction = fixedFunction(
      'PlaymeshCapabilityHandle.invoke',
      method.name,
      leaf
    );
    assertSchemaParameters(
      methodFunction,
      method.argumentsSchema,
      `${descriptor.code}.${method.name}`
    );
  }
  for (const event of descriptor.events || []) {
    const eventFunction = fixedFunction(
      'PlaymeshCapabilityHandle.on',
      event.name,
      leaf
    );
    assert.deepEqual(
      [...parameterNames(eventFunction)].sort(),
      ['HandleId', 'SubscriptionId'].sort(),
      `${descriptor.code}.${event.name} subscription parameters`
    );
  }
}
assert.equal(builtInLeaves.size, capabilityDescriptors.length);

process.stdout.write(
  'Playmesh GDevelop typed facade contract passed ' +
    '(116 fixed SDK wrappers; 5 descriptor-driven capability groups).\n'
);
