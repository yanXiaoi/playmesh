import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const extensionPath = path.resolve(
  testDirectory,
  '..',
  'extensions',
  'Playmesh.json'
);

// Keep this list independent from the extension implementation. It is the
// callable public surface declared by public/sdk/v1/playmesh-main.d.ts. A
// returned SDK object is named by its public interface, because inventing a
// playmesh.* path for a handle would conceal an incomplete mapping.
const executePaths = [
  // Game SDK namespaces.
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

  // Objects returned by the Game SDK.
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

  // App SDK namespaces.
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

  // Objects returned by the App SDK.
  'PlaymeshCapabilityHandle.invoke',
  'PlaymeshCapabilityHandle.removeEventListener',
  'PlaymeshCapabilityHandle.dispose',
  'PlaymeshAppMediaSession.close',
  'PlaymeshLanGame.join',
];

const subscribePaths = [
  // Game SDK subscriptions.
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

  // App SDK subscriptions.
  'playmesh.app.performance.onFps',
  'playmesh.app.performance.onLatency',
  'playmesh.app.device.onInput',
  'playmesh.app.ui.onGameMenuOpen',
  'playmesh.app.ui.onGameMenuClose',
  'PlaymeshCapabilityHandle.on',
  'PlaymeshCapabilityHandle.addEventListener',
  'PlaymeshCapabilityHandle.onError',
];

const handlerPaths = [
  'playmesh.main.authority.onService',
  'playmesh.main.rpc.onRequest',
  'PlaymeshBinaryChannel.onForward',
];

// Localization is presentation-only. These stable internal identifiers and
// property selectors are referenced by existing GDevelop projects and must
// not be translated or renamed.
const expectedPropertyPaths = [
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

const expectedInternalFunctionNames = [
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
];

// The first public release shipped the stable identifiers above. Typed SDK
// wrappers and the descriptor-driven capability facade are additive: keep the
// original identifiers as an ordered subsequence, while locking every added
// identifier independently so additions cannot silently hide a rename.
const expectedAddedInternalFunctionNames = [
  'CallMainRpc',
  'RegisterMainRpcHandler',
  'CallAppStorage',
  'GetCurrentGameInfo',
  'GetIsAuthority',
  'GetCurrentSession',
  'StartSession',
  'FinishSession',
  'GetCurrentPlayer',
  'SetPlayerNickname',
  'SubmitGameAction',
  'RequestAuthorityRpc',
  'CreateBinaryChannel',
  'JoinBinaryChannel',
  'StartAuthoritySync',
  'SubmitSyncAction',
  'SubmitSyncState',
  'RequestSyncSnapshot',
  'GetLatestSyncSnapshot',
  'GetStorageBucket',
  'BroadcastBinary',
  'BroadcastLatestBinary',
  'CloseBinaryChannel',
  'GetAuthoritySyncState',
  'SetAuthoritySyncState',
  'PublishCurrentAuthoritySyncState',
  'StopAuthoritySync',
  'GetBucketData',
  'SetBucketData',
  'GetBucketDataSync',
  'SetBucketDataSync',
  'RemoveBucketData',
  'ClearBucketData',
  'UploadBucketEncodedFile',
  'GetAppAvailability',
  'GetAppIdentity',
  'GetAppLocale',
  'GetAppStorageBucket',
  'GetAppBucketData',
  'SetAppBucketData',
  'GetAppBucketDataSync',
  'SetAppBucketDataSync',
  'RemoveAppBucketData',
  'ClearAppBucketData',
  'GetAppFps',
  'GetAppLatency',
  'GetAppLatencyDiagnostics',
  'SetAppPerformanceVisible',
  'ReportAppFrame',
  'GetCapabilityRegistry',
  'GetAvailableCapabilities',
  'GetDeclaredCapabilities',
  'CreateDynamicCapability',
  'OpenAppMediaSession',
  'GetDevicePlatform',
  'SetDeviceFullscreen',
  'DisableSystemMenuTriggers',
  'InitializeBrowserUi',
  'ConfigureAppUi',
  'ShowGameMenu',
  'RestartGame',
  'OpenSharePanel',
  'OpenRuntimeLogs',
  'EnterUiFullscreen',
  'ExitUiFullscreen',
  'OpenGameInfo',
  'SetUiPerformanceVisible',
  'ToggleUiPerformance',
  'ExitCurrentGame',
  'DiscoverLanGames',
  'JoinGameByInvitationLink',
  'ScanQrAndJoinGame',
  'PublishLanGame',
  'GetLanShareLinks',
  'InvokeDynamicCapability',
  'RemoveDynamicCapabilityEventListener',
  'DisposeDynamicCapability',
  'CloseAppMediaSession',
  'JoinDiscoveredLanGame',
  'BroadcastBinaryBytes',
  'SendBinaryToPlayer',
  'SendBinaryBytesToPlayer',
  'SendBinaryToPlayers',
  'SendBinaryBytesToPlayers',
  'BroadcastLatestBinaryBytes',
  'SendLatestBinaryToPlayer',
  'SendLatestBinaryBytesToPlayer',
  'SendLatestBinaryToPlayers',
  'SendLatestBinaryBytesToPlayers',
  'PublishCurrentAuthoritySyncStateToPlayers',
  'PublishGivenAuthoritySyncState',
  'PublishGivenAuthoritySyncStateToPlayers',
  'UploadBucketByteFile',
  'SubscribeSessionStateChange',
  'HasSubscribeSessionStateChangeEvent',
  'PopSubscribeSessionStateChangeEvent',
  'SubscribePlayerJoin',
  'HasSubscribePlayerJoinEvent',
  'PopSubscribePlayerJoinEvent',
  'SubscribePlayerLeave',
  'HasSubscribePlayerLeaveEvent',
  'PopSubscribePlayerLeaveEvent',
  'SubscribePlayerReconnect',
  'HasSubscribePlayerReconnectEvent',
  'PopSubscribePlayerReconnectEvent',
  'SubscribeGameMessage',
  'HasSubscribeGameMessageEvent',
  'PopSubscribeGameMessageEvent',
  'SubscribeLegacyGameEvent',
  'HasSubscribeLegacyGameEventEvent',
  'PopSubscribeLegacyGameEventEvent',
  'SubscribeSyncSnapshot',
  'HasSubscribeSyncSnapshotEvent',
  'PopSubscribeSyncSnapshotEvent',
  'SubscribeLifecycleChange',
  'HasSubscribeLifecycleChangeEvent',
  'PopSubscribeLifecycleChangeEvent',
  'SubscribeLifecyclePause',
  'HasSubscribeLifecyclePauseEvent',
  'PopSubscribeLifecyclePauseEvent',
  'SubscribeLifecycleResume',
  'HasSubscribeLifecycleResumeEvent',
  'PopSubscribeLifecycleResumeEvent',
  'SubscribeLifecycleExit',
  'HasSubscribeLifecycleExitEvent',
  'PopSubscribeLifecycleExitEvent',
  'SubscribeBinaryMessage',
  'HasSubscribeBinaryMessageEvent',
  'PopSubscribeBinaryMessageEvent',
  'SubscribeAppFps',
  'HasSubscribeAppFpsEvent',
  'PopSubscribeAppFpsEvent',
  'SubscribeAppLatency',
  'HasSubscribeAppLatencyEvent',
  'PopSubscribeAppLatencyEvent',
  'SubscribeDeviceInput',
  'HasSubscribeDeviceInputEvent',
  'PopSubscribeDeviceInputEvent',
  'SubscribeGameMenuOpen',
  'HasSubscribeGameMenuOpenEvent',
  'PopSubscribeGameMenuOpenEvent',
  'SubscribeGameMenuClose',
  'HasSubscribeGameMenuCloseEvent',
  'PopSubscribeGameMenuCloseEvent',
  'SubscribeDynamicCapabilityEvent',
  'HasSubscribeDynamicCapabilityEventEvent',
  'PopSubscribeDynamicCapabilityEventEvent',
  'AddDynamicCapabilityEventListener',
  'HasAddDynamicCapabilityEventListenerEvent',
  'PopAddDynamicCapabilityEventListenerEvent',
  'SubscribeDynamicCapabilityError',
  'HasSubscribeDynamicCapabilityErrorEvent',
  'PopSubscribeDynamicCapabilityErrorEvent',
  'RegisterAuthorityService',
  'HasRegisterAuthorityServiceRequest',
  'PopRegisterAuthorityServiceRequest',
  'RegisterAuthorityRpcHandler',
  'HasRegisterAuthorityRpcHandlerRequest',
  'PopRegisterAuthorityRpcHandlerRequest',
  'RegisterBinaryForwardHandler',
  'HasRegisterBinaryForwardHandlerRequest',
  'PopRegisterBinaryForwardHandlerRequest',
  'ExecuteMainSdkAdvanced',
  'SubscribeMainSdkAdvanced',
  'RegisterMainSdkHandlerAdvanced',
  'ReadMainSdkPropertyAdvanced',
  'ExecuteAppSdkAdvanced',
  'SubscribeAppSdkAdvanced',
  'ReadAppSdkPropertyAdvanced',
  'MainSdkVersion',
  'AuthorityDefaultNamespace',
  'BinaryAuthorityPlayerId',
  'BinaryChannelSdkId',
  'BinaryChannelMode',
  'AppSdkVersion',
  'CapabilitySdkId',
  'CapabilityCode',
  'CapabilityApiVersion',
  'MediaSessionSdkId',
  'MediaSessionState',
  'MediaSessionSourceHandleId',
  'MediaSessionStreamHandleId',
  'LanGameInstanceId',
  'LanGameId',
  'LanGameName',
  'LanGameHost',
  'CopyMediaSessionSource',
  'CopyMediaSessionStreamDescriptor',
  'IsAuthority',
  'IsAppAvailable',
  'HasCurrentGameInfo',
  'CopyCurrentGameInfo',
  'HasCurrentSession',
  'CopyCurrentSession',
  'HasCurrentPlayer',
  'CopyCurrentPlayer',
  'HasLatestSyncSnapshot',
  'CopyLatestSyncSnapshot',
  'HasAppIdentity',
  'CopyAppIdentity',
  'AppLocale',
  'HasAppFps',
  'AppFps',
  'HasAppLatency',
  'AppLatency',
  'HasAppLatencyDiagnostics',
  'CopyAppLatencyDiagnostics',
  'HasDevicePlatform',
  'DevicePlatform',
  'CopyCapabilityRegistry',
  'CopyAvailableCapabilities',
  'CopyDeclaredCapabilities',
  'AppIdentityUserId',
  'AppIdentityNickname',
  'AppIdentitySource',
  'CurrentPlayerId',
  'CurrentPlayerNickname',
  'CurrentPlayerRole',
  'CurrentPlayerConnected',
  'CurrentSessionState',
  'SessionStateEventHasSession',
  'SessionStateEventState',
  'PlayerJoinEventPlayerId',
  'PlayerJoinEventIsCurrentPlayer',
  'PlayerLeaveEventPlayerId',
  'PlayerLeaveEventIsCurrentPlayer',
  'PlayerReconnectEventPlayerId',
  'PlayerReconnectEventIsCurrentPlayer',
  'SyncEventRevision',
  'SyncEventStateType',
  'CopySyncEventState',
  'LifecycleEventState',
  'LifecycleEventError',
  'BinaryEventBase64',
  'BinaryEventSenderPlayerId',
  'BinaryEventDelivery',
  'HasAppFpsEventValue',
  'AppFpsEventValue',
  'HasAppLatencyEventValue',
  'AppLatencyEventValue',
  'RespondAuthorityResult',
  'RespondAuthorityRpc',
  'RejectAuthorityRpc',
  'PassBinaryForwardRequest',
  'ReplaceBinaryForwardRequest',
  'ReplaceBinaryForwardRequestWithBytes',
  'RejectBinaryForwardRequest',
  'KeepAuthoritySyncState',
  'SetNextAuthoritySyncState',
  'CompleteLifecycleExitCleanup',
  'IsCameraCapabilityDeclared',
  'IsCameraCapabilityAvailable',
  'IsMicrophoneCapabilityDeclared',
  'IsMicrophoneCapabilityAvailable',
  'IsMidiCapabilityDeclared',
  'IsMidiCapabilityAvailable',
  'IsVibrationCapabilityDeclared',
  'IsVibrationCapabilityAvailable',
  'IsPose6dCapabilityDeclared',
  'IsPose6dCapabilityAvailable',
  'CreateCameraCapability',
  'CreateMicrophoneCapability',
  'CreateMidiCapability',
  'CreateVibrationCapability',
  'CreatePose6dCapability',
  'DisposeCameraCapability',
  'DisposeMicrophoneCapability',
  'DisposeMidiCapability',
  'DisposeVibrationCapability',
  'DisposePose6dCapability',
  'StartMicrophoneSpeechToText',
  'VibrateDevice',
  'CancelDeviceVibration',
  'RecenterPose6d',
  'OpenPose6dVideoSource',
  'CreatePose6dVideoSourceLegacy',
  'SubscribeMicrophoneSoundLevel',
  'HasSubscribeMicrophoneSoundLevelEvent',
  'PopSubscribeMicrophoneSoundLevelEvent',
  'SubscribeMicrophoneTextResult',
  'HasSubscribeMicrophoneTextResultEvent',
  'PopSubscribeMicrophoneTextResultEvent',
  'SubscribePose6d',
  'HasSubscribePose6dEvent',
  'PopSubscribePose6dEvent',
  'MicrophoneSoundLevel',
  'MicrophoneRecognizedWords',
  'MicrophoneResultIsFinal',
  'MicrophoneResultType',
  'MicrophoneConfidence',
  'MicrophoneHasConfidenceRating',
  'CopyMicrophoneAlternates',
  'Pose6dCaptureTimestampNs',
  'Pose6dTrackingState',
  'Pose6dPositionX',
  'Pose6dPositionY',
  'Pose6dPositionZ',
  'Pose6dRotationX',
  'Pose6dRotationY',
  'Pose6dRotationZ',
  'Pose6dRotationW',
  'CopyPose6dEvent',
];

const expectedCallablePaths = [
  ...executePaths,
  ...subscribePaths,
  ...handlerPaths,
];
const isMainCallablePath = sdkPath =>
  sdkPath.startsWith('playmesh.main.') ||
  sdkPath.startsWith('PlaymeshBinaryChannel.') ||
  sdkPath.startsWith('PlaymeshSyncAuthorityController.') ||
  sdkPath.startsWith('PlaymeshStorageBucket.');
const mainCallablePaths = expectedCallablePaths.filter(isMainCallablePath);
const appCallablePaths = expectedCallablePaths.filter(
  sdkPath => !isMainCallablePath(sdkPath)
);

assert.equal(executePaths.length, 76, 'the execute baseline must stay at 76');
assert.equal(
  subscribePaths.length,
  20,
  'the subscription baseline must stay at 20'
);
assert.equal(handlerPaths.length, 3, 'the handler baseline must stay at 3');
assert.equal(
  new Set(expectedCallablePaths).size,
  99,
  'the public SDK callable baseline must contain 99 unique paths'
);
assert.equal(mainCallablePaths.length, 46);
assert.equal(appCallablePaths.length, 53);

const extensionSource = await readFile(extensionPath, 'utf8');
const extension = JSON.parse(extensionSource);

assert.equal(extension.name, 'Playmesh');
assert.deepEqual(
  extension.dependencies,
  [],
  'the extension must not load or inject a second SDK dependency'
);
assert.ok(
  Array.isArray(extension.eventsFunctions),
  'Playmesh.json must be a canonical GDevelop extension with eventsFunctions'
);
const actualInternalFunctionNames = extension.eventsFunctions.map(
  eventsFunction => eventsFunction.name
);
assert.equal(
  new Set(actualInternalFunctionNames).size,
  actualInternalFunctionNames.length,
  'event-function identifiers must remain unique'
);
let stableNameIndex = 0;
for (const functionName of actualInternalFunctionNames) {
  if (functionName === expectedInternalFunctionNames[stableNameIndex]) {
    stableNameIndex += 1;
  }
}
assert.equal(
  stableNameIndex,
  expectedInternalFunctionNames.length,
  'the original 100 stable event-function identifiers must remain an ordered subsequence'
);
const stableInternalFunctionNameSet = new Set(expectedInternalFunctionNames);
assert.deepEqual(
  actualInternalFunctionNames.filter(
    functionName => !stableInternalFunctionNameSet.has(functionName)
  ),
  expectedAddedInternalFunctionNames,
  'typed facade additions must keep their independently locked identifiers and order'
);
assert.equal(
  actualInternalFunctionNames.length,
  expectedInternalFunctionNames.length +
    expectedAddedInternalFunctionNames.length,
  'the extension must not add unreviewed internal identifiers'
);
const lifecycleFunctions = extension.eventsFunctions.filter(
  eventsFunction => eventsFunction.name === 'onFirstSceneLoaded'
);
assert.equal(lifecycleFunctions.length, 1);
assert.equal(
  lifecycleFunctions[0].private,
  true,
  'onFirstSceneLoaded must be hidden lifecycle initialization'
);
assert.equal(
  lifecycleFunctions[0].fullName,
  '',
  'GDevelop recognizes onFirstSceneLoaded as lifecycle code only with an empty fullName'
);
assert.deepEqual(lifecycleFunctions[0].parameters, []);

const stringLeaves = [];
const inlineCodeSources = [];
const inlineCodeBlocks = [];
const collectNestedStrings = value => {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.flatMap(collectNestedStrings);
  if (!value || typeof value !== 'object') return [];
  return Object.values(value).flatMap(collectNestedStrings);
};
const visit = (value, jsonPath = '$', parent = null) => {
  if (typeof value === 'string') {
    stringLeaves.push({ jsonPath, value });
    const key = jsonPath.slice(jsonPath.lastIndexOf('.') + 1);
    if (
      /^(?:inlineCode|javaScriptCode|sourceCode)$/i.test(key) ||
      value.includes('PLAYMESH_SDK_SURFACE') ||
      (parent?.type?.value || '').includes('JsCode')
    ) {
      inlineCodeSources.push(value);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((entry, index) => visit(entry, `${jsonPath}[${index}]`, value));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, entry] of Object.entries(value)) {
    if (/^(?:inlineCode|javaScriptCode|sourceCode)$/i.test(key)) {
      const codeStrings = collectNestedStrings(entry);
      inlineCodeSources.push(...codeStrings);
      inlineCodeBlocks.push(codeStrings.join('\n'));
    }
    visit(entry, `${jsonPath}.${key}`, value);
  }
};
visit(extension);

assert.equal(
  inlineCodeBlocks.length,
  extension.eventsFunctions.length,
  'every extension function must contain exactly one auditable inline JS block'
);
for (const [index, inlineCode] of inlineCodeBlocks.entries()) {
  assert.doesNotThrow(
    () =>
      new vm.Script(`(function () {\n${inlineCode}\n})`, {
        filename: `Playmesh.json#inlineCode-${index}`,
      }),
    `inline JS block ${index} must be valid JavaScript`
  );
}

const surfaceCodeBlocks = [
  ...new Set(
    inlineCodeBlocks.filter(value => value.includes('PLAYMESH_SDK_SURFACE'))
  ),
];
const surfaceSources =
  surfaceCodeBlocks.length > 0
    ? surfaceCodeBlocks
    : [
        ...new Set(
          stringLeaves
            .filter(({ value }) => value.includes('PLAYMESH_SDK_SURFACE'))
            .map(({ value }) => value)
        ),
      ];
assert.equal(
  surfaceSources.length,
  1,
  'one initialization JS block must own PLAYMESH_SDK_SURFACE'
);
const initializationSource = surfaceSources[0];

const findMatchingParenthesis = (source, openIndex) => {
  assert.equal(source[openIndex], '(');
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = openIndex; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (character === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === '*' && next === '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === '/' && next === '/') {
      lineComment = true;
      index += 1;
      continue;
    }
    if (character === '/' && next === '*') {
      blockComment = true;
      index += 1;
      continue;
    }
    if (character === '"' || character === "'" || character === '`') {
      quote = character;
      continue;
    }
    if (character === '(') depth += 1;
    if (character === ')') {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  throw new Error('PLAYMESH_SDK_SURFACE Object.freeze call is not balanced');
};

const surfaceMarkerIndex = initializationSource.indexOf(
  'const PLAYMESH_SDK_SURFACE'
);
assert.ok(surfaceMarkerIndex >= 0);
const freezeIndex = initializationSource.indexOf(
  'Object.freeze',
  surfaceMarkerIndex
);
assert.ok(freezeIndex >= 0, 'PLAYMESH_SDK_SURFACE must be immutable');
const freezeOpenIndex = initializationSource.indexOf('(', freezeIndex);
const freezeCloseIndex = findMatchingParenthesis(
  initializationSource,
  freezeOpenIndex
);
const surfaceExpression = initializationSource.slice(
  freezeIndex,
  freezeCloseIndex + 1
);
const evaluatedSurface = vm.runInNewContext(surfaceExpression, Object.create(null), {
  filename: 'Playmesh.json#PLAYMESH_SDK_SURFACE',
  timeout: 100,
});
const surface = JSON.parse(JSON.stringify(evaluatedSurface));

assert.ok(surface && typeof surface === 'object');
assert.ok(
  Array.isArray(surface.execute),
  'PLAYMESH_SDK_SURFACE.execute must be a statically auditable array'
);
assert.ok(
  Array.isArray(surface.subscribe),
  'PLAYMESH_SDK_SURFACE.subscribe must be a statically auditable array'
);
assert.ok(
  Array.isArray(surface.handler),
  'PLAYMESH_SDK_SURFACE.handler must be a statically auditable array'
);
assert.equal(
  Object.prototype.hasOwnProperty.call(surface, 'ready'),
  false,
  'ready is automatic initialization state, not a public command table'
);

const collectMappedPaths = section => {
  const values = [];
  const collect = value => {
    if (typeof value === 'string') {
      values.push(value);
      return;
    }
    if (Array.isArray(value)) {
      value.forEach(collect);
      return;
    }
    if (!value || typeof value !== 'object') return;
    Object.values(value).forEach(collect);
  };
  collect(section);
  return new Set(values);
};

const executeMappings = collectMappedPaths(surface.execute);
const subscribeMappings = collectMappedPaths(surface.subscribe);
const handlerMappings = collectMappedPaths(surface.handler);

assert.equal(executeMappings.size, 76, 'execute must map exactly 76 SDK calls');
assert.equal(
  subscribeMappings.size,
  20,
  'subscribe must map exactly 20 SDK subscriptions'
);
assert.equal(handlerMappings.size, 3, 'handler must map exactly 3 SDK handlers');

for (const sdkPath of executePaths) {
  assert.ok(
    executeMappings.has(sdkPath),
    `PLAYMESH_SDK_SURFACE.execute is missing ${sdkPath}`
  );
}
for (const sdkPath of subscribePaths) {
  assert.ok(
    subscribeMappings.has(sdkPath),
    `PLAYMESH_SDK_SURFACE.subscribe is missing ${sdkPath}`
  );
}
for (const sdkPath of handlerPaths) {
  assert.ok(
    handlerMappings.has(sdkPath),
    `PLAYMESH_SDK_SURFACE.handler is missing ${sdkPath}`
  );
}
const allDeclaredCallableMappings = new Set([
  ...executeMappings,
  ...subscribeMappings,
  ...handlerMappings,
]);
for (const readyPath of [
  'playmesh.ready',
  'playmesh.main.ready',
  'playmesh.app.ready',
]) {
  assert.equal(
    allDeclaredCallableMappings.has(readyPath),
    false,
    `${readyPath} must not be exposed as an executable SDK command`
  );
}
assert.equal(
  expectedCallablePaths.filter(path => allDeclaredCallableMappings.has(path))
    .length,
  99,
  'all 99 public callable members must have a declared command mapping'
);

const featureNames = new Set(
  (Array.isArray(surface.features) ? surface.features : []).map(feature =>
    typeof feature === 'string' ? feature : feature?.name
  )
);
for (const feature of [
  'nullable',
  'jsonPath',
  'operation',
  'error',
  'event',
  'request',
  'handle',
  'binary',
  'file',
  'media',
  'dynamicCapability',
]) {
  assert.ok(featureNames.has(feature), `missing extension feature: ${feature}`);
}

// Native capability plugins form an open registry. A finite list of current
// codes is not equivalent to supporting the App SDK.
for (const sdkPath of [
  'playmesh.app.capabilities.create',
  'PlaymeshCapabilityHandle.invoke',
  'PlaymeshCapabilityHandle.on',
  'PlaymeshCapabilityHandle.addEventListener',
  'PlaymeshCapabilityHandle.removeEventListener',
  'PlaymeshCapabilityHandle.onError',
  'PlaymeshCapabilityHandle.dispose',
]) {
  assert.ok(
    allDeclaredCallableMappings.has(sdkPath),
    `dynamic App capability mapping is missing ${sdkPath}`
  );
}

const combinedInlineCode = [...new Set(inlineCodeSources)].join('\n');
assert.match(
  combinedInlineCode,
  /(?:globalThis|window)\s*\.\s*playmesh/,
  'the extension must resolve the SDK from the current JS context'
);

const forbiddenRuntimePatterns = [
  [/<script\b/i, 'script markup injection'],
  [
    /document\s*\.\s*createElement\s*(?:\?\.)?\s*\(\s*['"]script['"]\s*\)/i,
    'script element injection',
  ],
  [/\bfetch\s*(?:\?\.)?\s*\(/, 'fetch'],
  [/\bXMLHttpRequest\b/, 'XMLHttpRequest'],
  [/\bWebSocket\b/, 'WebSocket'],
  [/\bpostMessage\s*(?:\?\.)?\s*\(/, 'postMessage'],
  [/\bplaymeshApp\b/, 'historical playmeshApp global'],
  [/\bSymbol\s*\.\s*for\s*\(/, 'SDK Symbol internal access'],
  [/playmesh\.(?:app|main)\.internal/i, 'SDK internal key'],
  [/__PLAYMESH/i, 'private Playmesh runtime declaration'],
  [/\bPlaymesh(?:App)?Bridge\b/, 'raw Playmesh bridge'],
  [/\bchrome\s*\.\s*webview\b/, 'raw WebView bridge'],
  [/\beval\s*\(/, 'eval'],
  [/\bnew\s+Function\b/, 'dynamic script execution'],
  [/\bimport\s*\(/, 'dynamic script import'],
];
for (const [pattern, label] of forbiddenRuntimePatterns) {
  assert.doesNotMatch(
    combinedInlineCode,
    pattern,
    `Playmesh extension must not use ${label}`
  );
}

// These public facilities must exist in actual GDevelop metadata, not only as
// comments in the private initialization source.
const publicFunctions = extension.eventsFunctions.filter(
  eventsFunction => !eventsFunction.private
);
assert.equal(
  publicFunctions.some(eventsFunction =>
    /wait\s*ready|waitready|等待.*就绪/i.test(
      `${eventsFunction.name || ''} ${eventsFunction.fullName || ''}`
    )
  ),
  false,
  'SDK readiness is automatic; the extension must not expose WaitReady'
);

// Every asynchronous GDevelop action must hand the engine a task that
// fulfills even if the runtime unexpectedly rejects. This prevents an SDK
// failure from aborting the event sheet or leaving it permanently waiting.
const asyncPublicFunctions = publicFunctions.filter(
  eventsFunction => eventsFunction.async === true
);
assert.ok(asyncPublicFunctions.length > 0);
for (const eventsFunction of asyncPublicFunctions) {
  const inlineCode = (eventsFunction.events || [])
    .flatMap(event => collectNestedStrings(event.inlineCode))
    .join('\n');
  const wrapperErrors = [];
  const wrapperContext = {
    getArgument() {
      return '';
    },
    task: null,
  };
  class PromiseTaskForTest {
    constructor(promise) {
      this.promise = promise;
    }
  }
  vm.runInNewContext(
    inlineCode,
    {
      gdjs: {
        PromiseTask: PromiseTaskForTest,
        _playmeshExtension: {
          execute() {
            return Promise.reject(new Error('rejected for wrapper contract'));
          },
          reportWrapperError(error) {
            wrapperErrors.push(error);
          },
        },
      },
      eventsFunctionContext: wrapperContext,
      Promise,
      console,
    },
    { filename: `Playmesh.json#${eventsFunction.name}`, timeout: 100 }
  );
  assert.ok(
    wrapperContext.task instanceof PromiseTaskForTest,
    `${eventsFunction.name} must create a GDevelop PromiseTask`
  );
  await assert.doesNotReject(() => wrapperContext.task.promise);
  assert.equal(
    wrapperErrors.length,
    1,
    `${eventsFunction.name} must report a rejected SDK action non-fatally`
  );
}

// GDevelop uses the exact ` ❯ ` delimiter to render nested semantic groups.
// Main and App commands must be discoverable independently; result/data/tool
// helpers live outside either SDK namespace.
const groupDelimiter = ' ❯ ';
const mainGroupRoot = 'Main SDK（游戏 SDK）';
const appGroupRoot = 'App SDK（原生 SDK）';
const allowedGroupRoots = new Set([
  mainGroupRoot,
  appGroupRoot,
  'Results（结果）',
  'Data（数据）',
  'Resources（资源）',
  'Diagnostics（诊断）',
]);
const expectedGroupPaths = new Set([
  `${mainGroupRoot}${groupDelimiter}游戏信息`,
  `${mainGroupRoot}${groupDelimiter}会话`,
  `${mainGroupRoot}${groupDelimiter}玩家`,
  `${mainGroupRoot}${groupDelimiter}游戏`,
  `${mainGroupRoot}${groupDelimiter}权威端`,
  `${mainGroupRoot}${groupDelimiter}请求响应`,
  `${mainGroupRoot}${groupDelimiter}二进制通信`,
  `${mainGroupRoot}${groupDelimiter}状态同步`,
  `${mainGroupRoot}${groupDelimiter}生命周期`,
  `${mainGroupRoot}${groupDelimiter}存储`,
  `${mainGroupRoot}${groupDelimiter}高级 JSON`,
  `${appGroupRoot}${groupDelimiter}可用性`,
  `${appGroupRoot}${groupDelimiter}身份`,
  `${appGroupRoot}${groupDelimiter}运行环境`,
  `${appGroupRoot}${groupDelimiter}存储`,
  `${appGroupRoot}${groupDelimiter}性能`,
  `${appGroupRoot}${groupDelimiter}能力注册表`,
  `${appGroupRoot}${groupDelimiter}动态能力（高级）`,
  `${appGroupRoot}${groupDelimiter}媒体会话`,
  `${appGroupRoot}${groupDelimiter}设备环境`,
  `${appGroupRoot}${groupDelimiter}界面`,
  `${appGroupRoot}${groupDelimiter}局域网`,
  `${appGroupRoot}${groupDelimiter}高级 JSON`,
  `${appGroupRoot}${groupDelimiter}摄像头`,
  `${appGroupRoot}${groupDelimiter}麦克风与语音转文字`,
  `${appGroupRoot}${groupDelimiter}MIDI（乐器接口）`,
  `${appGroupRoot}${groupDelimiter}震动反馈`,
  `${appGroupRoot}${groupDelimiter}空间位姿`,
  `Results（结果）${groupDelimiter}操作结果`,
  `Results（结果）${groupDelimiter}事件`,
  `Results（结果）${groupDelimiter}回调请求`,
  `Data（数据）${groupDelimiter}JSON 数据`,
  `Data（数据）${groupDelimiter}二进制与文件`,
  `Resources（资源）${groupDelimiter}句柄`,
  `Resources（资源）${groupDelimiter}媒体会话`,
  `Diagnostics（诊断）${groupDelimiter}错误`,
  `Diagnostics（诊断）${groupDelimiter}SDK 状态`,
]);
const visibleChinesePattern = /[\u3400-\u9fff]/;
const publicGroupRoots = new Set();
const publicGroupPaths = new Set();
for (const eventsFunction of publicFunctions) {
  assert.equal(
    typeof eventsFunction.fullName,
    'string',
    `${eventsFunction.name} must declare a visible display name`
  );
  assert.match(
    eventsFunction.fullName,
    visibleChinesePattern,
    `${eventsFunction.name} fullName must contain visible Chinese copy`
  );
  assert.equal(
    typeof eventsFunction.group,
    'string',
    `${eventsFunction.name} must declare a semantic group`
  );
  assert.ok(
    eventsFunction.group.includes(groupDelimiter),
    `${eventsFunction.name} must use the exact nested group delimiter "${groupDelimiter}"`
  );
  const groupParts = eventsFunction.group.split(groupDelimiter);
  assert.equal(
    groupParts.length,
    2,
    `${eventsFunction.name} group must remain a two-level semantic tree`
  );
  for (const [index, part] of groupParts.entries()) {
    assert.ok(part.trim(), `${eventsFunction.name} group part ${index} is empty`);
    assert.match(
      part,
      visibleChinesePattern,
      `${eventsFunction.name} group part ${index} must contain visible Chinese copy`
    );
  }
  const root = groupParts[0];
  assert.ok(
    allowedGroupRoots.has(root),
    `${eventsFunction.name} has an unknown semantic group root: ${root}`
  );
  publicGroupRoots.add(root);
  publicGroupPaths.add(eventsFunction.group);
}
for (const root of allowedGroupRoots) {
  assert.ok(publicGroupRoots.has(root), `missing semantic group root: ${root}`);
}
assert.equal(publicGroupRoots.size, 6, 'the semantic tree must keep six roots');
assert.equal(
  publicGroupPaths.size,
  37,
  'the semantic tree must keep 37 distinct root-to-leaf groups'
);
assert.deepEqual(
  [...publicGroupPaths].sort(),
  [...expectedGroupPaths].sort(),
  'Chinese display localization must keep the complete semantic group tree'
);

const parseSelector = parameter => {
  const value = parameter?.supplementaryInformation;
  if (Array.isArray(value)) return value;
  if (typeof value !== 'string' || !value.trim()) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    return [];
  }
};
const mainPublicCommandSelectors = new Set();
const appPublicCommandSelectors = new Set();
const publicPropertySelectors = new Set();
const isMainPropertyPath = propertyPath =>
  propertyPath.startsWith('playmesh.main.') ||
  propertyPath.startsWith('PlaymeshBinaryChannel.');
for (const eventsFunction of publicFunctions) {
  const root = eventsFunction.group.split(groupDelimiter)[0];
  for (const parameter of eventsFunction.parameters || []) {
    if (parameter.name === 'Property') {
      const propertySelector = parseSelector(parameter);
      const propertyKinds = new Set(
        propertySelector.map(propertyPath =>
          isMainPropertyPath(propertyPath) ? 'main' : 'app'
        )
      );
      assert.equal(
        propertyKinds.size,
        1,
        `${eventsFunction.name} must not mix Main/App property selectors`
      );
      const expectedPropertyRoot = propertyKinds.has('main')
        ? mainGroupRoot
        : appGroupRoot;
      assert.equal(
        root,
        expectedPropertyRoot,
        `${eventsFunction.name} property selector is under the wrong SDK root`
      );
      for (const propertyPath of propertySelector) {
        assert.equal(typeof propertyPath, 'string');
        publicPropertySelectors.add(propertyPath);
      }
      continue;
    }
    if (parameter.name !== 'Command') continue;
    const selector = parseSelector(parameter);
    if (selector.length === 0) continue;
    assert.ok(
      root === mainGroupRoot || root === appGroupRoot,
      `${eventsFunction.name} exposes an SDK command selector outside Main/App`
    );
    const destination =
      root === mainGroupRoot
        ? mainPublicCommandSelectors
        : appPublicCommandSelectors;
    for (const sdkPath of selector) {
      assert.equal(typeof sdkPath, 'string');
      if (root === mainGroupRoot) {
        assert.equal(
          sdkPath.startsWith('playmesh.app.'),
          false,
          `Main SDK selector contains App path: ${sdkPath}`
        );
      } else {
        assert.equal(
          sdkPath.startsWith('playmesh.main.'),
          false,
          `App SDK selector contains Main path: ${sdkPath}`
        );
      }
      destination.add(sdkPath);
    }
  }
}
assert.deepEqual(
  [...mainPublicCommandSelectors].sort(),
  [...mainCallablePaths].sort(),
  'Main SDK command selectors must remain an exact stable set'
);
assert.deepEqual(
  [...appPublicCommandSelectors].sort(),
  [...appCallablePaths].sort(),
  'App SDK command selectors must remain an exact stable set'
);
assert.deepEqual(
  [...publicPropertySelectors].sort(),
  [...expectedPropertyPaths].sort(),
  'SDK property selectors must remain an exact stable set'
);
for (const sdkPath of mainCallablePaths) {
  assert.ok(
    mainPublicCommandSelectors.has(sdkPath),
    `Main SDK public selectors are missing ${sdkPath}`
  );
}
for (const sdkPath of appCallablePaths) {
  assert.ok(
    appPublicCommandSelectors.has(sdkPath),
    `App SDK public selectors are missing ${sdkPath}`
  );
}

assert.ok(
  publicFunctions.some(eventsFunction =>
    ['Condition', 'ExpressionAndCondition'].includes(
      eventsFunction.functionType
    )
  ),
  'judgeable SDK values require public GDevelop conditions'
);
assert.ok(
  publicFunctions.some(eventsFunction =>
    ['Expression', 'StringExpression', 'ExpressionAndCondition'].includes(
      eventsFunction.functionType
    )
  ),
  'SDK values require public GDevelop expressions'
);
const publicFunctionMetadata = JSON.stringify(
  publicFunctions.map(eventsFunction => ({
    name: eventsFunction.name,
    fullName: eventsFunction.fullName,
    description: eventsFunction.description,
    functionType: eventsFunction.functionType,
    parameters: (eventsFunction.parameters || []).map(parameter => ({
      name: parameter.name,
      description: parameter.description,
      type: parameter.type,
    })),
  }))
);
for (const [label, pattern] of [
  ['generic SDK command selection', /command/i],
  [
    'generic JSON arguments',
    /(?:arguments?|args?)\W*json|json\W*(?:arguments?|args?)/i,
  ],
  ['operation state/result', /operation/i],
  ['error code/message', /error/i],
  ['queued SDK event', /event/i],
  ['handler request/response', /request|respond/i],
  ['opaque SDK handle', /handle/i],
  ['nullable value presence', /nullable|isNull|hasValue/i],
  ['JSON path access', /jsonPath|JSON path/i],
]) {
  assert.match(
    publicFunctionMetadata,
    pattern,
    `public GDevelop functions are missing ${label} access`
  );
}

// Execute the private initialization block in a context with no SDK. This is
// stronger than requiring one particular Promise/catch spelling: SDK absence,
// synchronous throws and rejected SDK promises must all become fulfilled
// operation records instead of escaping into the GDevelop event sheet.
const reportedRuntimeErrors = [];
const legacyRuntime = { runtimeVersion: 1, legacy: true };
class GDevelopRpcFile extends Blob {
  constructor(parts, name, options = {}) {
    super(parts, { type: options.type || '' });
    this.name = name;
    this.lastModified = options.lastModified || 0;
  }
}
const runtimeSandbox = {
  gdjs: { _playmeshExtension: legacyRuntime },
  setTimeout,
  clearTimeout,
  Uint8Array,
  ArrayBuffer,
  Blob,
  File: GDevelopRpcFile,
  console: {
    error(value) {
      reportedRuntimeErrors.push(String(value));
    },
  },
};
vm.runInNewContext(initializationSource, runtimeSandbox, {
  filename: 'Playmesh.json#onFirstSceneLoaded',
  timeout: 1_000,
});
const runtime = runtimeSandbox.gdjs._playmeshExtension;
assert.notEqual(
  runtime,
  legacyRuntime,
  'a stale v1 runtime must not suppress installation of the current facade'
);
assert.equal(runtime?.runtimeVersion, 2);
assert.equal(typeof runtime.execute, 'function');
assert.equal(typeof runtime.subscribe, 'function');

let missingSdkResult;
const missingSdkPromise = runtime.execute(
  'playmesh.main.session.start',
  '[]',
  'missing-sdk-operation',
  ''
);
assert.equal(typeof missingSdkPromise?.then, 'function');
await assert.doesNotReject(async () => {
  missingSdkResult = await missingSdkPromise;
});
assert.equal(missingSdkResult.ok, false);
assert.equal(missingSdkResult.status, 'rejected');
assert.equal(missingSdkResult.error?.code, 'sdk_missing');
assert.equal(
  runtime.getOperation('missing-sdk-operation')?.error?.code,
  'sdk_missing'
);
assert.equal(
  runtime.operationValueAt('missing-sdk-operation', '').exists,
  false,
  'a failed operation must not masquerade as a successful null value'
);
assert.ok(
  reportedRuntimeErrors.some(message => message.includes('sdk_missing')),
  'a missing SDK must be reported without stopping the game'
);

let missingSubscription;
assert.doesNotThrow(() => {
  missingSubscription = runtime.subscribe(
    'playmesh.main.session.onStateChange',
    '[]',
    'missing-sdk-subscription',
    ''
  );
});
assert.equal(missingSubscription.ok, false);
assert.equal(missingSubscription.error?.code, 'sdk_missing');

runtimeSandbox.playmesh = {
  main: {
    session: {
      start() {
        const error = new Error('SDK rejected the operation');
        error.code = 'sdk_rejected_for_test';
        return Promise.reject(error);
      },
    },
  },
};
let rejectedSdkResult;
await assert.doesNotReject(async () => {
  rejectedSdkResult = await runtime.execute(
    'playmesh.main.session.start',
    '[]',
    'rejected-sdk-operation',
    ''
  );
});
assert.equal(rejectedSdkResult.ok, false);
assert.equal(rejectedSdkResult.status, 'rejected');
assert.equal(rejectedSdkResult.error?.code, 'sdk_rejected_for_test');

// Readiness is supplied automatically by the host. The generic command path
// must call the current SDK member without exposing or re-awaiting ready for
// every GDevelop action.
let readyReads = 0;
const readyIndependentSdk = {
  main: {
    gameInfo: {
      getCurrent() {
        return { id: 'current-context-game' };
      },
    },
  },
};
Object.defineProperty(readyIndependentSdk, 'ready', {
  get() {
    readyReads += 1;
    return Promise.resolve();
  },
});
runtimeSandbox.playmesh = readyIndependentSdk;
const readyIndependentResult = await runtime.execute(
  'playmesh.main.gameInfo.getCurrent',
  '[]',
  'ready-independent-operation',
  ''
);
assert.equal(readyIndependentResult.ok, true);
assert.equal(readyIndependentResult.value?.id, 'current-context-game');
assert.equal(readyReads, 0, 'execute must not await playmesh.ready per command');

// App SDK presence and native App availability are intentionally different.
runtimeSandbox.playmesh = { app: { isAvailable: () => false } };
const browserAppResult = await runtime.execute(
  'playmesh.app.isAvailable',
  '[]',
  'browser-app-operation',
  ''
);
assert.equal(browserAppResult.ok, true);
assert.equal(browserAppResult.value, false);

// Prove that App native capabilities are an open registry rather than a list
// of today's plugin codes. This deliberately uses a future/unknown code and
// method/event names that do not occur in the extension implementation.
let createdCapability;
let capabilityEventCallback;
let capabilityCleanupCalls = 0;
let openedMediaSource;
let closedMediaSessions = 0;
const issuedMediaSource = {
  type: 'playmesh.app.media-source',
  version: 1,
  id: 'future-media-source',
  kind: 'video',
  protocol: 'future-transport-v9',
  live: true,
  transportMetadata: { codec: 'future-codec', layers: [1, 2, 3] },
  handleId: 'untrusted-source-handle-id',
  handleType: 'UntrustedHandleType',
};
runtimeSandbox.playmesh = {
  app: {
    capabilities: {
      async create(code, options) {
        createdCapability = { code, options };
        return {
          id: 'future-capability-handle',
          code,
          apiVersion: '99.0.0',
          async invoke(method, args) {
            if (method === 'issueFutureMedia') return issuedMediaSource;
            return { method, args, from: code };
          },
          on(eventName, callback) {
            createdCapability.eventName = eventName;
            capabilityEventCallback = callback;
            return () => {
              capabilityCleanupCalls += 1;
            };
          },
        };
      },
    },
    media: {
      async open(source) {
        openedMediaSource = source;
        return {
          id: 'future-media-session',
          source,
          stream: {
            active: true,
            getTracks() {
              return [];
            },
          },
          state: 'open',
          async close() {
            closedMediaSessions += 1;
          },
        };
      },
    },
  },
};
const dynamicCapabilityCode = 'future.contract-test.capability';
const createdCapabilityResult = await runtime.execute(
  'playmesh.app.capabilities.create',
  JSON.stringify([dynamicCapabilityCode, { sensitivity: 7 }]),
  'dynamic-capability-create',
  ''
);
assert.equal(createdCapabilityResult.ok, true);
assert.equal(createdCapability?.code, dynamicCapabilityCode);
assert.deepEqual(
  JSON.parse(JSON.stringify(createdCapability?.options)),
  { sensitivity: 7 }
);
const capabilityHandleId = createdCapabilityResult.value?.handleId;
assert.ok(capabilityHandleId);

const dynamicInvokeResult = await runtime.execute(
  'PlaymeshCapabilityHandle.invoke',
  '["measureFuture",{"sample":3}]',
  'dynamic-capability-invoke',
  capabilityHandleId
);
assert.equal(dynamicInvokeResult.ok, true);
assert.deepEqual(JSON.parse(JSON.stringify(dynamicInvokeResult.value)), {
  method: 'measureFuture',
  args: { sample: 3 },
  from: dynamicCapabilityCode,
});

const mediaSourceResult = await runtime.execute(
  'PlaymeshCapabilityHandle.invoke',
  '["issueFutureMedia"]',
  'dynamic-media-source',
  capabilityHandleId
);
assert.equal(mediaSourceResult.ok, true);
assert.equal(mediaSourceResult.value?.handleType, 'PlaymeshAppMediaSource');
assert.notEqual(
  mediaSourceResult.value?.handleId,
  issuedMediaSource.handleId,
  'capability data must not forge an extension handle ID'
);
assert.deepEqual(
  JSON.parse(JSON.stringify(mediaSourceResult.value?.transportMetadata)),
  { codec: 'future-codec', layers: [1, 2, 3] },
  'future media-source own fields must remain accessible'
);

const mediaSessionResult = await runtime.execute(
  'playmesh.app.media.open',
  JSON.stringify([{ $handle: mediaSourceResult.value.handleId }]),
  'dynamic-media-open',
  ''
);
assert.equal(mediaSessionResult.ok, true);
assert.equal(openedMediaSource, issuedMediaSource);
assert.equal(mediaSessionResult.value?.handleType, 'PlaymeshAppMediaSession');
assert.equal(mediaSessionResult.value?.source?.transportMetadata?.codec, 'future-codec');
assert.equal(mediaSessionResult.value?.stream?.opaque, true);
const mediaCloseResult = await runtime.execute(
  'PlaymeshAppMediaSession.close',
  '[]',
  'dynamic-media-close',
  mediaSessionResult.value.handleId
);
assert.equal(mediaCloseResult.ok, true);
assert.equal(closedMediaSessions, 1);

const dynamicEventSubscription = runtime.subscribe(
  'PlaymeshCapabilityHandle.on',
  '["futureReading"]',
  'dynamic-capability-event',
  capabilityHandleId
);
assert.equal(dynamicEventSubscription.ok, true);
assert.equal(createdCapability?.eventName, 'futureReading');
capabilityEventCallback({ reading: 42 });
assert.equal(runtime.eventCount('dynamic-capability-event'), 1);
assert.equal(
  runtime.eventAt('dynamic-capability-event', '$.value.reading').value,
  42
);
assert.equal(runtime.unsubscribe('dynamic-capability-event'), true);
assert.equal(capabilityCleanupCalls, 1);

runtimeSandbox.playmesh = {
  main: {
    gameInfo: {
      getCurrent: () => undefined,
    },
  },
};
const undefinedResult = await runtime.execute(
  'playmesh.main.gameInfo.getCurrent',
  '[]',
  'undefined-operation',
  ''
);
assert.equal(undefinedResult.ok, true);
assert.equal(undefinedResult.valueType, 'undefined');
assert.equal(
  runtime.operationValueAt('undefined-operation', '').exists,
  false,
  'a void SDK result must remain distinct from null'
);

runtimeSandbox.playmesh.main.gameInfo.getCurrent = () => null;
const nullResult = await runtime.execute(
  'playmesh.main.gameInfo.getCurrent',
  '[]',
  'null-operation',
  ''
);
assert.equal(nullResult.ok, true);
assert.equal(nullResult.valueType, 'null');
assert.deepEqual(
  JSON.parse(JSON.stringify(runtime.operationValueAt('null-operation', ''))),
  { exists: true, value: null }
);

// Callback requests remain visible only while answerable. A response or a
// timeout must remove the queue record as well as the internal Promise.
let authorityCallback;
runtimeSandbox.playmesh = {
  main: {
    authority: {
      onService(callback) {
        authorityCallback = callback;
        return () => {};
      },
    },
  },
};
const registeredHandler = runtime.registerHandler(
  'playmesh.main.authority.onService',
  '{"callbackTimeoutMs":100}',
  'authority-handler',
  ''
);
assert.equal(registeredHandler.ok, true);
const authorityResultPromise = authorityCallback(
  { type: 'move' },
  { senderPlayerId: 'player-1' }
);
assert.equal(runtime.requestCount('authority-handler'), 1);
const authorityRequest = runtime.peekRequest('authority-handler');
assert.ok(authorityRequest?.requestId);
assert.equal(
  runtime.respond(
    authorityRequest.requestId,
    '{"targetPlayerIds":["player-1"],"message":{"accepted":true}}',
    'result'
  ),
  true
);
assert.deepEqual(JSON.parse(JSON.stringify(await authorityResultPromise)), {
  targetPlayerIds: ['player-1'],
  message: { accepted: true },
});
assert.equal(
  runtime.requestCount('authority-handler'),
  0,
  'responded requests must not remain queued'
);

const timedOutResultPromise = authorityCallback(
  { type: 'idle' },
  { senderPlayerId: 'player-1' }
);
assert.equal(runtime.requestCount('authority-handler'), 1);
assert.equal(await timedOutResultPromise, null);
assert.equal(
  runtime.requestCount('authority-handler'),
  0,
  'timed-out requests must not remain queued'
);

let rpcPath;
let rpcCallback;
let rpcCleanupCalls = 0;
runtimeSandbox.playmesh = {
  main: {
    rpc: {
      onRequest(path, callback) {
        rpcPath = path;
        rpcCallback = callback;
        return () => {
          rpcCleanupCalls += 1;
        };
      },
    },
  },
};
const registeredRpcHandler = runtime.registerHandler(
  'playmesh.main.rpc.onRequest',
  '["/files/echo",{"callbackTimeoutMs":1000}]',
  'rpc-handler',
  ''
);
assert.equal(registeredRpcHandler.ok, true);
assert.equal(rpcPath, '/files/echo');
const rpcResultPromise = rpcCallback(
  {
    metadata: { slot: 3 },
    bytes: Uint8Array.from([0, 255, 7]),
    file: new GDevelopRpcFile([Uint8Array.from([1, 2, 3])], 'save.bin', {
      type: 'application/octet-stream',
      lastModified: 123,
    }),
  },
  { senderPlayerId: 'player-2' }
);
for (let attempt = 0; attempt < 20 && runtime.requestCount('rpc-handler') === 0; attempt += 1) {
  await Promise.resolve();
}
const rpcRequest = runtime.peekRequest('rpc-handler');
assert.equal(rpcRequest?.payload?.data?.metadata?.slot, 3);
assert.equal(rpcRequest?.payload?.data?.bytes?.$binary?.data, 'AP8H');
assert.equal(rpcRequest?.payload?.data?.file?.$file?.name, 'save.bin');
assert.equal(rpcRequest?.payload?.data?.file?.$file?.data, 'AQID');
assert.equal(
  runtime.respond(
    rpcRequest.requestId,
    {
      accepted: true,
      bytes: { $binary: { encoding: 'bytes', data: [9, 8, 7] } },
      file: {
        $file: {
          name: 'reply.bin',
          type: 'application/octet-stream',
          encoding: 'base64',
          data: 'BgUE',
        },
      },
    },
    'result'
  ),
  true
);
const rpcResult = await rpcResultPromise;
assert.equal(rpcResult.accepted, true);
assert.deepEqual([...rpcResult.bytes], [9, 8, 7]);
assert.equal(rpcResult.file.name, 'reply.bin');
assert.deepEqual([...new Uint8Array(await rpcResult.file.arrayBuffer())], [6, 5, 4]);
assert.equal(runtime.unregisterHandler('rpc-handler'), true);
assert.equal(rpcCleanupCalls, 1);

// lifecycle.onExit is not an ordinary fire-and-forget event: the SDK awaits
// its callback Promise. Preserve that contract with the same queued-request
// bridge used by handlers while still exposing the exit event for inspection.
let exitCallback;
let exitCleanupCalls = 0;
runtimeSandbox.playmesh = {
  main: {
    lifecycle: {
      onExit(callback) {
        exitCallback = callback;
        return () => {
          exitCleanupCalls += 1;
        };
      },
    },
  },
};
const exitSubscription = runtime.subscribe(
  'playmesh.main.lifecycle.onExit',
  '{"handlerId":"exit-handler","callbackTimeoutMs":100}',
  'exit-subscription',
  ''
);
assert.equal(exitSubscription.ok, true);
const exitPromise = exitCallback({ reason: 'game-over' });
assert.equal(typeof exitPromise?.then, 'function');
assert.equal(runtime.eventCount('exit-subscription'), 1);
assert.equal(runtime.requestCount('exit-handler'), 1);
const exitRequest = runtime.peekRequest('exit-handler');
assert.equal(exitRequest?.kind, 'playmesh.main.lifecycle.onExit');
assert.equal(
  runtime.respond(exitRequest.requestId, '', 'keep'),
  true
);
assert.equal(await exitPromise, undefined);
assert.equal(runtime.requestCount('exit-handler'), 0);
assert.equal(runtime.unsubscribe('exit-subscription'), true);
assert.equal(exitCleanupCalls, 1);

const passiveExitSubscription = runtime.subscribe(
  'playmesh.main.lifecycle.onExit',
  '[]',
  'passive-exit-subscription',
  ''
);
assert.equal(passiveExitSubscription.ok, true);
assert.equal(
  exitCallback({ reason: 'passive-observer' }),
  undefined,
  'an ordinary onExit observer must not make the host wait for a response'
);
assert.equal(runtime.eventCount('passive-exit-subscription'), 1);
assert.equal(runtime.requestCount('passive-exit-subscription'), 0);
assert.equal(runtime.unsubscribe('passive-exit-subscription'), true);
assert.equal(exitCleanupCalls, 2);

process.stdout.write(
  'Playmesh GDevelop extension SDK surface contract passed (99 callable members; ready is automatic).\n'
);
