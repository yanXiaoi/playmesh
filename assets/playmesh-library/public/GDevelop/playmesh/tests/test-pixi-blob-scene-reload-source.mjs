import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex === -1 || !process.argv[sourceArgumentIndex + 1]) {
  throw new Error(
    'Usage: node test-pixi-blob-scene-reload-source.mjs --source <patched GDevelop root>'
  );
}
const sourceRoot = path.resolve(process.argv[sourceArgumentIndex + 1]);
const readSource = relativePath =>
  readFile(path.join(sourceRoot, ...relativePath.split('/')), 'utf8');

const pixiResourcesLoader = await readSource(
  'newIDE/app/src/ObjectsRendering/PixiResourcesLoader.js'
);
const pixiTextureAsset = await readSource(
  'newIDE/app/src/PlaymeshResources/PlaymeshPixiTextureAsset.js'
);
assert.match(
  pixiTextureAsset,
  /alias:\s*`\$\{PLAYMESH_PIXI_BLOB_TEXTURE_ALIAS_PREFIX\}\$\{url\}`/
);
assert.match(pixiTextureAsset, /loadParser:\s*'loadTextures'/);
assert.match(
  pixiResourcesLoader,
  /getPlaymeshPixiTextureAsset.*PlaymeshPixiTextureAsset/
);
assert.match(
  pixiResourcesLoader,
  /PIXI\.Assets\.load\(\s*getPlaymeshPixiTextureAsset\(url\)\s*\)/
);
assert.doesNotMatch(
  pixiResourcesLoader,
  /Platformer|PlatformBehavior|platform role/i
);

const sceneEditor = await readSource('newIDE/app/src/SceneEditor/index.js');
assert.doesNotMatch(sceneEditor, /PlaymeshSceneResourceReloadQueue/);
assert.match(sceneEditor, /reloadFromDisk = true/);
assert.match(sceneEditor, /reloadFromDisk: hasResourceChanged/);
assert.match(sceneEditor, /this\.props\.onObjectEdited\([\s\S]*false[\s\S]*\)/);
assert.match(
  sceneEditor,
  /finally\s*\{[\s\S]*editorDisplay\.startSceneRendering\(true, pauseReason\)/
);
assert.doesNotMatch(sceneEditor, /Platformer|PlatformBehavior|platform role/i);

assert.match(pixiResourcesLoader, /loadedFromUrl\?: string/);
assert.match(pixiResourcesLoader, /pendingResourceReloadPromises/);
assert.match(pixiResourcesLoader, /currentUrl === loadedEntry\.loadedFromUrl/);

process.stdout.write(
  'Pixi Blob parser and official SceneEditor reload contract passed.\n'
);
