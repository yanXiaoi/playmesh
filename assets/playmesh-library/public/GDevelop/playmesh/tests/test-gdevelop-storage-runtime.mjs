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
  'add a lazy fail-closed Playmesh App synchronous Bucket capability resolver'
);
const resolverMatch = resolverReplacement.match(
  /const playmeshGDevelopRootKey = [\s\S]*?return bucket;\n      };/
);
assert.ok(resolverMatch, 'storage resolver source is missing');
const executableResolver = resolverMatch[0]
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
assert.equal(storageReplacementSource.includes('playmesh.main.storage'), false);
assert.equal(storageReplacementSource.includes('playmesh.app.storage'), true);

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

// Generic official exports retain the official localStorage behavior.
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
  assert.equal(runLoad({ name: '存档/一', localStorage, logger, ...runtime }), '{"score":7}');
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

// Playmesh pages use the current device's App Bucket. Authority, player and
// nickname state are deliberately irrelevant to the local storage scope.
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
      app: {
        storage: {
          getBucket(name) {
            calls.push(['getBucket', name]);
            return bucket;
          },
        },
      },
      main: {
        storage: {
          getBucket() {
            throw new Error('GDevelop must not use Main Bucket');
          },
        },
      },
    },
  });
  let localStorageCalls = 0;
  const localStorage = {
    getItem() { localStorageCalls += 1; },
    setItem() { localStorageCalls += 1; },
  };
  assert.equal(
    runLoad({ name: '原始/本地存档', localStorage, logger, ...runtime }),
    '{"score":9}'
  );
  runUnload({
    name: '原始/本地存档',
    jsObject: { score: 10 },
    serializedString: '{"score":10}',
    localStorage,
    logger,
    ...runtime,
  });
  assert.equal(localStorageCalls, 0);
  assert.deepEqual(calls, [
    ['getBucket', 'GDJS/原始/本地存档'],
    ['getDataSync', rootKey],
    ['getBucket', 'GDJS/原始/本地存档'],
    ['setDataSync', rootKey, { score: 10 }],
  ]);
}

// Partial/fake Playmesh App surfaces fail closed without a second local copy.
for (const playmesh of [
  null,
  {},
  { app: {} },
  { app: { storage: {} } },
  { app: { storage: { getBucket: () => null } } },
  { app: { storage: { getBucket: () => ({ getDataSync() {} }) } } },
  { app: { storage: { getBucket: () => ({ setDataSync() {} }) } } },
]) {
  const runtime = makeResolver({ playmesh });
  let localStorageCalls = 0;
  assert.throws(
    () => runLoad({
      name: 'save',
      localStorage: { getItem() { localStorageCalls += 1; } },
      logger,
      ...runtime,
    }),
    /不兼容的 PlayMesh App SDK.*同步存储/s
  );
  assert.throws(
    () => runUnload({
      name: 'save',
      jsObject: { score: 1 },
      serializedString: '{"score":1}',
      localStorage: { setItem() { localStorageCalls += 1; } },
      logger,
      ...runtime,
    }),
    /不兼容的 PlayMesh App SDK.*同步存储/s
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

process.stdout.write('GDevelop storagetools App Bucket runtime contract passed.\n');
