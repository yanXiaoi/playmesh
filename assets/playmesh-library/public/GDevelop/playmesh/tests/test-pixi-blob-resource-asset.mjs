import assert from 'node:assert/strict';
import { File } from 'node:buffer';
import { access, readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const dependenciesCacheRoot = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/cache/deps'
);

const dependencyCacheEntries = await readdir(dependenciesCacheRoot, {
  withFileTypes: true,
});
let dependenciesRoot = null;
const dependencyCandidates = [
  path.resolve(
    repositoryRoot,
    'work/gdevelop-webide-build-cache/profiles/default/build-source/newIDE/app'
  ),
  ...dependencyCacheEntries
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(dependenciesCacheRoot, entry.name)),
];
for (const candidate of dependencyCandidates) {
  try {
    await access(path.join(candidate, 'node_modules/pixi.js/package.json'));
    await access(
      path.join(candidate, 'node_modules/@babel/plugin-transform-flow-strip-types')
    );
    dependenciesRoot = candidate;
    break;
  } catch (_error) {
    // This cache entry belongs to another build dependency set.
  }
}
assert.ok(
  dependenciesRoot,
  'a cached GDevelop dependency set containing Pixi and Babel is required'
);

const appRequire = createRequire(path.join(dependenciesRoot, 'package.json'));
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const source = await readFile(
  path.resolve(
    testDirectory,
    '../overlays/newIDE/app/src/PlaymeshResources/PlaymeshPixiTextureAsset.js'
  ),
  'utf8'
);
const executable = transformSync(source, {
  babelrc: false,
  configFile: false,
  plugins: [[flowStripPlugin, { all: true }]],
  sourceType: 'module',
}).code;
const { getPlaymeshPixiTextureAsset } = await import(
  `data:text/javascript;base64,${Buffer.from(executable).toString('base64')}`
);

const pixiPackage = JSON.parse(
  await readFile(
    path.join(dependenciesRoot, 'node_modules/pixi.js/package.json'),
    'utf8'
  )
);
assert.match(
  pixiPackage.version,
  /^7\./,
  'the runtime contract must exercise the cached Pixi 7 implementation'
);

const { Assets, loadTextures } = appRequire(
  path.join(dependenciesRoot, 'node_modules/@pixi/assets/lib/index.js')
);
assert.ok(
  Assets.loader.parsers.includes(loadTextures),
  'the real Pixi Assets singleton must have the real loadTextures parser registered'
);

const originalLoadTexturesLoad = loadTextures.load;
const originalLoadTexturesTest = loadTextures.test;
let parserLoadCalls = [];
let parserTestCalls = 0;
loadTextures.test = (...args) => {
  parserTestCalls += 1;
  return originalLoadTexturesTest(...args);
};
loadTextures.load = async (url, descriptor) => {
  const response = await fetch(url);
  const blob = await response.blob();
  const loadedFixture = {
    destroyed: false,
    parser: descriptor.loadParser,
    size: blob.size,
    type: blob.type,
    url,
    destroy() {
      this.destroyed = true;
    },
  };
  parserLoadCalls.push(loadedFixture);
  return loadedFixture;
};

const fixtures = [
  new File([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], 'camera.JPG', {
    type: 'image/jpeg',
  }),
  new File(
    [new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])],
    'sprite.PNG',
    { type: 'image/png' }
  ),
];

try {
  for (const file of fixtures) {
    const blobUrl = URL.createObjectURL(file);
    try {
      assert.match(blobUrl, /^blob:/);
      assert.doesNotMatch(blobUrl, /\.(?:jpe?g|png)(?:$|[?#])/i);

      // Reproduce the real regression: the initial render has already added
      // and resolved the bare Blob URL. Pixi then refuses to replace that
      // resolver key when an object with the same src provides loadParser.
      Assets.reset();
      await Assets.init({ skipDetections: true });
      Assets.add({ alias: blobUrl, src: blobUrl });
      Assets.resolver.resolve(blobUrl);
      parserLoadCalls = [];
      parserTestCalls = 0;
      const warnings = [];
      const originalConsoleWarn = console.warn;
      let originalDescriptorResult;
      console.warn = (...args) => warnings.push(args.join(' '));
      try {
        originalDescriptorResult = await Assets.load({
          src: blobUrl,
          loadParser: 'loadTextures',
        });
      } finally {
        console.warn = originalConsoleWarn;
      }
      assert.equal(originalDescriptorResult, null);
      assert.equal(parserLoadCalls.length, 0);
      assert.ok(
        parserTestCalls > 0,
        'the stale resolver entry must reproduce URL auto-detection instead of named parser selection'
      );
      assert.ok(
        warnings.some(message =>
          message.includes("could not be loaded as we don't know how to parse it")
        ),
        'the stale resolver entry must reproduce the real Pixi warning'
      );

      // The Playmesh descriptor uses a private alias, so the actual Assets
      // resolver creates a distinct entry carrying loadParser while the real
      // Loader still fetches and caches the original Blob src.
      Assets.reset();
      await Assets.init({ skipDetections: true });
      Assets.add({ alias: blobUrl, src: blobUrl });
      Assets.resolver.resolve(blobUrl);
      parserLoadCalls = [];
      parserTestCalls = 0;
      const descriptor = getPlaymeshPixiTextureAsset(blobUrl);
      assert.deepEqual(descriptor, {
        alias: `playmesh-blob-texture:${blobUrl}`,
        src: blobUrl,
        loadParser: 'loadTextures',
      });

      const firstLoaded = await Assets.load(descriptor);
      assert.equal(parserTestCalls, 0, 'the explicit parser must bypass URL suffix detection');
      assert.equal(parserLoadCalls.length, 1);
      assert.equal(firstLoaded.url, blobUrl);
      assert.equal(firstLoaded.parser, 'loadTextures');
      assert.equal(firstLoaded.type, file.type);
      assert.equal(firstLoaded.size, file.size);
      assert.equal(Assets.cache.has(blobUrl), true);
      assert.equal(Assets.cache.has(descriptor.alias), true);

      await Assets.unload(blobUrl);
      assert.equal(firstLoaded.destroyed, true);
      assert.equal(Assets.cache.has(blobUrl), false);
      assert.equal(Assets.cache.has(descriptor.alias), false);

      parserLoadCalls = [];
      parserTestCalls = 0;
      const reloaded = await Assets.load(descriptor);
      assert.equal(parserTestCalls, 0);
      assert.equal(parserLoadCalls.length, 1);
      assert.equal(reloaded.type, file.type);
      assert.equal(reloaded.url, blobUrl);
      await Assets.unload(blobUrl);
      assert.equal(reloaded.destroyed, true);
    } finally {
      URL.revokeObjectURL(blobUrl);
    }
  }

  assert.equal(
    getPlaymeshPixiTextureAsset('https://example.invalid/image.png'),
    'https://example.invalid/image.png',
    'ordinary resources must keep Pixi official parser detection'
  );
} finally {
  loadTextures.load = originalLoadTexturesLoad;
  loadTextures.test = originalLoadTexturesTest;
  Assets.reset();
}

process.stdout.write(
  `Pixi ${pixiPackage.version} extensionless Blob image Assets/Resolver/Loader contract passed.\n`
);
