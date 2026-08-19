import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const sourcePolicy = await readFile(
  path.join(playmeshDirectory, 'scripts', 'apply-source-policy.mjs'),
  'utf8'
);
const outputManifest = JSON.parse(
  await readFile(
    path.join(playmeshDirectory, 'source-policy-output-manifest.json'),
    'utf8'
  )
);

const storagePath = 'GDJS/Runtime/events-tools/storagetools.ts';
const upstreamGitBlobSha = 'd61394d79c78e787f488ae63e4185ffff5c9dee3';
const rootKey = '$playmesh.gdevelop.root.v1';

assert.equal(sourcePolicy.split(`relativePath: '${storagePath}'`).length - 1, 1);
assert.equal(
  sourcePolicy.split(`expectedGitBlobSha: '${upstreamGitBlobSha}'`).length - 1,
  1
);
const extractReplacement = description => {
  const descriptionIndex = sourcePolicy.indexOf(`'${description}'`);
  assert.ok(descriptionIndex >= 0, `missing replacement: ${description}`);
  const end = sourcePolicy.lastIndexOf('`', descriptionIndex);
  const start = sourcePolicy.lastIndexOf('`', end - 1);
  assert.ok(start >= 0 && end > start, `invalid replacement: ${description}`);
  return sourcePolicy.slice(start + 1, end);
};

const resolverReplacement = extractReplacement(
  'add a lazy fail-closed Playmesh synchronous Bucket capability resolver'
);
const resolverMatch = resolverReplacement.match(
  /const playmeshGDevelopRootKey = [\s\S]*?return bucket;\n      };/
);
assert.ok(resolverMatch, 'storage resolver source is missing');
const executableResolver = resolverMatch[0]
  .replace(': string | null', '')
  .replace('(name: string): any | null', '(name)')
  .replaceAll('(window as any)', 'window');
const makeResolver = browserWindow =>
  new Function(
    'window',
    `${executableResolver}\nreturn { playmeshGDevelopRootKey, getPlaymeshStorageBucket };`
  )(browserWindow);

const loadReplacement = extractReplacement(
  'read the exact GDevelop root through the Playmesh sync Bucket when present'
).replace('let serializedString: string | null', 'let serializedString');
const unloadReplacement = extractReplacement(
  'write the exact GDevelop root through the Playmesh sync Bucket when present'
);
const storageReplacementSource = [
  resolverReplacement,
  loadReplacement,
  unloadReplacement,
].join('\n');
assert.equal(storageReplacementSource.includes('Symbol.for('), false);
assert.equal(storageReplacementSource.includes('playmesh.runtime.backends'), false);
const runLoad = ({
  name,
  localStorage,
  logger,
  getPlaymeshStorageBucket,
  playmeshGDevelopRootKey,
}) =>
  new Function(
    'name',
    'localStorage',
    'logger',
    'getPlaymeshStorageBucket',
    'playmeshGDevelopRootKey',
    `${loadReplacement}\nreturn serializedString;`
  )(
    name,
    localStorage,
    logger,
    getPlaymeshStorageBucket,
    playmeshGDevelopRootKey
  );
const runUnload = ({
  name,
  jsObject,
  serializedString,
  localStorage,
  logger,
  getPlaymeshStorageBucket,
  playmeshGDevelopRootKey,
}) =>
  new Function(
    'name',
    'jsObject',
    'serializedString',
    'localStorage',
    'logger',
    'getPlaymeshStorageBucket',
    'playmeshGDevelopRootKey',
    unloadReplacement
  )(
    name,
    jsObject,
    serializedString,
    localStorage,
    logger,
    getPlaymeshStorageBucket,
    playmeshGDevelopRootKey
  );

const logger = { error() {} };

// Generic official exports have no `window.playmesh` and retain the official
// localStorage key and serialized-string semantics byte for byte.
{
  const calls = [];
  const localStorage = {
    getItem(key) {
      calls.push(['getItem', key]);
      return '{"score":7}';
    },
    setItem(key, value) {
      calls.push(['setItem', key, value]);
    },
  };
  const runtime = makeResolver({});
  assert.equal(runtime.playmeshGDevelopRootKey, rootKey);
  assert.equal(runtime.getPlaymeshStorageBucket('存档/一'), null);
  assert.equal(
    runLoad({
      name: '存档/一',
      localStorage,
      logger,
      ...runtime,
    }),
    '{"score":7}'
  );
  runUnload({
    name: '存档/一',
    jsObject: { score: 8 },
    serializedString: '{"score":8}',
    localStorage,
    logger,
    ...runtime,
  });
  assert.deepEqual(calls, [
    ['getItem', 'GDJS_存档/一'],
    ['setItem', 'GDJS_存档/一', '{"score":8}'],
  ]);
}

// A complete Playmesh SDK scopes the GDevelop file under the current username,
// reads the reserved root, and writes the root object rather than a string.
{
  const calls = [];
  const bucket = {
    getDataSync(key) {
      calls.push(['getDataSync', key]);
      return { score: 9 };
    },
    setDataSync(key, value) {
      calls.push(['setDataSync', key, value]);
    },
  };
  const runtime = makeResolver({
    playmesh: {
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: true }) },
        player: {
          getCurrent() {
            return { nickname: '玩家/一号' };
          },
        },
        session: { isAuthority: () => false },
        storage: {
          getBucket(name) {
            calls.push(['getBucket', name]);
            return bucket;
          },
        },
      },
    },
  });
  let localStorageCalls = 0;
  const localStorage = {
    getItem() {
      localStorageCalls += 1;
      return null;
    },
    setItem() {
      localStorageCalls += 1;
    },
  };
  assert.equal(
    runLoad({
      name: '原始/玩家存档',
      localStorage,
      logger,
      ...runtime,
    }),
    '{"score":9}'
  );
  runUnload({
    name: '原始/玩家存档',
    jsObject: { score: 10 },
    serializedString: '{"score":10}',
    localStorage,
    logger,
    ...runtime,
  });
  assert.equal(localStorageCalls, 0);
  assert.deepEqual(calls, [
    ['getBucket', 'GDJS/users/%E7%8E%A9%E5%AE%B6%2F%E4%B8%80%E5%8F%B7/原始/玩家存档'],
    ['getDataSync', rootKey],
    ['getBucket', 'GDJS/users/%E7%8E%A9%E5%AE%B6%2F%E4%B8%80%E5%8F%B7/原始/玩家存档'],
    ['setDataSync', rootKey, { score: 10 }],
  ]);
}

// A public Authority page always uses the fixed auth directory, even when its
// App bridge also exposes the host account identity.
{
  const calls = [];
  const bucket = {
    getDataSync() {
      return null;
    },
    setDataSync() {},
  };
  const runtime = makeResolver({
    playmesh: {
      app: {
        identity: {
          getCurrent() {
            return { nickname: '主持人' };
          },
        },
      },
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: true }) },
        player: { getCurrent: () => null },
        session: { isAuthority: () => true },
        storage: {
          getBucket(name) {
            calls.push(name);
            return bucket;
          },
        },
      },
    },
  });
  assert.equal(runtime.getPlaymeshStorageBucket('save'), bucket);
  assert.deepEqual(calls, ['GDJS/auth/save']);
}

// An Authority page that also represents a participating player is personal,
// not the public screen, and therefore keeps the player's username scope.
{
  const calls = [];
  const bucket = { getDataSync() {}, setDataSync() {} };
  const runtime = makeResolver({
    playmesh: {
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: true }) },
        player: { getCurrent: () => ({ nickname: '房主玩家' }) },
        session: { isAuthority: () => true },
        storage: {
          getBucket(name) {
            calls.push(name);
            return bucket;
          },
        },
      },
    },
  });
  assert.equal(runtime.getPlaymeshStorageBucket('save'), bucket);
  assert.deepEqual(calls, [
    'GDJS/users/%E6%88%BF%E4%B8%BB%E7%8E%A9%E5%AE%B6/save',
  ]);
}

// A non-Authority App page can use the App identity when it has no session
// player (for example, an App-hosted solo game).
{
  const calls = [];
  const bucket = { getDataSync() {}, setDataSync() {} };
  const runtime = makeResolver({
    playmesh: {
      app: {
        identity: { getCurrent: () => ({ nickname: '单机用户' }) },
      },
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: false }) },
        player: { getCurrent: () => null },
        session: { isAuthority: () => false },
        storage: {
          getBucket(name) {
            calls.push(name);
            return bucket;
          },
        },
      },
    },
  });
  assert.equal(runtime.getPlaymeshStorageBucket('save'), bucket);
  assert.deepEqual(calls, ['GDJS/users/%E5%8D%95%E6%9C%BA%E7%94%A8%E6%88%B7/save']);
}

// The resolved scope is frozen for the page lifetime. A mid-session nickname
// change cannot move an already loaded GDevelop root into another user's save.
{
  let nickname = 'auth';
  const calls = [];
  const bucket = { getDataSync() {}, setDataSync() {} };
  const runtime = makeResolver({
    playmesh: {
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: true }) },
        player: { getCurrent: () => ({ nickname }) },
        session: { isAuthority: () => false },
        storage: {
          getBucket(name) {
            calls.push(name);
            return bucket;
          },
        },
      },
    },
  });
  assert.equal(runtime.getPlaymeshStorageBucket('first'), bucket);
  nickname = 'renamed';
  assert.equal(runtime.getPlaymeshStorageBucket('second'), bucket);
  assert.deepEqual(calls, [
    'GDJS/users/auth/first',
    'GDJS/users/auth/second',
  ]);
}

// Identity resolution fails closed before SDK bootstrap and may be retried
// after readiness; it never assigns an unready player to the auth directory.
{
  let gameInfo = null;
  let bucketCalls = 0;
  const bucket = { getDataSync() {}, setDataSync() {} };
  const runtime = makeResolver({
    playmesh: {
      main: {
        gameInfo: { getCurrent: () => gameInfo },
        player: { getCurrent: () => ({ nickname: 'ready-player' }) },
        session: { isAuthority: () => false },
        storage: {
          getBucket() {
            bucketCalls += 1;
            return bucket;
          },
        },
      },
    },
  });
  assert.throws(
    () => runtime.getPlaymeshStorageBucket('save'),
    /尚未就绪/
  );
  assert.equal(bucketCalls, 0);
  gameInfo = { multiplayer: true };
  assert.equal(runtime.getPlaymeshStorageBucket('save'), bucket);
  assert.equal(bucketCalls, 1);
}

// A Playmesh browser-solo page has no player or App identity today. It keeps
// the official per-browser localStorage semantics and never enters auth.
{
  let bucketCalls = 0;
  const runtime = makeResolver({
    playmesh: {
      main: {
        gameInfo: { getCurrent: () => ({ multiplayer: false }) },
        player: { getCurrent: () => null },
        session: { isAuthority: () => false },
        storage: {
          getBucket() {
            bucketCalls += 1;
            return { getDataSync() {}, setDataSync() {} };
          },
        },
      },
    },
  });
  const calls = [];
  const localStorage = {
    getItem(key) {
      calls.push(['getItem', key]);
      return '{"solo":true}';
    },
    setItem(key, value) {
      calls.push(['setItem', key, value]);
    },
  };
  assert.equal(
    runLoad({
      name: 'solo-save',
      localStorage,
      logger,
      ...runtime,
    }),
    '{"solo":true}'
  );
  runUnload({
    name: 'solo-save',
    jsObject: { solo: true },
    serializedString: '{"solo":true}',
    localStorage,
    logger,
    ...runtime,
  });
  assert.equal(bucketCalls, 0);
  assert.deepEqual(calls, [
    ['getItem', 'GDJS_solo-save'],
    ['setItem', 'GDJS_solo-save', '{"solo":true}'],
  ]);
}

// Any partial/fake Playmesh surface is incompatible. Resolution happens
// before either official localStorage branch, so it cannot silently fallback.
for (const playmesh of [
  null,
  {},
  { main: {} },
  { main: { storage: {} } },
  {
    main: {
      gameInfo: { getCurrent: () => ({ multiplayer: true }) },
      player: { getCurrent: () => ({ nickname: '玩家' }) },
      session: { isAuthority: () => false },
      storage: { getBucket: () => null },
    },
  },
  {
    main: {
      gameInfo: { getCurrent: () => ({ multiplayer: true }) },
      player: { getCurrent: () => ({ nickname: '玩家' }) },
      session: { isAuthority: () => false },
      storage: { getBucket: () => ({ getDataSync() {} }) },
    },
  },
  {
    main: {
      gameInfo: { getCurrent: () => ({ multiplayer: true }) },
      player: { getCurrent: () => ({ nickname: '玩家' }) },
      session: { isAuthority: () => false },
      storage: { getBucket: () => ({ setDataSync() {} }) },
    },
  },
]) {
  const runtime = makeResolver({ playmesh });
  let localStorageCalls = 0;
  assert.throws(
    () =>
      runLoad({
        name: 'save',
        localStorage: {
          getItem() {
            localStorageCalls += 1;
          },
        },
        logger,
        ...runtime,
      }),
    /不兼容的 PlayMesh Game SDK.*同步存储/s
  );
  assert.throws(
    () =>
      runUnload({
        name: 'save',
        jsObject: { score: 1 },
        serializedString: '{"score":1}',
        localStorage: {
          setItem() {
            localStorageCalls += 1;
          },
        },
        logger,
        ...runtime,
      }),
    /不兼容的 PlayMesh Game SDK.*同步存储/s
  );
  assert.equal(localStorageCalls, 0);
}

const manifestEntry = outputManifest.patchedOfficialFiles.filter(
  entry => entry.relativePath === storagePath
);
assert.equal(manifestEntry.length, 1);
assert.equal(manifestEntry[0].upstreamGitBlobSha, upstreamGitBlobSha);

const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex !== -1) {
  const sourceRoot = process.argv[sourceArgumentIndex + 1];
  if (!sourceRoot) throw new Error('--source requires a patched GDevelop root');
  const patched = await readFile(path.join(sourceRoot, ...storagePath.split('/')));
  const patchedText = patched.toString('utf8');
  assert.equal(patchedText.includes('Symbol.for('), false);
  assert.equal(
    patchedText.split("localStorage.getItem('GDJS_' + name)").length - 1,
    1
  );
  assert.equal(
    patchedText.split("localStorage.setItem('GDJS_' + name, serializedString)")
      .length - 1,
    1
  );
  assert.equal(patchedText.split('getPlaymeshStorageBucket(name)').length - 1, 2);
  assert.equal(patchedText.split('getDataSync(').length - 1, 1);
  assert.equal(patchedText.split('setDataSync(').length - 1, 1);
  const digest = createHash('sha256').update(patched).digest('hex');
  assert.equal(manifestEntry[0].postPatchSha256, digest);
}

process.stdout.write('GDevelop storagetools three-state runtime contract passed.\n');
