import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const extensionPath = path.join(
  playmeshDirectory,
  'extensions',
  'Playmesh.json'
);
const lockPath = path.join(playmeshDirectory, 'webide-lock.json');
const defaultProfileRoot = path.join(
  repositoryRoot,
  'work',
  'gdevelop-webide-build-cache',
  'profiles',
  'default'
);
const libGdConfigPath = path.join(defaultProfileRoot, 'libgd-config.json');

const expectedLibGdFiles = Object.freeze({
  'libGD.js': Object.freeze({
    sha256: '6ab78b6c8b23ab890bec0a7972a94c1d269fdbabb5864db8d67d132c3723c9b5',
    size: 2096916,
  }),
  'libGD.wasm': Object.freeze({
    sha256: '041c6da0859f96047d5a2209f15d36ee1b62fc19a2cf132df9b24768d9c7e46d',
    size: 3391975,
  }),
});
const expectedFunctionCount = 402;
const expectedPublicFunctionCount = 362;
const expectedAsyncFunctionCount = 140;

// These are runtime/editor identifiers, not translatable labels. Keep this
// baseline independent from Playmesh.json so changing the extension body
// cannot make the compatibility test silently self-approve an identifier
// rename.
const expectedFunctionNames = Object.freeze([
  'onFirstSceneLoaded',
  'IsSdkPresent',
  'CallMainGameInfo',
  'ReadMainGameInfoProperty',
  'CallMainSession',
  'SubscribeMainSession',
  'CallMainPlayer',
  'CallMainGame',
  'SubscribeMainGame',
  'RegisterMainAuthorityHandler',
  'ReadMainAuthorityProperty',
  'CallMainBinary',
  'SubscribeMainBinary',
  'RegisterMainBinaryHandler',
  'ReadMainBinaryProperty',
  'CallMainSync',
  'SubscribeMainSync',
  'SubscribeMainLifecycle',
  'CallMainStorage',
  'CallAppAvailability',
  'ReadAppAvailabilityProperty',
  'CallAppIdentity',
  'CallAppRuntime',
  'CallAppPerformance',
  'SubscribeAppPerformance',
  'CallAppCapabilities',
  'SubscribeAppCapabilities',
  'ReadAppCapabilitiesProperty',
  'CallAppMedia',
  'ReadAppMediaProperty',
  'CallAppDevice',
  'SubscribeAppDevice',
  'CallAppUi',
  'SubscribeAppUi',
  'CallAppLan',
  'ReadAppLanProperty',
  'OperationFinished',
  'OperationSucceeded',
  'OperationFailed',
  'OperationValueExists',
  'OperationValueIsNull',
  'OperationValueType',
  'OperationValueEquals',
  'OperationJson',
  'OperationValueJson',
  'OperationValueString',
  'OperationValueNumber',
  'CopyOperationValueToVariable',
  'ForgetOperation',
  'LastOperationId',
  'Unsubscribe',
  'HasSubscription',
  'HasEvent',
  'EventValueExists',
  'EventCount',
  'PeekEventJson',
  'EventValueJson',
  'PopEventToVariable',
  'ClearEvents',
  'UnregisterHandler',
  'HasRequest',
  'RequestValueExists',
  'RequestCount',
  'PeekRequestJson',
  'RequestValueJson',
  'PopRequestToVariable',
  'RespondRequest',
  'CancelRequest',
  'HasHandle',
  'HandlePropertyExists',
  'IsOpaqueMediaStream',
  'HandleType',
  'LastHandleId',
  'HandlePropertyJson',
  'CopyHandlePropertyToVariable',
  'ReleaseHandle',
  'HasError',
  'ErrorCount',
  'LastErrorJson',
  'LastErrorCode',
  'LastErrorMessage',
  'PopErrorToVariable',
  'ClearErrors',
  'JsonPathExists',
  'JsonPathJson',
  'JsonPathString',
  'JsonPathNumber',
  'CopyJsonPathToVariable',
  'Utf8ToBase64',
  'Base64ToUtf8',
  'Base64ToHex',
  'HexToBase64',
  'BinaryArgumentJson',
  'VariableToBase64',
  'Base64ToVariable',
  'FileArgumentJson',
  'UploadFile',
  'CreateAbortHandle',
  'AbortMediaOpen',
  'OpenMedia',
]);

const expectedCommands = Object.freeze([
  'playmesh.main.gameInfo.getCurrent',
  'playmesh.main.session.isAuthority',
  'playmesh.main.session.getCurrent',
  'playmesh.main.session.start',
  'playmesh.main.session.finish',
  'playmesh.main.player.getCurrent',
  'playmesh.main.player.setNickname',
  'playmesh.main.game.submitAction',
  'playmesh.main.rpc.request',
  'playmesh.main.binary.createChannel',
  'playmesh.main.binary.joinChannel',
  'playmesh.main.sync.startAuthority',
  'playmesh.main.sync.submitAction',
  'playmesh.main.sync.submitState',
  'playmesh.main.sync.requestSnapshot',
  'playmesh.main.sync.getSnapshot',
  'playmesh.main.storage.getBucket',
  'PlaymeshBinaryChannel.send',
  'PlaymeshBinaryChannel.sendLatest',
  'PlaymeshBinaryChannel.close',
  'PlaymeshSyncAuthorityController.getState',
  'PlaymeshSyncAuthorityController.setState',
  'PlaymeshSyncAuthorityController.publish',
  'PlaymeshSyncAuthorityController.stop',
  'PlaymeshStorageBucket.getData',
  'PlaymeshStorageBucket.setData',
  'PlaymeshStorageBucket.getDataSync',
  'PlaymeshStorageBucket.setDataSync',
  'PlaymeshStorageBucket.removeData',
  'PlaymeshStorageBucket.clearData',
  'PlaymeshStorageBucket.upload',
  'playmesh.app.isAvailable',
  'playmesh.app.identity.getCurrent',
  'playmesh.app.runtime.getLocale',
  'playmesh.app.storage.getBucket',
  'PlaymeshAppStorageBucket.getData',
  'PlaymeshAppStorageBucket.setData',
  'PlaymeshAppStorageBucket.getDataSync',
  'PlaymeshAppStorageBucket.setDataSync',
  'PlaymeshAppStorageBucket.removeData',
  'PlaymeshAppStorageBucket.clearData',
  'playmesh.app.performance.getFps',
  'playmesh.app.performance.getLatency',
  'playmesh.app.performance.getLatencyDiagnostics',
  'playmesh.app.performance.setVisible',
  'playmesh.app.performance.reportFrame',
  'playmesh.app.capabilities.getRegistry',
  'playmesh.app.capabilities.getAvailable',
  'playmesh.app.capabilities.getDeclared',
  'playmesh.app.capabilities.create',
  'playmesh.app.media.open',
  'playmesh.app.device.getPlatform',
  'playmesh.app.device.setFullscreen',
  'playmesh.app.ui.disableSystemMenuTriggers',
  'playmesh.app.ui.initializeBrowser',
  'playmesh.app.ui.configure',
  'playmesh.app.ui.showGameSidebar',
  'playmesh.app.ui.restartGame',
  'playmesh.app.ui.openSharePanel',
  'playmesh.app.ui.openRuntimeLogs',
  'playmesh.app.ui.enterFullscreen',
  'playmesh.app.ui.exitFullscreen',
  'playmesh.app.ui.openGameInfo',
  'playmesh.app.ui.setPerformanceVisible',
  'playmesh.app.ui.togglePerformance',
  'playmesh.app.ui.exitGame',
  'playmesh.app.lan.discoverGames',
  'playmesh.app.lan.joinByLink',
  'playmesh.app.lan.scanQrAndJoin',
  'playmesh.app.lan.setPublished',
  'playmesh.app.lan.getShareLinks',
  'PlaymeshCapabilityHandle.invoke',
  'PlaymeshCapabilityHandle.removeEventListener',
  'PlaymeshCapabilityHandle.dispose',
  'PlaymeshAppMediaSession.close',
  'PlaymeshLanGame.join',
  'playmesh.main.session.onStateChange',
  'playmesh.main.session.onPlayerJoin',
  'playmesh.main.session.onPlayerLeave',
  'playmesh.main.session.onPlayerReconnect',
  'playmesh.main.game.onMessage',
  'playmesh.main.game.onEvent',
  'playmesh.main.sync.observe',
  'playmesh.main.lifecycle.onChange',
  'playmesh.main.lifecycle.onPause',
  'playmesh.main.lifecycle.onResume',
  'playmesh.main.lifecycle.onExit',
  'PlaymeshBinaryChannel.onMessage',
  'playmesh.app.performance.onFps',
  'playmesh.app.performance.onLatency',
  'playmesh.app.device.onInput',
  'playmesh.app.ui.onGameMenuOpen',
  'playmesh.app.ui.onGameMenuClose',
  'PlaymeshCapabilityHandle.on',
  'PlaymeshCapabilityHandle.addEventListener',
  'PlaymeshCapabilityHandle.onError',
  'playmesh.main.authority.onService',
  'playmesh.main.rpc.onRequest',
  'PlaymeshBinaryChannel.onForward',
]);

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const readJson = async filePath => JSON.parse(await readFile(filePath, 'utf8'));
const optionValue = option => {
  const index = process.argv.indexOf(option);
  if (index < 0) return null;
  const value = process.argv[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`${option} requires a directory`);
  }
  return value;
};

const [webIdeLock, libGdConfig, extension] = await Promise.all([
  readJson(lockPath),
  readJson(libGdConfigPath),
  readJson(extensionPath),
]);
assert.equal(webIdeLock.upstream.tag, 'v5.6.276');
assert.equal(
  webIdeLock.upstream.commit,
  '9ef4a53e6a9b351618a1e60a99f7d7f4baf36361'
);
assert.equal(libGdConfig.kind, 'official-exact-commit-artifact');
assert.equal(libGdConfig.revision, webIdeLock.upstream.commit);
assert.equal(
  libGdConfig.urlIdentity,
  `https://s3.amazonaws.com/gdevelop-gdevelop.js/master/commit/${webIdeLock.upstream.commit}`
);

const libGdDirectory = path.resolve(
  optionValue('--libgd') || libGdConfig.cachePath
);
for (const [fileName, expected] of Object.entries(expectedLibGdFiles)) {
  assert.deepEqual(libGdConfig.files[fileName], expected);
  const filePath = path.join(libGdDirectory, fileName);
  const [metadata, bytes] = await Promise.all([stat(filePath), readFile(filePath)]);
  assert.equal(metadata.isFile(), true, `${fileName} must be a regular file`);
  assert.equal(bytes.byteLength, expected.size, `${fileName} size mismatch`);
  assert.equal(sha256(bytes), expected.sha256, `${fileName} SHA-256 mismatch`);
}

const require = createRequire(import.meta.url);
const initializeGDevelopJs = require(path.join(libGdDirectory, 'libGD.js'));
const gd = await initializeGDevelopJs({
  locateFile: fileName => path.join(libGdDirectory, fileName),
});
assert.equal(typeof gd.Project, 'function');
assert.equal(typeof gd.Serializer.fromJSObject, 'function');

// Use the same installation primitive as GDevelop's Extension Store. Loading
// the locked JS platform first registers the built-in JavaScript event type,
// so the extension body itself is deserialized rather than treated as opaque
// fixture data.
const serializedExtensions = gd.Serializer.fromJSObject([extension]);
const project = new gd.Project();
project.addPlatform(gd.JsPlatform.get());
project.unserializeAndInsertExtensionsFrom(serializedExtensions);
assert.equal(project.getEventsFunctionsExtensionsCount(), 1);
assert.equal(project.hasEventsFunctionsExtensionNamed('Playmesh'), true);
const deserializedExtension = project.getEventsFunctionsExtension('Playmesh');
assert.equal(deserializedExtension.getName(), extension.name);
assert.equal(deserializedExtension.getFullName(), extension.fullName);
assert.equal(deserializedExtension.getVersion(), extension.version);
assert.equal(deserializedExtension.getIconUrl(), extension.iconUrl);
assert.equal(
  deserializedExtension.getPreviewIconUrl(),
  extension.previewIconUrl
);
assert.equal(
  extension.eventsFunctions.length,
  expectedFunctionCount,
  'the complete typed facade/editor function count changed'
);
const expectedFunctionNameSet = new Set(expectedFunctionNames);
assert.deepEqual(
  extension.eventsFunctions
    .map(eventsFunction => eventsFunction.name)
    .filter(name => expectedFunctionNameSet.has(name)),
  expectedFunctionNames,
  'the 100 stable GDevelop function identifiers or their relative order changed'
);

const rawFunctionsByName = new Map();
const rawCaseFoldedNames = new Set();
for (const eventsFunction of extension.eventsFunctions) {
  assert.match(eventsFunction.name, /^[A-Za-z][A-Za-z0-9_]*$/);
  assert.equal(
    rawFunctionsByName.has(eventsFunction.name),
    false,
    `duplicate function name: ${eventsFunction.name}`
  );
  const foldedName = eventsFunction.name.toLowerCase();
  assert.equal(
    rawCaseFoldedNames.has(foldedName),
    false,
    `case-insensitive function name collision: ${eventsFunction.name}`
  );
  rawFunctionsByName.set(eventsFunction.name, eventsFunction);
  rawCaseFoldedNames.add(foldedName);
}

const deserializedFunctions = deserializedExtension.getEventsFunctions();
assert.equal(
  deserializedFunctions.getEventsFunctionsCount(),
  extension.eventsFunctions.length,
  'libGD must retain every extension function'
);
const actualFunctionsByName = new Map();
for (
  let index = 0;
  index < deserializedFunctions.getEventsFunctionsCount();
  index += 1
) {
  const actual = deserializedFunctions.getEventsFunctionAt(index);
  assert.equal(
    actualFunctionsByName.has(actual.getName()),
    false,
    `libGD function name collision: ${actual.getName()}`
  );
  actualFunctionsByName.set(actual.getName(), actual);
}
assert.deepEqual(
  [...actualFunctionsByName.keys()],
  extension.eventsFunctions.map(eventsFunction => eventsFunction.name),
  'libGD must retain canonical function order and names'
);

const assertFunctionType = (raw, actual) => {
  if (raw.functionType === 'Action') {
    assert.equal(actual.isAction(), true, raw.name);
    assert.equal(actual.isCondition(), false, raw.name);
    assert.equal(actual.isExpression(), false, raw.name);
    return;
  }
  if (raw.functionType === 'Condition') {
    assert.equal(actual.isAction(), false, raw.name);
    assert.equal(actual.isCondition(), true, raw.name);
    assert.equal(actual.isExpression(), false, raw.name);
    return;
  }
  if (
    raw.functionType === 'Expression' ||
    raw.functionType === 'StringExpression'
  ) {
    assert.equal(actual.isAction(), false, raw.name);
    assert.equal(actual.isCondition(), false, raw.name);
    assert.equal(actual.isExpression(), true, raw.name);
    const expressionType = actual.getExpressionType();
    assert.equal(
      raw.functionType === 'StringExpression'
        ? expressionType.isString()
        : expressionType.isNumber(),
      true,
      `${raw.name} expression value type was not retained`
    );
    return;
  }
  assert.fail(`unsupported canonical function type: ${raw.functionType}`);
};

let asyncFunctionCount = 0;
const actualParameterTypes = new Set();
for (const [name, raw] of rawFunctionsByName) {
  const actual = actualFunctionsByName.get(name);
  assert.ok(actual, `libGD dropped function: ${name}`);
  assert.equal(actual.getFullName(), raw.fullName || '', `${name} fullName`);
  assert.equal(actual.getDescription(), raw.description || '', `${name} description`);
  assert.equal(actual.getGroup(), raw.group || '', `${name} group`);
  assert.equal(actual.getSentence(), raw.sentence || '', `${name} sentence`);
  assert.equal(actual.isPrivate(), raw.private === true, `${name} private`);
  assert.equal(actual.isAsync(), raw.async === true, `${name} async`);
  assertFunctionType(raw, actual);

  const usesPromiseTask = JSON.stringify(raw.events || []).includes(
    'gdjs.PromiseTask'
  );
  assert.equal(
    raw.async === true,
    usesPromiseTask,
    `${name} async metadata and event implementation disagree`
  );
  if (actual.isAsync()) asyncFunctionCount += 1;

  const rawParameters = raw.parameters || [];
  const actualParameters = actual.getParameters();
  assert.equal(
    actualParameters.getParametersCount(),
    rawParameters.length,
    `${name} parameter count`
  );
  for (let index = 0; index < rawParameters.length; index += 1) {
    const rawParameter = rawParameters[index];
    const actualParameter = actualParameters.getParameterAt(index);
    actualParameterTypes.add(actualParameter.getType());
    assert.equal(actualParameter.getName(), rawParameter.name, `${name} parameter name`);
    assert.equal(actualParameter.getType(), rawParameter.type, `${name} parameter type`);
    assert.equal(
      actualParameter.getDescription(),
      rawParameter.description || '',
      `${name}.${rawParameter.name} description`
    );
    assert.equal(
      actualParameter.getExtraInfo(),
      rawParameter.supplementaryInformation || '',
      `${name}.${rawParameter.name} selector metadata`
    );
    assert.equal(
      actualParameter.isOptional(),
      rawParameter.optional === true,
      `${name}.${rawParameter.name} optional metadata`
    );
    assert.equal(
      actualParameter.getDefaultValue(),
      rawParameter.defaultValue || '',
      `${name}.${rawParameter.name} default metadata`
    );
  }
}
const rawAsyncFunctionCount = extension.eventsFunctions.filter(
  eventsFunction => eventsFunction.async === true
).length;
assert.equal(asyncFunctionCount, rawAsyncFunctionCount);
assert.equal(asyncFunctionCount, expectedAsyncFunctionCount);
const supportedParameterTypes = new Set([
  'expression',
  'string',
  'stringWithSelector',
  'variable',
  'yesorno',
]);
for (const type of actualParameterTypes) {
  assert.ok(supportedParameterTypes.has(type), `unsupported editor parameter type: ${type}`);
}
for (const type of supportedParameterTypes) {
  assert.ok(actualParameterTypes.has(type), `typed facades do not exercise ${type}`);
}

const lifecycleFunctions = [...actualFunctionsByName.values()].filter(
  eventsFunction =>
    deserializedExtension.isExtensionLifecycleEventsFunction(
      eventsFunction.getName()
    )
);
assert.equal(lifecycleFunctions.length, 1);
const lifecycleFunction = lifecycleFunctions[0];
assert.equal(lifecycleFunction.getName(), 'onFirstSceneLoaded');
assert.equal(
  gd.MetadataDeclarationHelper.isExtensionLifecycleEventsFunction(
    lifecycleFunction.getName()
  ),
  true
);
assert.equal(lifecycleFunction.isPrivate(), true);
assert.equal(lifecycleFunction.getFullName(), '');
assert.equal(lifecycleFunction.getGroup(), '');
assert.equal(lifecycleFunction.isAction(), true);
assert.equal(lifecycleFunction.isAsync(), false);
assert.equal(lifecycleFunction.getParameters().getParametersCount(), 0);

const publicFunctions = [...actualFunctionsByName.values()].filter(
  eventsFunction => !eventsFunction.isPrivate()
);
assert.equal(
  publicFunctions.length,
  extension.eventsFunctions.filter(eventsFunction => eventsFunction.private !== true)
    .length
);
assert.equal(publicFunctions.length, expectedPublicFunctionCount);
const publicFullNames = new Set();
const mainSdkGroupRoot = 'Main SDK（游戏 SDK）';
const appSdkGroupRoot = 'App SDK（原生 SDK）';
const expectedGroupTree = {
  [mainSdkGroupRoot]: [
    '权威端',
    '请求响应',
    '二进制通信',
    '游戏',
    '游戏信息',
    '生命周期',
    '玩家',
    '会话',
    '存储',
    '状态同步',
    '高级 JSON',
  ],
  [appSdkGroupRoot]: [
    '可用性',
    '能力注册表',
    '动态能力（高级）',
    '设备环境',
    '身份',
    '局域网',
    '媒体会话',
    '性能',
    '运行环境',
    '存储',
    '界面',
    '摄像头',
    '麦克风与语音转文字',
    'MIDI（乐器接口）',
    '震动反馈',
    '空间位姿',
    '高级 JSON',
  ],
  'Results（结果）': ['事件', '操作结果', '回调请求'],
  'Data（数据）': ['二进制与文件', 'JSON 数据'],
  'Resources（资源）': ['句柄', '媒体会话'],
  'Diagnostics（诊断）': ['错误', 'SDK 状态'],
};
assert.equal(Object.keys(expectedGroupTree).length, 6);
assert.equal(
  Object.values(expectedGroupTree).reduce(
    (count, leaves) => count + leaves.length,
    0
  ),
  37
);
const actualGroupTree = new Map();
for (const eventsFunction of publicFunctions) {
  const fullName = eventsFunction.getFullName();
  assert.ok(fullName, `${eventsFunction.getName()} has an empty public name`);
  assert.match(
    fullName,
    /[\u3400-\u9fff]/u,
    `${eventsFunction.getName()} public fullName is not Chinese-visible copy`
  );
  const foldedFullName = fullName.toLowerCase();
  assert.equal(
    publicFullNames.has(foldedFullName),
    false,
    `public full name collision: ${fullName}`
  );
  publicFullNames.add(foldedFullName);

  const group = eventsFunction.getGroup();
  assert.ok(group, `${eventsFunction.getName()} is flattened at the root`);
  assert.equal(group.trim(), group, `${eventsFunction.getName()} group whitespace`);
  const segments = group.split(' ❯ ');
  assert.equal(
    segments.length,
    2,
    `${eventsFunction.getName()} must form one root/leaf editor group`
  );
  assert.ok(segments.every(Boolean), `${eventsFunction.getName()} has an empty group segment`);
  assert.equal(
    segments.every(segment => /[\u3400-\u9fff]/u.test(segment)),
    true,
    `${eventsFunction.getName()} group is not Chinese-visible copy: ${group}`
  );
  const [root, leaf] = segments;
  assert.ok(
    Object.prototype.hasOwnProperty.call(expectedGroupTree, root),
    `${eventsFunction.getName()} has an unknown group root: ${root}`
  );
  if (!actualGroupTree.has(root)) actualGroupTree.set(root, new Set());
  actualGroupTree.get(root).add(leaf);
}
assert.deepEqual(
  Object.fromEntries(
    [...actualGroupTree].map(([root, leaves]) => [root, [...leaves].sort()])
  ),
  Object.fromEntries(
    Object.entries(expectedGroupTree).map(([root, leaves]) => [
      root,
      [...leaves].sort(),
    ])
  )
);

const parseSelector = (eventsFunction, parameter) => {
  assert.equal(parameter.getType(), 'stringWithSelector');
  const value = JSON.parse(parameter.getExtraInfo());
  assert.ok(Array.isArray(value) && value.length > 0);
  assert.equal(
    value.every(item => typeof item === 'string' && item.length > 0),
    true,
    `${eventsFunction.getName()}.${parameter.getName()} selector is invalid`
  );
  return value;
};
const isMainSdkPath = value =>
  value.startsWith('playmesh.main.') ||
  value.startsWith('PlaymeshBinaryChannel.') ||
  value.startsWith('PlaymeshSyncAuthorityController.') ||
  value.startsWith('PlaymeshStorageBucket.');
const isAppSdkPath = value =>
  value.startsWith('playmesh.app.') ||
  value.startsWith('PlaymeshCapabilityHandle.') ||
  value.startsWith('PlaymeshAppMediaSession.') ||
  value.startsWith('PlaymeshAppStorageBucket.') ||
  value.startsWith('PlaymeshLanGame.');
const selectedCommands = [];
const selectedProperties = [];
for (const eventsFunction of publicFunctions) {
  const root = eventsFunction.getGroup().split(' ❯ ')[0];
  const parameters = eventsFunction.getParameters();
  for (let index = 0; index < parameters.getParametersCount(); index += 1) {
    const parameter = parameters.getParameterAt(index);
    if (parameter.getType() !== 'stringWithSelector') continue;
    const selector = parseSelector(eventsFunction, parameter);
    if (parameter.getName() === 'Command') selectedCommands.push(...selector);
    if (parameter.getName() === 'Property') selectedProperties.push(...selector);
    for (const value of selector) {
      if (!isMainSdkPath(value) && !isAppSdkPath(value)) continue;
      assert.ok(
        root === mainSdkGroupRoot || root === appSdkGroupRoot,
        `${value} leaked into tool group ${root}`
      );
      assert.equal(
        root,
        isMainSdkPath(value) ? mainSdkGroupRoot : appSdkGroupRoot,
        `${value} is exposed under the wrong SDK tree`
      );
    }
  }
}

const initializationSource = extension.eventsFunctions
  .find(eventsFunction => eventsFunction.name === 'onFirstSceneLoaded')
  .events.find(event => event.type === 'BuiltinCommonInstructions::JsCode')
  .inlineCode;
const readSurfaceArray = name => {
  let match = initializationSource.match(
    new RegExp(`${name}: Object\\.freeze\\((\\[[^\\]]]*\\])\\)`)
  );
  if (!match) {
    match = initializationSource.match(
      new RegExp(`${name}: Object\\.freeze\\((\\[[^\\r\\n]*\\])\\)`)
    );
  }
  assert.ok(match, `missing PLAYMESH_SDK_SURFACE.${name}`);
  return JSON.parse(match[1]);
};
const declaredCommands = [
  ...readSurfaceArray('execute'),
  ...readSurfaceArray('subscribe'),
  ...readSurfaceArray('handler'),
];
assert.equal(expectedCommands.length, 99);
assert.deepEqual(
  declaredCommands,
  expectedCommands,
  'the 99 stable SDK command paths or their declared order changed'
);
assert.equal(new Set(expectedCommands).size, 99);
assert.equal(selectedCommands.length, 99, 'command selector entries changed');
assert.deepEqual(
  [...new Set(selectedCommands)].sort(),
  [...expectedCommands].sort(),
  'libGD command selectors must expose the exact runtime surface'
);

const expectedProperties = [
  'playmesh.main.version',
  'playmesh.main.authority.defaultNamespace',
  'playmesh.main.binary.authorityPlayerId',
  'PlaymeshBinaryChannel.id',
  'PlaymeshBinaryChannel.mode',
  'playmesh.app.version',
  'PlaymeshCapabilityHandle.id',
  'PlaymeshCapabilityHandle.code',
  'PlaymeshCapabilityHandle.apiVersion',
  'PlaymeshAppMediaSession.id',
  'PlaymeshAppMediaSession.source',
  'PlaymeshAppMediaSession.state',
  'PlaymeshAppMediaSession.stream',
  'PlaymeshLanGame.instanceId',
  'PlaymeshLanGame.gameId',
  'PlaymeshLanGame.name',
  'PlaymeshLanGame.host',
];
assert.equal(expectedProperties.length, 17);
assert.equal(selectedProperties.length, expectedProperties.length);
assert.deepEqual(
  [...new Set(selectedProperties)].sort(),
  [...expectedProperties].sort(),
  'libGD property selectors must expose the exact readable surface'
);
const allSdkSelectors = [...selectedCommands, ...selectedProperties];
assert.equal(allSdkSelectors.length, 116);
assert.equal(new Set(allSdkSelectors).size, 116, 'SDK selector paths must be unique');
assert.equal(allSdkSelectors.filter(isMainSdkPath).length, 51);
assert.equal(allSdkSelectors.filter(isAppSdkPath).length, 65);

serializedExtensions.delete();
project.delete();

process.stdout.write(
  'Playmesh extension passed locked GDevelop 5.6.276 libGD/editor semantics ' +
    `(${extension.eventsFunctions.length} functions, ${asyncFunctionCount} async, ` +
    '116 stable SDK selectors).\n'
);
