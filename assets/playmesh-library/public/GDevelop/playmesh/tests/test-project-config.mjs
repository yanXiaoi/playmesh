import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceRoot = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshProjectConfig'
);

const importSource = async source =>
  import(`data:text/javascript;base64,${Buffer.from(source).toString(
    'base64'
  )}`);
const readSource = filename =>
  readFile(path.join(sourceRoot, filename), 'utf8');

const protocolSource = await readSource('PlaymeshProjectConfigProtocol.js');
const protocol = await importSource(protocolSource);
globalThis.__playmeshProjectConfigProtocol = protocol;

let clientSource = await readSource('PlaymeshProjectConfigClient.js');
clientSource = clientSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshProjectConfigProtocol';/,
  `const {
  PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES,
  PlaymeshProjectConfigProtocolError,
  assertPlaymeshProjectConfigReadResponse,
  buildPlaymeshProjectConfigUrl,
  createPlaymeshProjectConfigPutBody,
  parsePlaymeshProjectConfigErrorEnvelope,
  readPlaymeshProjectConfigJson,
} = globalThis.__playmeshProjectConfigProtocol;`
);
const clientModule = await importSource(clientSource);
globalThis.__playmeshProjectConfigClient = clientModule;

let controllerSource = await readSource('PlaymeshProjectConfigController.js');
controllerSource = controllerSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshProjectConfigClient';/,
  `const {
  PlaymeshProjectConfigClientError,
  PlaymeshProjectConfigConflictError,
} = globalThis.__playmeshProjectConfigClient;`
);
controllerSource = controllerSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshProjectConfigProtocol';/,
  `const {
  PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS,
  normalizePlaymeshProjectTags,
} = globalThis.__playmeshProjectConfigProtocol;`
);
const controllerModule = await importSource(controllerSource);
const runtimePlanSource = await readSource('PlaymeshRuntimePlan.js');
const runtimePlan = await importSource(runtimePlanSource);
assert.doesNotMatch(
  runtimePlanSource,
  /PlaymeshRuntimeInjection|injectionFileCount|\binjection\s*:/
);
globalThis.__playmeshRuntimePlanResolverMocks = {
  PlaymeshProjectConfigClient: class {
    async read() {
      throw new Error('A test must inject its config client.');
    }
  },
  PlaymeshProjectConfigClientError:
    clientModule.PlaymeshProjectConfigClientError,
  resolveRuntimePlan: runtimePlan.resolveRuntimePlan,
  detectGDevelopMultiplayerActivation: () => 'unknown',
};
const rawRuntimePlanResolverSource = await readSource(
  'PlaymeshRuntimePlanResolver.js'
);
const injectRuntimePlanResolverMocks = source =>
  source
  .replace(
    /import \{[\s\S]*?\} from ["']\.\/PlaymeshProjectConfigClient["'];/,
    `const {
  PlaymeshProjectConfigClient,
  PlaymeshProjectConfigClientError,
} = globalThis.__playmeshRuntimePlanResolverMocks;`
  )
  .replace(
    /import \{ resolveRuntimePlan \} from ["']\.\/PlaymeshRuntimePlan["'];/,
    'const { resolveRuntimePlan } = globalThis.__playmeshRuntimePlanResolverMocks;'
  )
  .replace(
    /import \{ detectGDevelopMultiplayerActivation \} from ["'][^"']+["'];/,
    'const { detectGDevelopMultiplayerActivation } = globalThis.__playmeshRuntimePlanResolverMocks;'
  );
assert.doesNotMatch(
  injectRuntimePlanResolverMocks(`import {
  PlaymeshProjectConfigClient,
  PlaymeshProjectConfigClientError,
} from "./PlaymeshProjectConfigClient";
import { resolveRuntimePlan } from "./PlaymeshRuntimePlan";
import { detectGDevelopMultiplayerActivation } from "../PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection";`),
  /\bimport\b/,
  'The data-URL test harness must accept double-quoted imports too.'
);
const runtimePlanResolverSource = injectRuntimePlanResolverMocks(
  rawRuntimePlanResolverSource
);
const runtimePlanResolver = await importSource(runtimePlanResolverSource);
const diagnostic = await importSource(
  await readSource('PlaymeshConfigDiagnostic.js')
);

const gameId = 'com.playmesh.game.gconfig001';
const config = (overrides = {}) => {
  const gameType = overrides.gameType || 'single';
  return {
    schemaVersion: 2,
    gameId,
    revision: 1,
    gameType,
    minPlayers: gameType === 'online' ? 2 : 1,
    maxPlayers: gameType === 'online' ? 5 : 1,
    tags: [],
    webRuntimeMultithreading: false,
    updatedAt: '2026-08-05T01:02:03.000Z',
    ...overrides,
  };
};
const envelope = (status, overrides = {}) => ({
  requestId: `req-${status}`,
  status,
  ...(status === 'ready' ? { config: config() } : {}),
  ...overrides,
});
const response = (status, body, headers = {}) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });

// 协议解析必须精确：missing/invalid 不能补出猜测配置，ready 必须匹配请求的项目身份。
assert.deepEqual(
  protocol.assertPlaymeshProjectConfigReadResponse(envelope('ready'), gameId)
    .config,
  config()
);
for (const status of ['missing', 'invalid']) {
  assert.deepEqual(
    protocol.assertPlaymeshProjectConfigReadResponse(envelope(status), gameId),
    { requestId: `req-${status}`, status }
  );
}
for (const invalid of [
  { ...envelope('missing'), config: config() },
  { ...envelope('ready'), unexpected: true },
  envelope('ready', { config: config({ gameId: 'com.example.other' }) }),
  envelope('ready', { config: { ...config(), unexpected: true } }),
  envelope('ready', { config: config({ revision: 0 }) }),
  envelope('ready', { config: config({ gameType: 'multiplayer' }) }),
  envelope('ready', {
    config: config({ webRuntimeMultithreading: 'true' }),
  }),
  envelope('ready', { config: config({ updatedAt: 'not-a-time' }) }),
  envelope('ready', { config: config({ updatedAt: '2026-02-31T01:02:03Z' }) }),
]) {
  assert.throws(
    () => protocol.assertPlaymeshProjectConfigReadResponse(invalid, gameId),
    error => error.code === 'invalid_response'
  );
}
assert.deepEqual(
  protocol.createPlaymeshProjectConfigPutBody({
    gameType: 'online',
    minPlayers: 3,
    maxPlayers: 9,
    tags: ['合作', '动作'],
    webRuntimeMultithreading: true,
    expectedRevision: 7,
  }),
  {
    schemaVersion: 2,
    gameType: 'online',
    minPlayers: 3,
    maxPlayers: 9,
    tags: ['合作', '动作'],
    webRuntimeMultithreading: true,
    expectedRevision: 7,
  }
);
assert.throws(
  () =>
    protocol.createPlaymeshProjectConfigPutBody({
      gameType: 'online',
      minPlayers: 2,
      maxPlayers: 5,
      tags: [],
      webRuntimeMultithreading: false,
      expectedRevision: -1,
    }),
  error => error.code === 'invalid_expected_revision'
);
assert.equal(
  protocol.buildPlaymeshProjectConfigUrl(gameId),
  '/dev/api/gdevelop/projects/com.playmesh.game.gconfig001/config'
);
for (const unsafeId of ['', '../escape', 'https://evil.example/a', 'a/b']) {
  assert.throws(
    () => protocol.buildPlaymeshProjectConfigUrl(unsafeId),
    error => error.code === 'invalid_game_id'
  );
}

const requests = [];
const queuedResponses = [];
const fetchImplementation = async (url, options = {}) => {
  requests.push({ url, options });
  const next = queuedResponses.shift();
  if (!next) throw new Error(`Missing response for ${url}`);
  return next;
};
const client = new clientModule.PlaymeshProjectConfigClient({
  fetchImplementation,
  timeoutMs: 2000,
});

queuedResponses.push(response(200, envelope('ready')));
const readReady = await client.read({ gameId });
assert.equal(readReady.config.gameType, 'single');
assert.equal(
  requests.at(-1).url,
  '/dev/api/gdevelop/projects/com.playmesh.game.gconfig001/config'
);
assert.equal(requests.at(-1).options.method, 'GET');
assert.equal(requests.at(-1).options.credentials, 'same-origin');
assert.equal(requests.at(-1).options.cache, 'no-store');
assert.equal(requests.at(-1).options.redirect, 'error');
assert.deepEqual(requests.at(-1).options.headers, {
  Accept: 'application/json',
});
assert.equal(
  /authorization|bearer|token/i.test(JSON.stringify(requests.at(-1))),
  false
);

queuedResponses.push(
  response(
    200,
    envelope('ready', { config: config({ revision: 2, gameType: 'online' }) })
  )
);
const updated = await client.put({
  gameId,
  gameType: 'online',
  minPlayers: 3,
  maxPlayers: 9,
  tags: ['合作', '动作'],
  webRuntimeMultithreading: true,
  expectedRevision: 1,
});
assert.equal(updated.config.revision, 2);
assert.equal(requests.at(-1).options.method, 'PUT');
assert.deepEqual(JSON.parse(requests.at(-1).options.body), {
  schemaVersion: 2,
  gameType: 'online',
  minPlayers: 3,
  maxPlayers: 9,
  tags: ['合作', '动作'],
  webRuntimeMultithreading: true,
  expectedRevision: 1,
});
assert.deepEqual(requests.at(-1).options.headers, {
  Accept: 'application/json',
  'Content-Type': 'application/json',
});

queuedResponses.push(
  response(200, envelope('ready', {
    config: config({
      revision: 3,
      gameType: 'online',
      updatedAt: '2026-08-08T09:52:04.419854Z',
    }),
  }))
);
assert.equal(
  (await client.read({ gameId })).config.updatedAt,
  '2026-08-08T09:52:04.419854Z',
  'Gateway microsecond timestamps must round-trip in WebView clients'
);

queuedResponses.push(
  response(200, '{broken', { 'X-Request-ID': 'dev-response-parse' })
);
await assert.rejects(
  client.read({ gameId }),
  error =>
    error.code === 'invalid_response' &&
    error.status === 200 &&
    error.requestId === 'dev-response-parse'
);

queuedResponses.push(
  response(409, {
    requestId: 'req-conflict',
    error: {
      code: 'gdevelop_config_revision_conflict',
      message: 'changed elsewhere',
      currentRevision: 3,
    },
  })
);
await assert.rejects(
  client.put({
    gameId,
    gameType: 'single',
    minPlayers: 1,
    maxPlayers: 1,
    tags: [],
    webRuntimeMultithreading: false,
    expectedRevision: 2,
  }),
  error =>
    error instanceof clientModule.PlaymeshProjectConfigConflictError &&
    error.code === 'gdevelop_config_revision_conflict' &&
    error.currentRevision === 3 &&
    error.requestId === 'req-conflict'
);

queuedResponses.push(
  response(409, {
    requestId: 'req-invalid',
    error: {
      code: 'gdevelop_config_invalid',
      message: 'broken sidecar',
    },
  })
);
await assert.rejects(
  client.put({
    gameId,
    gameType: 'online',
    minPlayers: 2,
    maxPlayers: 5,
    tags: [],
    webRuntimeMultithreading: false,
    expectedRevision: 3,
  }),
  error =>
    error instanceof clientModule.PlaymeshProjectConfigClientError &&
    !(error instanceof clientModule.PlaymeshProjectConfigConflictError) &&
    error.code === 'gdevelop_config_invalid'
);

queuedResponses.push(
  response(
    200,
    JSON.stringify({
      ...envelope('missing'),
      padding: 'x'.repeat(protocol.PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES),
    })
  )
);
await assert.rejects(
  client.read({ gameId }),
  error => error.code === 'response_too_large'
);
queuedResponses.push(
  response(200, envelope('missing'), {
    'Content-Length': String(
      protocol.PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES + 1
    ),
  })
);
await assert.rejects(
  client.read({ gameId }),
  error => error.code === 'response_too_large'
);

{
  const abortController = new AbortController();
  const abortClient = new clientModule.PlaymeshProjectConfigClient({
    timeoutMs: 2000,
    fetchImplementation: async (_, options) =>
      new Promise((resolve, reject) => {
        options.signal.addEventListener(
          'abort',
          () => reject(new DOMException('Aborted', 'AbortError')),
          { once: true }
        );
      }),
  });
  const pending = abortClient.read({ gameId, signal: abortController.signal });
  abortController.abort();
  await assert.rejects(pending, error => error.code === 'cancelled');
}

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};
const flushTasks = () => new Promise(resolve => setTimeout(resolve, 0));

// 切换项目会中止旧请求，并通过 epoch 丢弃迟到响应。
{
  const first = deferred();
  const second = deferred();
  const reads = [];
  const fakeClient = {
    read({ gameId: requestedGameId, signal }) {
      reads.push({ requestedGameId, signal });
      return requestedGameId.endsWith('first') ? first.promise : second.promise;
    },
    async put() {
      throw new Error('unexpected PUT');
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  const firstLoad = controller.load('com.example.first');
  const secondLoad = controller.load('com.example.second');
  assert.equal(reads[0].signal.aborted, true);
  second.resolve({ requestId: 'req-second', status: 'missing' });
  await secondLoad;
  first.resolve({
    requestId: 'req-first',
    status: 'ready',
    config: config({ gameId: 'com.example.first', gameType: 'online' }),
  });
  await firstLoad;
  assert.equal(controller.getState().gameId, 'com.example.second');
  assert.equal(controller.getState().status, 'missing');
  assert.equal(controller.getState().draftGameType, 'single');
  assert.equal(controller.getState().isExplicitlySaved, false);
  controller.dispose();
}

// 旧项目缺失配置时可见默认值为 single；即使用户未触碰字段，Apply 也必须显式写 revision=0。
{
  const puts = [];
  const fakeClient = {
    async read() {
      return { requestId: 'req-missing', status: 'missing' };
    },
    async put(input) {
      puts.push(input);
      return {
        requestId: 'req-saved',
        status: 'ready',
        config: config({ revision: 1, gameType: input.gameType }),
      };
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  assert.equal(controller.getState().status, 'missing');
  assert.equal(controller.getState().requiresExplicitSave, true);
  const skipped = await controller.saveAfterOfficialApply({
    officialApplySucceeded: false,
  });
  assert.deepEqual(skipped, { ok: false, reason: 'official_apply_failed' });
  assert.equal(puts.length, 0);
  const saved = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.equal(saved.ok, true);
  assert.equal(saved.kind, 'saved');
  assert.equal(puts[0].expectedRevision, 0);
  assert.equal(puts[0].gameType, 'single');
  assert.equal(puts[0].webRuntimeMultithreading, false);
  assert.equal(controller.getState().status, 'ready');
  assert.equal(controller.getState().isExplicitlySaved, true);
}

// Web Runtime 多线程属于现有 Playmesh 设置；切换后随同一次 Apply 保存。
{
  const puts = [];
  const fakeClient = {
    async read() {
      return { requestId: 'req-runtime', status: 'ready', config: config() };
    },
    async put(input) {
      puts.push(input);
      return {
        requestId: 'req-runtime-saved',
        status: 'ready',
        config: config({
          revision: 2,
          webRuntimeMultithreading: input.webRuntimeMultithreading,
        }),
      };
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  controller.selectWebRuntimeMultithreading(true);
  assert.equal(controller.getState().requiresExplicitSave, true);
  await controller.saveAfterOfficialApply({ officialApplySucceeded: true });
  assert.equal(puts[0].webRuntimeMultithreading, true);
  assert.equal(controller.getState().draftWebRuntimeMultithreading, true);
}

// invalid/unavailable 只禁用 PlayMesh 字段，且绝不能发出 PUT。
for (const status of ['invalid', 'unavailable']) {
  let putCalls = 0;
  const fakeClient = {
    async read() {
      if (status === 'invalid') {
        return { requestId: 'req-invalid', status: 'invalid' };
      }
      throw new clientModule.PlaymeshProjectConfigClientError({
        code: 'config_unavailable',
      });
    },
    async put() {
      putCalls++;
      throw new Error('unexpected PUT');
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  assert.equal(controller.getState().status, status);
  assert.equal(controller.getState().fieldDisabled, true);
  const result = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.deepEqual(result, { ok: false, reason: 'config_not_savable' });
  assert.equal(putCalls, 0);
}

// CAS 冲突必须有类型、刷新最新值、明确可重试，且不能把尝试值伪装成已保存。
{
  let reads = 0;
  let puts = 0;
  const fakeClient = {
    async read() {
      reads++;
      return {
        requestId: `req-read-${reads}`,
        status: 'ready',
        config: config({ revision: reads === 1 ? 4 : 5, gameType: 'single' }),
      };
    },
    async put(input) {
      puts++;
      if (puts === 1) {
        throw new clientModule.PlaymeshProjectConfigConflictError({
          currentRevision: 5,
          requestId: 'req-cas',
        });
      }
      return {
        requestId: 'req-retry',
        status: 'ready',
        config: config({
          revision: 6,
          gameType: input.gameType,
          minPlayers: input.minPlayers,
          maxPlayers: input.maxPlayers,
          tags: input.tags,
        }),
      };
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  controller.selectGameType('online');
  const conflicted = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.deepEqual(conflicted, {
    ok: false,
    reason: 'conflict',
    currentRevision: 5,
  });
  const conflictState = controller.getState();
  assert.equal(conflictState.status, 'conflict');
  assert.equal(conflictState.currentRevision, 5);
  assert.equal(conflictState.savedGameType, 'single');
  assert.equal(conflictState.draftGameType, 'online');
  assert.equal(conflictState.fieldDisabled, false);
  assert.equal(conflictState.requiresExplicitSave, true);
  const retried = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.equal(retried.ok, true);
  assert.equal(puts, 2);
  assert.equal(controller.getState().status, 'ready');
  assert.equal(controller.getState().savedGameType, 'online');
}

// PUT 已提交但 WebView 响应流失败时，GET 对账必须识别 durable commit，
// 不得弹出“未保存”或永久禁用字段。
{
  let reads = 0;
  const fakeClient = {
    async read() {
      reads++;
      return {
        requestId: `req-reconcile-${reads}`,
        status: 'ready',
        config: config({
          revision: reads === 1 ? 1 : 2,
          gameType: reads === 1 ? 'single' : 'online',
        }),
      };
    },
    async put() {
      throw new clientModule.PlaymeshProjectConfigClientError({
        code: 'invalid_response',
        status: 200,
        requestId: 'dev-ambiguous-put',
      });
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  controller.selectGameType('online');
  const reconciled = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.equal(reconciled.ok, true);
  assert.equal(reconciled.kind, 'saved');
  assert.equal(controller.getState().status, 'ready');
  assert.equal(controller.getState().savedGameType, 'online');
  assert.equal(controller.getState().fieldDisabled, false);
}

// 确认未提交的 PUT 失败保留 draft/baseline 与结构化诊断，可直接重试。
{
  let reads = 0;
  const fakeClient = {
    async read() {
      reads++;
      return {
        requestId: `req-failed-${reads}`,
        status: 'ready',
        config: config({ revision: 4, gameType: 'single' }),
      };
    },
    async put() {
      throw new clientModule.PlaymeshProjectConfigClientError({
        code: 'config_unavailable',
        status: 503,
        requestId: 'dev-failed-put',
      });
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load(gameId);
  controller.selectGameType('online');
  const failed = await controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  assert.deepEqual(failed, {
    ok: false,
    reason: 'save_failed',
    code: 'config_unavailable',
    status: 503,
    requestId: 'dev-failed-put',
  });
  const failedState = controller.getState();
  assert.equal(failedState.status, 'save_failed');
  assert.equal(failedState.fieldDisabled, false);
  assert.equal(failedState.requiresExplicitSave, true);
  assert.equal(failedState.draftGameType, 'online');
  assert.equal(failedState.savedGameType, 'single');
  assert.equal(failedState.errorStatus, 503);
  assert.equal(failedState.errorRequestId, 'dev-failed-put');
}

// 保存期间切换项目时，必须同时丢弃 PUT 结果与过期冲突刷新。
{
  const save = deferred();
  const fakeClient = {
    async read({ gameId: requestedGameId }) {
      return requestedGameId.endsWith('new')
        ? { requestId: 'req-new', status: 'missing' }
        : {
            requestId: 'req-old',
            status: 'ready',
            config: config({ gameId: requestedGameId }),
          };
    },
    put() {
      return save.promise;
    },
  };
  const controller = new controllerModule.PlaymeshProjectConfigController({
    client: fakeClient,
  });
  await controller.load('com.example.old');
  controller.selectGameType('online');
  const saving = controller.saveAfterOfficialApply({
    officialApplySucceeded: true,
  });
  await flushTasks();
  await controller.load('com.example.new');
  save.resolve({
    requestId: 'req-late',
    status: 'ready',
    config: config({ gameId: 'com.example.old', gameType: 'online' }),
  });
  await saving;
  assert.equal(controller.getState().gameId, 'com.example.new');
  assert.equal(controller.getState().status, 'missing');
}

const expectedPlans = [
  // 显式 online 在 PlayMesh 预览和发布中始终优先于扫描结果。
  ['online', 'enabled', 'preview', 'full', 'active', 'game', 'multiplayer', false, null],
  ['online', 'disabled', 'preview', 'full', 'active', 'game', 'multiplayer', false, null],
  ['online', 'unknown', 'publish', 'full', 'active', 'game', 'multiplayer', false, null],
  // 显式 single 与多人扫描冲突时，预览仍按本地单机运行，发布则在导出前阻断。
  ['single', 'enabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['single', 'enabled', 'publish', 'full', 'inactive', 'game', 'solo', true, null],
  ['single', 'disabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['single', 'disabled', 'publish', 'full', 'inactive', 'game', 'solo', false, null],
  [
    'single',
    'unknown',
    'preview',
    'full',
    'inactive',
    'game',
    'solo',
    false,
    'multiplayer_scan_unknown',
  ],
  // 缺失配置仅在可靠确认未使用多人能力时按旧单机项目兼容。
  ['missing', 'disabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['missing', 'enabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['missing', 'enabled', 'publish', 'full', 'inactive', 'game', 'solo', true, null],
  ['missing', 'unknown', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  // 损坏或不可达配置不能采用扫描结果。
  ['invalid', 'disabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['invalid', 'enabled', 'publish', 'full', 'inactive', 'game', 'solo', true, null],
  ['unavailable', 'enabled', 'preview', 'full', 'inactive', 'game', 'solo', false, null],
  ['unavailable', 'disabled', 'publish', 'full', 'inactive', 'game', 'solo', true, null],
];
for (const [
  configStatus,
  scanActivation,
  target,
  bundlePresence,
  runtimeActivation,
  presentation,
  manifestMode,
  blockBeforeExport,
  warning,
] of expectedPlans) {
  const plan = runtimePlan.resolveRuntimePlan(
    configStatus,
    scanActivation,
    target
  );
  assert.equal(
    plan.bundlePresence,
    bundlePresence,
    `${configStatus}/${scanActivation}/${target}`
  );
  assert.equal(plan.runtimeActivation, runtimeActivation);
  assert.equal(plan.presentation, presentation);
  assert.equal(plan.manifestMode, manifestMode);
  assert.equal(plan.blockBeforeExport, blockBeforeExport);
  assert.equal(plan.warning, warning);
  assert.equal(plan.connectCore, runtimeActivation === 'active');
}
for (const configStatus of [
  'online',
  'single',
  'missing',
  'invalid',
  'unavailable',
]) {
  for (const scanActivation of ['enabled', 'disabled', 'unknown']) {
    const plan = runtimePlan.resolveRuntimePlan(
      configStatus,
      scanActivation,
      'generic'
    );
    assert.equal(plan.bundlePresence, 'none');
    assert.equal(plan.runtimeActivation, 'inactive');
    assert.equal(plan.presentation, 'game');
    assert.equal(plan.connectCore, false);
    assert.equal(plan.blockBeforeExport, false);
    assert.equal(plan.manifestMode, 'official');
  }
}
assert.throws(
  () => runtimePlan.resolveRuntimePlan('online', 'maybe', 'preview'),
  /未知的 GDevelop 多人扫描状态/
);

{
  const resolved = await runtimePlanResolver.resolvePlaymeshProjectRuntimePlan({
    gameId,
    project: {},
    target: 'publish',
    client: {
      async read() {
        return envelope('ready', {
          config: config({ gameType: 'online' }),
        });
      },
    },
    detectActivation: () => 'disabled',
  });
  assert.equal(resolved.configStatus, 'online');
  assert.equal(resolved.scanActivation, 'disabled');
  assert.equal(resolved.plan.bundlePresence, 'full');
  assert.equal(resolved.plan.runtimeActivation, 'active');
  assert.equal(resolved.plan.manifestMode, 'multiplayer');
  assert.equal(resolved.config.minPlayers, 2);
  assert.equal(resolved.config.maxPlayers, 5);
}

{
  const resolved = await runtimePlanResolver.resolvePlaymeshProjectRuntimePlan({
    gameId,
    project: {},
    target: 'preview',
    client: {
      async read() {
        throw new Error('gateway offline');
      },
    },
    detectActivation: () => {
      throw new Error('scan failed');
    },
  });
  assert.equal(resolved.configStatus, 'unavailable');
  assert.equal(resolved.scanActivation, 'unknown');
  assert.equal(resolved.plan.bundlePresence, 'full');
  assert.equal(resolved.plan.runtimeActivation, 'inactive');
  assert.equal(resolved.plan.presentation, 'game');
  assert.equal(resolved.plan.connectCore, false);
  assert.equal(resolved.plan.blockBeforeExport, false);
  assert.equal(resolved.config, null);
}

{
  const abortController = new AbortController();
  abortController.abort();
  await assert.rejects(
    runtimePlanResolver.resolvePlaymeshProjectRuntimePlan({
      gameId,
      project: {},
      target: 'preview',
      signal: abortController.signal,
      client: {
        async read() {
          throw new clientModule.PlaymeshProjectConfigClientError({
            code: 'cancelled',
          });
        },
      },
      detectActivation: () => 'disabled',
    }),
    error => error.name === 'AbortError'
  );
}

const diagnosticFile = diagnostic.createPlaymeshConfigDiagnosticFile({
  entryPath: 'index.html',
  locale: 'zh-CN',
  message: '请前往“游戏属性→PlayMesh 配置→联机”后重试。',
});
assert.equal(diagnosticFile.filePath, 'index.html');
assert.equal(diagnosticFile.files.length, 1);
assert.equal(diagnosticFile.files[0].filePath, 'index.html');
assert.match(diagnosticFile.text, /游戏属性→PlayMesh 配置→联机/);
assert.doesNotMatch(
  diagnosticFile.text,
  /playmesh-main|playmesh-app|\/playmesh\/sdk|bridge|bootstrap|authority|websocket|wss?:\/\/|127\.0\.0\.1|localhost|bearer|token/i
);
assert.equal((diagnosticFile.text.match(/<html\b/gi) || []).length, 1);
assert.equal((diagnosticFile.text.match(/<script\b/gi) || []).length, 0);
const escapedDiagnostic = diagnostic.createPlaymeshConfigDiagnosticFile({
  entryPath: 'nested/main.html',
  locale: 'en-US" onload="bad',
  message: '<img src=x onerror=alert(1)>',
});
assert.doesNotMatch(escapedDiagnostic.text, /<img|onload="/i);
assert.match(escapedDiagnostic.text, /&lt;img/);
assert.throws(
  () =>
    diagnostic.createPlaymeshConfigDiagnosticFile({
      entryPath: '../second.html',
      locale: 'en-US',
      message: 'Configure online mode.',
    }),
  /诊断入口路径无效/
);
// React 区块保持官方原生外观，仅暴露官方 Apply 后接口；运行行为由上方控制器测试覆盖。
const sectionSource = await readSource('PlaymeshProjectConfigSection.js');
assert.match(sectionSource, /React\.forwardRef/);
assert.match(sectionSource, /saveAfterOfficialApply/);
assert.match(sectionSource, /officialApplySucceeded/);
assert.match(sectionSource, /visible = true/);
assert.match(sectionSource, /if \(!visible\) return null/);
assert.match(sectionSource, /controller\.getState\(\)\.gameId !== gameId/);
assert.match(sectionSource, /<Text size="block-title">/);
assert.match(sectionSource, /playmeshProjectConfigMessages\.scope/);
assert.match(sectionSource, /<SelectField/);
assert.match(sectionSource, /<SemiControlledTextField/);
assert.match(sectionSource, /draftMinPlayers/);
assert.match(sectionSource, /draftMaxPlayers/);
assert.match(sectionSource, /draftTags/);
assert.match(sectionSource, /selectMinPlayers/);
assert.match(sectionSource, /selectMaxPlayers/);
assert.match(sectionSource, /selectTags/);
assert.match(sectionSource, /native=\{false\}/);
assert.equal((sectionSource.match(/<SelectOption/g) || []).length, 2);
assert.match(sectionSource, /value="single"/);
assert.match(sectionSource, /value="online"/);
assert.equal(
  (controllerSource.match(/this\._client\.put\(\{/g) || []).length,
  1,
  'game type, player limits and tags must share one project-config PUT'
);
assert.doesNotMatch(sectionSource, /value="multiplayer"/);
assert.doesNotMatch(sectionSource, /\.module\.css|styled\(|makeStyles|@mui/);
assert.match(sectionSource, /fieldDisabled/);
assert.match(sectionSource, /state\.gameId === gameId/);
assert.match(sectionSource, /requiresExplicitSave/);
assert.match(sectionSource, /playmeshProjectConfigMessages\.missingNotSaved/);
assert.match(sectionSource, /playmeshProjectConfigMessages\.conflict/);
assert.match(sectionSource, /playmeshProjectConfigMessages\.retry/);
assert.match(
  sectionSource,
  /playmeshProjectConfigMessages\.webRuntimeMultithreading/
);
assert.match(sectionSource, /selectWebRuntimeMultithreading/);
assert.match(sectionSource, /errorRequestId/);
assert.match(sectionSource, /usePlaymeshLocalization/);

const messagesSource = await readSource('PlaymeshProjectConfigMessages.js');
for (const key of [
  'projectConfigTitle',
  'projectConfigScope',
  'projectConfigGameType',
  'projectConfigSingle',
  'projectConfigOnline',
  'projectConfigMinPlayers',
  'projectConfigMaxPlayers',
  'projectConfigTags',
  'projectConfigTagsHint',
  'projectConfigLoading',
  'projectConfigSaving',
  'projectConfigMissingNotSaved',
  'projectConfigInvalid',
  'projectConfigUnavailable',
  'projectConfigRetry',
  'projectConfigConflict',
  'projectConfigSaveFailed',
]) {
  assert.match(messagesSource, new RegExp(`playmeshMessages\\.${key}\\b`));
}
assert.doesNotMatch(messagesSource, /defaultMessage|PlayMesh 配置|正在读取/);

const allSources = await Promise.all(
  [
    'PlaymeshProjectConfigProtocol.js',
    'PlaymeshProjectConfigClient.js',
    'PlaymeshProjectConfigController.js',
    'PlaymeshProjectConfigMessages.js',
    'PlaymeshProjectConfigSection.js',
    'PlaymeshRuntimePlan.js',
    'PlaymeshRuntimePlanResolver.js',
    'PlaymeshConfigDiagnostic.js',
    'index.js',
  ].map(readSource)
);
for (const source of allSources) {
  assert.doesNotMatch(
    source,
    /\bany\b|\$FlowFixMe|flowlint|\$FlowExpectedError/
  );
}

const sourcePolicy = await readFile(
  path.resolve(testDirectory, '../scripts/apply-source-policy.mjs'),
  'utf8'
);
assert.equal(
  (sourcePolicy.match(/<PlaymeshProjectConfigSection\b/g) || []).length,
  1,
  'Project Properties must mount exactly one Playmesh project-config panel'
);
assert.equal(
  (sourcePolicy.match(/\.saveAfterOfficialApply\(\{/g) || []).length,
  1,
  'official Apply must trigger exactly one shared Playmesh config save'
);
assert.match(sourcePolicy, /relativePath: 'newIDE\/app\/src\/UI\/SelectField\.js'/);
assert.match(sourcePolicy, /native: props\.native !== false/);
assert.match(sourcePolicy, /getContentAnchorEl: null/);
assert.match(sourcePolicy, /disablePortal: false/);
assert.doesNotMatch(
  sourcePolicy,
  /setCurrentTab\('playmesh'\);\s*Window\.showMessageBox/
);
assert.match(
  sourcePolicy,
  /applyPropertiesToProject\(project, props\.i18n, initialProperties\);\s*return;/
);

process.stdout.write(
  'GDevelop PlayMesh project config frontend tests passed.\n'
);
