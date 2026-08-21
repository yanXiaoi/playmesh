import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(
  new URL(
    '../assets/playmesh-library/public/developer/gdevelop-authority-bootstrap.js',
    import.meta.url,
  ),
  'utf8',
);
const bridgeSource = await readFile(
  new URL(
    '../assets/playmesh-library/public/developer/gdevelop-multiplayer-bridge.js',
    import.meta.url,
  ),
  'utf8',
);

const wait = milliseconds =>
  new Promise(resolve => setTimeout(resolve, milliseconds));

function createRuntime({
  authority,
  multiplayer = true,
  sessionPresent = true,
  joinFailures = 0,
  attachFailures = 0,
  warningEvents = null,
  warningCapability = true,
  gameInfoPresent = true,
  hostStateMismatch = false,
}) {
  const calls = {
    runtimeAttach: 0,
    attach: 0,
    update: 0,
    detach: 0,
    coordinatorDispose: 0,
    create: 0,
    join: 0,
    close: 0,
    service: 0,
    serviceUnregister: 0,
    sessionSubscribe: 0,
    sessionUnsubscribe: 0,
    gameSubscribe: 0,
    gameUnsubscribe: 0,
    warningEmit: 0,
    submit: [],
  };
  const session = {
    id: 'session-fixture',
    state: 'lobby',
    authorityClientId: 'host-1',
    minPlayers: 1,
    maxPlayers: 8,
    players: [
      {
        id: 'host-1',
        nickname: 'Host',
        role: 'authority',
        connected: true,
      },
      {
        id: 'guest-1',
        nickname: 'Guest',
        role: 'player',
        connected: true,
      },
    ],
  };
  let authorityHandler = null;
  let gameMessageHandler = null;
  let attachedChannel = null;
  const channel = {
    id: '00000000-0000-4000-8000-000000000001',
    mode: 'relay',
    async close() {
      calls.close += 1;
    },
  };
  const main = {
    ready: Promise.resolve(),
    gameInfo: {
      getCurrent: () => (gameInfoPresent ? { multiplayer } : null),
    },
    session: {
      isAuthority: () => authority,
      getCurrent: () => (sessionPresent ? session : null),
      onStateChange(callback) {
        calls.sessionSubscribe += 1;
        callback(session);
        return () => {
          calls.sessionUnsubscribe += 1;
        };
      },
    },
    player: {
      getCurrent: () => (authority ? session.players[0] : session.players[1]),
    },
    binary: {
      authorityPlayerId: 'authority',
      async createChannel(options) {
        calls.create += 1;
        assert.equal(options.mode, 'relay');
        return channel;
      },
      async joinChannel(channelId) {
        calls.join += 1;
        assert.equal(channelId, channel.id);
        if (calls.join <= joinFailures) {
          throw new Error('simulated join failure');
        }
        return channel;
      },
    },
    authority: {
      onService(handler, options) {
        calls.service += 1;
        authorityHandler = handler;
        assert.equal(options.namespace, 'playmesh.gdevelop.multiplayer.v1');
        return () => {
          calls.serviceUnregister += 1;
        };
      },
    },
    game: {
      onMessage(handler) {
        calls.gameSubscribe += 1;
        gameMessageHandler = handler;
        return () => {
          calls.gameUnsubscribe += 1;
        };
      },
      async submitAction(action, options) {
        calls.submit.push({ action, options });
      },
    },
  };
  const coordinator = {
    protocol: 'playmesh.gdevelop.multiplayer.v1',
    version: 1,
    attachRuntime(attachedMain) {
      calls.runtimeAttach += 1;
      assert.equal(attachedMain, main);
    },
    attachChannel(attached) {
      calls.attach += 1;
      assert.equal(attached, channel);
      if (calls.attach <= attachFailures) {
        throw new Error('simulated attach failure');
      }
      attachedChannel = attached;
    },
    updateContext(context) {
      calls.update += 1;
      assert.equal(context.isAuthority, authority);
      assert.equal(context.currentSession, session);
      if (hostStateMismatch) {
        throw Object.assign(new Error('simulated host role mismatch'), {
          code: 'PLAYMESH_GDEVELOP_ROLE_MISMATCH',
        });
      }
    },
    applyPlayerNumberSnapshot(snapshot) {
      assert.equal(snapshot.protocol, 'playmesh.gdevelop.multiplayer.v1');
      assert.equal(snapshot.sessionId, session.id);
    },
    detachChannel() {
      calls.detach += 1;
      attachedChannel = null;
    },
    dispose() {
      calls.coordinatorDispose += 1;
    },
  };
  if (warningCapability) {
    coordinator.emitWarning = event => {
      calls.warningEmit += 1;
      if (warningEvents) {
        warningEvents.push(JSON.parse(JSON.stringify(event)));
        return true;
      }
      return false;
    };
  }
  return {
    calls,
    channel,
    main,
    coordinator,
    session,
    getAuthorityHandler: () => authorityHandler,
    getGameMessageHandler: () => gameMessageHandler,
    getAttachedChannel: () => attachedChannel,
  };
}

const COORDINATOR_SYMBOL = Symbol.for(
  'playmesh.gdevelop.multiplayer.coordinator.v1',
);

function startScript({
  gdjsMultiplayer = false,
  constructRuntimeGame = false,
  warningLogs = null,
} = {}) {
  const context = vm.createContext({
    console: {
      error() {},
      warn(...args) {
        warningLogs?.push(args);
      },
    },
    Date,
    Promise,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    addEventListener() {},
  });
  context.__runtimeGameConstructions = 0;
  context.__firstSceneStarts = 0;
  context.gdjs = {
    projectData: { variables: [] },
    RuntimeGame: function RuntimeGame() {
      context.__runtimeGameConstructions += 1;
      this.startGameLoop = () => {
        context.__firstSceneStarts += 1;
      };
    },
  };
  if (gdjsMultiplayer) context.gdjs.multiplayer = {};
  vm.runInContext(source, context, {
    filename: 'gdevelop-authority-bootstrap.js',
  });
  if (constructRuntimeGame) {
    vm.runInContext('new gdjs.RuntimeGame(gdjs.projectData).startGameLoop();', context, {
      filename: 'gdevelop-runtime-construction.js',
    });
  }
  return context;
}

const assertNoRuntimeSideEffects = calls => {
  for (const name of [
    'runtimeAttach',
    'attach',
    'update',
    'detach',
    'coordinatorDispose',
    'create',
    'join',
    'close',
    'service',
    'serviceUnregister',
    'sessionSubscribe',
    'sessionUnsubscribe',
    'gameSubscribe',
    'gameUnsubscribe',
  ]) {
    assert.equal(calls[name], 0, `${name} 在 inactive 模式必须为零`);
  }
  assert.deepEqual(calls.submit, []);
};

function realmValue(context, value) {
  context.__fixtureJson = JSON.stringify(value);
  const result = vm.runInContext('JSON.parse(__fixtureJson)', context);
  delete context.__fixtureJson;
  return result;
}

{
  const runtime = createRuntime({ authority: true });
  const context = startScript();
  await wait(70);
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  const api = context.playmeshGDevelopAuthorityBootstrap;
  await api.install();
  await api.install();
  vm.runInContext(source, context, {
    filename: 'gdevelop-authority-bootstrap-duplicate.js',
  });
  await api.install();
  assert.equal(context.playmeshGDevelopAuthorityBootstrap, api);
  assert.equal(api.installed, true);
  assert.equal(runtime.calls.create, 1, '幂等安装只能创建一个 channel');
  assert.equal(runtime.calls.service, 1, 'Authority 只能注册一个 handler');
  assert.equal(runtime.calls.gameSubscribe, 0, 'Authority 不走 guest discovery');
  assert.equal(runtime.calls.attach, 1);
  const handler = runtime.getAuthorityHandler();
  assert.equal(
    handler(
      realmValue(context, { type: 'other' }),
      realmValue(context, {
        senderPlayerId: 'guest-1',
        session: runtime.session,
      }),
    ),
    null,
  );
  assert.deepEqual(
    JSON.parse(JSON.stringify(handler(
      realmValue(context, {
        type: 'channel.request',
        protocol: api.protocol,
        version: api.version,
        sessionId: 'session-fixture',
      }),
      realmValue(context, {
        senderPlayerId: 'guest-1',
        session: runtime.session,
      }),
    ))),
    [
      {
        targetPlayerIds: ['guest-1'],
        message: {
          type: 'channel.ready',
          protocol: api.protocol,
          version: api.version,
          sessionId: 'session-fixture',
          channelId: runtime.channel.id,
        },
      },
      {
        targetPlayerIds: ['guest-1'],
        message: {
          type: 'playerNumbers.snapshot',
          protocol: api.protocol,
          version: api.version,
          sessionId: 'session-fixture',
          epoch: 1,
          revision: 1,
          assignments: [
            { playerId: 'host-1', playerNumber: 1 },
            { playerId: 'guest-1', playerNumber: 2 },
          ],
          errorCode: null,
        },
      },
    ],
  );

  const requestSnapshot = senderPlayerId => {
    const response = handler(
      realmValue(context, {
        type: 'playerNumbers.request',
        protocol: api.protocol,
        version: api.version,
        sessionId: runtime.session.id,
        knownEpoch: 0,
        knownRevision: 0,
      }),
      realmValue(context, {
        senderPlayerId,
        session: runtime.session,
      }),
    );
    return JSON.parse(JSON.stringify(response.message));
  };

  runtime.session.state = 'running';
  const runningSnapshot = requestSnapshot('guest-1');
  runtime.session.state = 'lobby';
  const returnedLobbySnapshot = requestSnapshot('guest-1');
  assert.equal(runningSnapshot.epoch, 1);
  assert.equal(returnedLobbySnapshot.epoch, 1);
  assert.equal(
    returnedLobbySnapshot.assignments.find(
      assignment => assignment.playerId === 'guest-1',
    ).playerNumber,
    2,
    '同一 session 与 authority 回到 lobby 不能重排玩家编号',
  );

  runtime.session.players[1].connected = false;
  runtime.session.players.push({
    id: 'guest-2',
    nickname: 'Guest 2',
    role: 'player',
    connected: true,
  });
  const afterSoftLeave = requestSnapshot('guest-2');
  assert.deepEqual(afterSoftLeave.assignments.slice(0, 3), [
    { playerId: 'host-1', playerNumber: 1 },
    { playerId: 'guest-1', playerNumber: 2 },
    { playerId: 'guest-2', playerNumber: 3 },
  ]);
  runtime.session.players[1].connected = true;
  const afterReconnect = requestSnapshot('guest-1');
  assert.equal(
    afterReconnect.assignments.find(
      assignment => assignment.playerId === 'guest-1',
    ).playerNumber,
    2,
    '软离开后重连必须复用原编号',
  );

  for (let index = 3; index <= 8; index++) {
    runtime.session.players.push({
      id: `guest-${index}`,
      nickname: `Guest ${index}`,
      role: 'player',
      connected: true,
    });
  }
  const overflowSnapshot = requestSnapshot('guest-2');
  assert.equal(overflowSnapshot.errorCode, 'PLAYER_LIMIT_EXCEEDED');
  assert.equal(
    overflowSnapshot.assignments.find(
      assignment => assignment.playerId === 'guest-7',
    ).playerNumber,
    8,
  );
  assert.equal(
    overflowSnapshot.assignments.some(
      assignment => assignment.playerId === 'guest-8',
    ),
    false,
    '第九名玩家不能复用已经分配过的编号',
  );

  runtime.session.id = 'session-next';
  runtime.session.players = runtime.session.players.slice(0, 2);
  const nextSessionSnapshot = requestSnapshot('guest-1');
  assert.equal(nextSessionSnapshot.epoch, 2);
  assert.deepEqual(nextSessionSnapshot.assignments, [
    { playerId: 'host-1', playerNumber: 1 },
    { playerId: 'guest-1', playerNumber: 2 },
  ]);

  runtime.session.authorityClientId = 'guest-1';
  const nextAuthoritySnapshot = requestSnapshot('host-1');
  assert.equal(nextAuthoritySnapshot.epoch, 3);
  assert.deepEqual(nextAuthoritySnapshot.assignments, [
    { playerId: 'guest-1', playerNumber: 1 },
    { playerId: 'host-1', playerNumber: 2 },
  ]);
  await api.dispose();
  await api.dispose();
  assert.equal(runtime.calls.serviceUnregister, 1);
  assert.equal(runtime.calls.close, 1, 'Authority 只关闭自己创建的 channel');
  assert.equal(runtime.calls.detach, 1);
}

{
  const runtime = createRuntime({ authority: false });
  const context = startScript();
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  const api = context.playmeshGDevelopAuthorityBootstrap;
  await api.install();
  assert.equal(runtime.calls.service, 0, 'guest 不能注册 Authority handler');
  assert.equal(runtime.calls.gameSubscribe, 1);
  assert.equal(runtime.calls.submit.length, 2, 'guest 安装后发现 channel 并请求编号');
  assert.equal(
    runtime.calls.submit[0].options.namespace,
    'playmesh.gdevelop.multiplayer.v1',
  );
  runtime.getGameMessageHandler()(realmValue(context, {
    type: 'channel.ready',
    protocol: api.protocol,
    version: api.version,
    sessionId: 'session-fixture',
    channelId: runtime.channel.id,
  }));
  await wait(0);
  assert.equal(runtime.calls.join, 1);
  assert.equal(runtime.calls.attach, 1);
  await api.dispose();
  assert.equal(runtime.calls.gameUnsubscribe, 1);
  assert.equal(runtime.calls.close, 0, 'guest dispose 不能关闭共享 channel');
}

{
  const runtime = createRuntime({
    authority: false,
    joinFailures: 1,
    attachFailures: 1,
  });
  const context = startScript();
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  const api = context.playmeshGDevelopAuthorityBootstrap;
  await api.install();
  const ready = realmValue(context, {
    type: 'channel.ready',
    protocol: api.protocol,
    version: api.version,
    sessionId: 'session-fixture',
    channelId: runtime.channel.id,
  });

  runtime.getGameMessageHandler()(ready);
  await wait(0);
  assert.equal(runtime.calls.join, 1);
  assert.equal(runtime.calls.attach, 0);
  assert.equal(runtime.getAttachedChannel(), null);

  runtime.getGameMessageHandler()(ready);
  await wait(0);
  assert.equal(runtime.calls.join, 2);
  assert.equal(runtime.calls.attach, 1);
  assert.equal(runtime.calls.detach, 0, 'failed attach never published a channel');
  assert.equal(runtime.getAttachedChannel(), null, 'no half-attached channel remains');

  runtime.getGameMessageHandler()(ready);
  await wait(0);
  assert.equal(runtime.calls.join, 3);
  assert.equal(runtime.calls.attach, 2);
  assert.equal(runtime.getAttachedChannel(), runtime.channel);

  runtime.getGameMessageHandler()(ready);
  await wait(0);
  assert.equal(runtime.calls.join, 3, 'successful attach suppresses duplicate discovery');
  assert.equal(runtime.calls.attach, 2);
  await api.dispose();
}

{
  const warningEvents = [];
  const runtime = createRuntime({
    authority: true,
    multiplayer: false,
    warningEvents,
  });
  const context = startScript({ constructRuntimeGame: true });
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  const api = context.playmeshGDevelopAuthorityBootstrap;
  await api.install();
  await api.install();
  vm.runInContext(source, context, {
    filename: 'gdevelop-authority-bootstrap-inactive-duplicate.js',
  });
  await api.install();
  assert.equal(api.installed, false);
  assert.equal(
    context.__runtimeGameConstructions,
    1,
    'game_not_multiplayer 只禁用多人连接，不能阻止 RuntimeGame 构造',
  );
  assert.equal(
    context.__firstSceneStarts,
    1,
    'game_not_multiplayer 不能阻止 RuntimeGame 启动首场景',
  );
  assertNoRuntimeSideEffects(runtime.calls);
  assert.deepEqual(warningEvents, [
    {
      code: 'MULTIPLAYER_RUNTIME_INACTIVE',
      source: 'gdevelop-bootstrap',
      context: {
        activation: 'game_not_multiplayer',
        sessionPresent: true,
        behaviorDetected: false,
      },
    },
  ]);
  assert.equal(runtime.calls.warningEmit, 1);
  context.gdjs = { multiplayer: {} };
  await api.install();
  await api.install();
  assert.deepEqual(
    warningEvents.map(event => event.context.activation),
    [
      'game_not_multiplayer',
      'multiplayer_behavior_requires_online_game',
    ],
    '同页按 reason 各发一次，重复安装不能重复发同一 reason',
  );
  assert.equal(runtime.calls.warningEmit, 2);
}

{
  const warningEvents = [];
  const runtime = createRuntime({
    authority: true,
    multiplayer: false,
    warningEvents,
  });
  const context = startScript({ gdjsMultiplayer: true });
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  await context.playmeshGDevelopAuthorityBootstrap.install();
  assertNoRuntimeSideEffects(runtime.calls);
  assert.equal(warningEvents.length, 1);
  assert.equal(
    warningEvents[0].context.activation,
    'multiplayer_behavior_requires_online_game',
  );
  assert.equal(warningEvents[0].code, 'MULTIPLAYER_CONFIGURATION_REQUIRED');
  assert.equal(warningEvents[0].context.behaviorDetected, true);
}

{
  const warningEvents = [];
  const runtime = createRuntime({
    authority: true,
    multiplayer: true,
    sessionPresent: false,
    warningEvents,
  });
  const context = startScript();
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  await context.playmeshGDevelopAuthorityBootstrap.install();
  assertNoRuntimeSideEffects(runtime.calls);
  assert.deepEqual(warningEvents.map(event => event.context.activation), [
    'session_unavailable',
  ]);
}

{
  const warningEvents = [];
  const runtime = createRuntime({
    authority: true,
    gameInfoPresent: false,
    warningEvents,
  });
  const context = startScript({ constructRuntimeGame: true });
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  await context.playmeshGDevelopAuthorityBootstrap.install();
  assert.equal(
    context.__runtimeGameConstructions,
    1,
    'game type 配置不可用不能阻止 RuntimeGame 构造',
  );
  assertNoRuntimeSideEffects(runtime.calls);
  assert.equal(
    warningEvents[0].context.activation,
    'game_type_unavailable',
  );
  assert.equal(warningEvents.length, 1);
}

{
  const warningEvents = [];
  const runtime = createRuntime({
    authority: true,
    hostStateMismatch: true,
    warningEvents,
  });
  const context = startScript({ constructRuntimeGame: true });
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  await context.playmeshGDevelopAuthorityBootstrap.install();
  assert.equal(
    context.__runtimeGameConstructions,
    1,
    'host state mismatch 不能阻止 RuntimeGame 构造',
  );
  assert.equal(context.playmeshGDevelopAuthorityBootstrap.installed, false);
  assert.equal(runtime.calls.runtimeAttach, 1);
  assert.equal(runtime.calls.update, 1);
  for (const name of ['attach', 'create', 'join', 'service', 'gameSubscribe']) {
    assert.equal(runtime.calls[name], 0, `${name} 不得连接多人后端`);
  }
  assert.equal(warningEvents.length, 1);
  assert.equal(warningEvents[0].code, 'MULTIPLAYER_HOST_STATE_MISMATCH');
  assert.equal(warningEvents[0].context.activation, 'host_state_mismatch');
}

{
  const warningEvents = [];
  const warningLogs = [];
  const runtime = createRuntime({
    authority: true,
    multiplayer: false,
    warningEvents,
    warningCapability: false,
  });
  const context = startScript({ warningLogs });
  context.playmesh = { main: runtime.main };
  context[COORDINATOR_SYMBOL] = runtime.coordinator;
  const installation = context.playmeshGDevelopAuthorityBootstrap.install();
  await installation;
  assertNoRuntimeSideEffects(runtime.calls);
  assert.deepEqual(
    warningEvents,
    [],
    'warning façade 缺失时必须安全 no-op',
  );
  assert.equal(warningLogs.length, 1, '宿主 warning 通道缺失时必须保留结构化 console');
  assert.equal(
    warningLogs[0][1].context.activation,
    'game_not_multiplayer',
  );
  await context.playmeshGDevelopAuthorityBootstrap.dispose();
}

const symbolNames = [...source.matchAll(/Symbol\.for\(\s*['"]([^'"]+)['"]/g)]
  .map(match => match[1])
  .sort();
assert.deepEqual(symbolNames, [
  'playmesh.gdevelop.multiplayer.coordinator.v1',
]);
assert.doesNotMatch(source, /playmesh\.gdevelop\.warning\.sink/);
assert.doesNotMatch(
  source,
  /Object\.defineProperty\(global,[\s\S]{0,160}warning/i,
);
assert.match(bridgeSource, /host_state_mismatch/);
assert.match(bridgeSource, /game_type_unavailable/);
assert.doesNotMatch(
  bridgeSource,
  /document\.(?:body|documentElement)\.(?:innerHTML|outerHTML|textContent)\s*=/,
  '多人配置诊断不得整页替换游戏文档',
);
assert.doesNotMatch(
  bridgeSource,
  /document\.(?:body|documentElement)\.replaceChildren\(/,
  '多人配置诊断不得清空游戏文档',
);

console.log('GDevelop Authority bootstrap tests passed.');
