import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';

const sourceIndex = process.argv.indexOf('--source');
const sourceRoot =
  sourceIndex === -1 ? null : path.resolve(process.argv[sourceIndex + 1] || '');
if (!sourceRoot) {
  throw new Error(
    'Usage: node test-builtin-extension-localization-source.mjs --source <patched GDevelop root>'
  );
}

const loadCompiledCatalog = async relativePath => {
  const source = await readFile(path.join(sourceRoot, relativePath), 'utf8');
  const sandbox = { module: { exports: {} }, exports: {} };
  vm.runInNewContext(source, sandbox, { filename: relativePath });
  return sandbox.module.exports;
};

const loadMergedMessages = async language => {
  const localeRoot = path.join('newIDE', 'app', 'src', 'locales', language);
  const [editorCatalog, extensionCatalog] = await Promise.all([
    loadCompiledCatalog(path.join(localeRoot, 'messages.js')),
    loadCompiledCatalog(path.join(localeRoot, 'extension-messages.js')),
  ]);
  return {
    ...extensionCatalog.messages,
    ...editorCatalog.messages,
  };
};

const providerPath = path.join(
  sourceRoot,
  'newIDE',
  'app',
  'src',
  'Utils',
  'i18n',
  'GDI18nProvider.js'
);
const providerSource = await readFile(providerPath, 'utf8');

const setupIndex = providerSource.indexOf('const nextI18n = setupI18n({');
const translationIndex = providerSource.indexOf(
  'gd.getTranslation = getTranslationFunction(nextI18n);'
);
const measurementIndex = providerSource.indexOf(
  'gd.MeasurementUnit.applyTranslation();'
);
const reloadIndex = providerSource.indexOf(
  'gd.JsPlatform.get().reloadBuiltinExtensions();'
);
const publishIndex = providerSource.indexOf('this.setState(', setupIndex);

assert.ok(setupIndex >= 0, 'the next locale must be initialized explicitly');
assert.ok(
  setupIndex < translationIndex &&
    translationIndex < measurementIndex &&
    measurementIndex < reloadIndex &&
    reloadIndex < publishIndex,
  'libGD translations and native built-ins must be refreshed before the locale is published to child components'
);
assert.equal(
  providerSource.includes('gd.getTranslation = getTranslationFunction(i18n);'),
  false,
  'the translation function must not be installed only in the post-render setState callback'
);

// Native object and behavior metadata is registered once by libGD. These are
// the stable built-ins users encounter in the object/behavior creation UI and
// form a regression baseline for both official Chinese catalogs. Values come
// from GDevelop's official catalogs; Playmesh does not override or machine
// translate them.
const criticalBuiltInMetadataKeys = [
  'Sprite',
  'Animated object which can be used for most elements of a 2D game.',
  'Tiled Sprite',
  'Displays an image repeated over an area.',
  'Panel Sprite',
  'An image with edges and corners that are stretched separately from the full image.',
  'Text',
  'Displays a text on the screen.',
  'Platform',
  'Platformer character',
  'Destroy when outside of the screen',
  'Destroy objects automatically when they go outside of the 2D camera borders.',
  'Draggable object',
  'Top-down movement',
  'Pathfinding',
  'Obstacle for pathfinding',
  'Anchor',
  "Anchor objects to the window's bounds.",
];

for (const language of ['zh_CN', 'zh_TW']) {
  const messages = await loadMergedMessages(language);
  for (const key of criticalBuiltInMetadataKeys) {
    assert.equal(
      Object.prototype.hasOwnProperty.call(messages, key),
      true,
      `${language} official catalog is missing built-in metadata key: ${key}`
    );
    assert.equal(
      typeof messages[key],
      'string',
      `${language} built-in metadata must compile to a string: ${key}`
    );
    assert.notEqual(
      messages[key],
      key,
      `${language} built-in metadata unexpectedly falls back to English: ${key}`
    );
  }
}

console.log(
  `Built-in localization source contract passed (${criticalBuiltInMetadataKeys.length} keys across zh_CN/zh_TW).`
);
