import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const sourceIndex = process.argv.indexOf('--source');
if (sourceIndex === -1 || !process.argv[sourceIndex + 1]) {
  throw new Error(
    'Usage: node test-browser-persistence-boundary.mjs --source <patched GDevelop root>'
  );
}

const sourceRoot = path.resolve(process.argv[sourceIndex + 1]);
const readSource = relativePath =>
  readFile(path.join(sourceRoot, relativePath), 'utf8');

const [
  browserApp,
  browserEntry,
  projectCache,
  userUuid,
  localStats,
  cleanup,
  projectStore,
  authentication,
] = await Promise.all([
  readSource('newIDE/app/src/BrowserApp.js'),
  readSource('newIDE/app/src/index.js'),
  readSource('newIDE/app/src/Utils/ProjectCache.js'),
  readSource('newIDE/app/src/Utils/Analytics/UserUUID.js'),
  readSource('newIDE/app/src/Utils/Analytics/LocalStats.js'),
  readSource(
    'newIDE/app/src/PlaymeshBrowserPersistence/PlaymeshBrowserPersistenceCleanup.js'
  ),
  readSource(
    'newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore.js'
  ),
  readSource('newIDE/app/src/Utils/GDevelopServices/Authentication.js'),
]);

assert.match(browserApp, /cleanupPlaymeshLegacyBrowserPersistence\(\)/);
assert.doesNotMatch(
  browserApp,
  /Browser(?:SW|S3)PreviewLauncher|ensureBrowserSWPreviewSession/,
  'BrowserApp must leave preview transport selection to the Playmesh router'
);
assert.match(browserApp, /PlaymeshPreviewLauncherRouter/);
assert.doesNotMatch(
  browserEntry,
  /registerServiceWorker/,
  'the local preview worker must be registered lazily only for in-game edition'
);

assert.doesNotMatch(
  projectCache,
  /indexedDB|IDBDatabase|serializeToJSON|createObjectStore|objectStore\(/
);
assert.match(projectCache, /static isAvailable\(\): any \{\s*return false;/);
assert.match(projectCache, /async get\([^]*?return null;/);
assert.match(projectCache, /async put\([^]*?\{\}/);

assert.doesNotMatch(userUuid, /localStorage|gd-user-uuid/);
assert.match(userUuid, /let currentUserUuid: \?string = null/);
assert.doesNotMatch(localStats, /localStorage|gd-local-stats/);
assert.match(localStats, /let programOpeningCount = 0/);

for (const databaseName of ['gdevelop-cloud-project-autosave']) {
  assert.match(cleanup, new RegExp(databaseName));
}
assert.doesNotMatch(
  cleanup,
  /gdevelop-browser-sw-preview/,
  'the local embedded-preview database is active state, not legacy residue'
);
for (const localStorageKey of [
  'gd-user-uuid',
  'gd-local-stats-program-opening',
]) {
  assert.match(cleanup, new RegExp(localStorageKey));
}
assert.match(cleanup, /deleteDatabase\(databaseName\)/);
assert.doesNotMatch(cleanup, /registration\.unregister\(\)|getRegistrations\(\)/);
assert.doesNotMatch(cleanup, /service-worker/);
assert.match(cleanup, /let cleanupPromise: \?Promise<void> = null/);
assert.match(cleanup, /durableProjectSource: 'app-gateway'/);
assert.match(cleanup, /indexedDbInNormalRuntime: 'forbidden'/);

assert.match(projectStore, /const sessionProjects = new Map/);
assert.doesNotMatch(
  projectStore,
  /indexedDB|IDBDatabase|localStorage|sessionStorage|localforage/i
);
assert.doesNotMatch(
  authentication,
  /initializeApp|\bgetAuth\b|onAuthStateChanged|GDevelopFirebaseConfig/
);
assert.match(authentication, /this\._initialAuthCheckPromise = Promise\.resolve\(\)/);

const sourceDirectory = path.join(sourceRoot, 'newIDE/app/src');
const importPattern =
  /(?:\bfrom\s*|\bimport\s*\(\s*(?:\/\*[\s\S]*?\*\/\s*)?|\bimport\s*)(['"])(\.\.?\/[^'"]+)\1/g;
const resolveLocalImport = async (importerPath, specifier) => {
  const unresolved = path.resolve(path.dirname(importerPath), specifier);
  const candidates = path.extname(unresolved)
    ? [unresolved]
    : [
        `${unresolved}.js`,
        `${unresolved}.jsx`,
        `${unresolved}.ts`,
        `${unresolved}.tsx`,
        path.join(unresolved, 'index.js'),
        path.join(unresolved, 'index.jsx'),
        path.join(unresolved, 'index.ts'),
        path.join(unresolved, 'index.tsx'),
      ];
  for (const candidate of candidates) {
    try {
      if ((await stat(candidate)).isFile()) return candidate;
    } catch (error) {
      // Try the next source extension.
    }
  }
  return null;
};

// Traverse the browser product entry directly. index.js also contains the
// Electron dynamic import, which is a different product graph.
const entryPath = path.join(sourceDirectory, 'BrowserApp.js');
const pending = [entryPath];
const reachableSources = new Map();
while (pending.length) {
  const absolutePath = pending.pop();
  if (!absolutePath || reachableSources.has(absolutePath)) continue;
  const source = await readFile(absolutePath, 'utf8');
  reachableSources.set(absolutePath, source);
  for (const match of source.matchAll(importPattern)) {
    const resolved = await resolveLocalImport(absolutePath, match[2]);
    if (
      resolved &&
      resolved.startsWith(sourceDirectory + path.sep) &&
      !reachableSources.has(resolved)
    ) {
      pending.push(resolved);
    }
  }
}

const inspectIndexedDbOpens = (relativePath, source) => {
  const failures = [];
  for (const match of source.matchAll(
    /(?:window\.)?indexedDB\.open\(\s*([^,)\n]+)/g
  )) {
    const expression = match[1].trim();
    const literalMatch = expression.match(/^['"`]([^'"`]+)['"`]$/);
    const bindingMatch = literalMatch
      ? null
      : source.match(
          new RegExp(
            `(?:const|let|var)\\s+${expression.replace(
              /[.*+?^${}()|[\]\\]/g,
              '\\$&'
            )}\\s*=\\s*['\"\\x60]([^'\"\\x60]+)['\"\\x60]`
          )
        );
    const databaseName = literalMatch?.[1] || bindingMatch?.[1] || expression;
    const line = source.slice(0, match.index).split('\n').length;
    failures.push(`${relativePath}:${line} database=${databaseName}`);
  }
  return failures;
};

assert.deepEqual(
  inspectIndexedDbOpens(
    'fixture.js',
    "const DB_NAME = 'forbidden-fixture-db';\nindexedDB.open(DB_NAME);"
  ),
  ['fixture.js:2 database=forbidden-fixture-db'],
  'the policy audit must report the database name for a forbidden open'
);

const browserSwIndexedDbPath = path.join(
  sourceDirectory,
  'ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher/BrowserSWPreviewIndexedDB.js'
);
const indexedDbOpenFailures = [];
for (const [absolutePath, source] of reachableSources) {
  const opens = inspectIndexedDbOpens(
    path.relative(sourceRoot, absolutePath),
    source
  );
  if (absolutePath === browserSwIndexedDbPath) {
    assert.equal(
      opens.length,
      1,
      'the embedded-preview module must own exactly one IndexedDB open boundary'
    );
    assert.match(source, /const DB_NAME = 'gdevelop-browser-sw-preview';/);
    continue;
  }
  indexedDbOpenFailures.push(...opens);
}
assert.deepEqual(
  indexedDbOpenFailures,
  [],
  `Playmesh normal WebIDE import graph opens IndexedDB:\n${indexedDbOpenFailures.join(
    '\n'
  )}`
);

assert.equal(
  reachableSources.has(browserSwIndexedDbPath),
  true,
  'the local BrowserSW embedded-preview store must be reachable'
);

for (const relativePath of [
  'ExportAndShare/BrowserExporters/BrowserS3PreviewLauncher/index.js',
  'ExportAndShare/BrowserExporters/BrowserS3FileSystem.js',
  'EventsFunctionsExtensionsLoader/CodeWriters/BrowserS3EventsFunctionCodeWriter.js',
  'Utils/GDevelopServices/Preview.js',
]) {
  assert.equal(
    reachableSources.has(path.join(sourceDirectory, relativePath)),
    false,
    `the browser entry graph retained the forbidden S3 preview module: ${relativePath}`
  );
}

assert.equal(
  reachableSources.has(
    path.join(sourceDirectory, 'GameEngineFinder/BrowserS3GDJSFinder.js')
  ),
  true,
  'the historical GDJS finder remains reachable because it resolves packaged local GDJS'
);

process.stdout.write(
  'GDevelop browser persistence boundary tests passed.\n'
);
