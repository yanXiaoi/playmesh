import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';

import { computeDirectoryTreeDigest } from '../scripts/source-policy-verifier-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const derivativesRoot = path.resolve(testDirectory, '../external-editors');
const scriptsRoot = path.resolve(testDirectory, '../scripts');

const readText = relativePath =>
  readFile(path.resolve(derivativesRoot, ...relativePath.split('/')), 'utf8');

const loadCatalog = async relativePath => {
  const registrations = [];
  const root = {
    PlaymeshExternalEditorI18n: {
      registerCatalog: catalog => registrations.push(catalog),
    },
  };
  root.globalThis = root;
  root.window = root;
  runInNewContext(await readText(relativePath), root, { filename: relativePath });
  assert.equal(registrations.length, 1, `${relativePath} must register once`);
  return registrations[0];
};

const manifests = new Map();
const catalogs = new Map();
for (const editor of ['jfxr', 'yarn']) {
  const manifest = JSON.parse(await readText(`${editor}/manifest.json`));
  manifests.set(editor, manifest);
  assert.equal(manifest.name, editor);
  assert.deepEqual(
    manifest.locales.map(locale => locale.id),
    ['en', 'zh-CN']
  );
  const editorCatalogs = new Map();
  for (const locale of manifest.locales) {
    const catalog = await loadCatalog(`${editor}/overlay/${locale.catalog}`);
    editorCatalogs.set(locale.id, catalog);
    assert.equal(catalog.editor, editor);
    assert.equal(catalog.locale, locale.id);
    assert.equal(Object.keys(catalog.messages).length, locale.messageCount);
    assert.ok(
      Object.values(catalog.messages).every(message => typeof message === 'string')
    );
  }
  assert.deepEqual(
    Object.keys(editorCatalogs.get('en').messages).sort(),
    Object.keys(editorCatalogs.get('zh-CN').messages).sort(),
    `${editor} locale catalogs must have the same key set`
  );
  catalogs.set(editor, editorCatalogs);

  const overlayTree = await computeDirectoryTreeDigest(
    path.join(derivativesRoot, editor, 'overlay')
  );
  assert.equal(overlayTree.sha256, manifest.overlay.treeSha256);
  assert.equal(overlayTree.files.length, manifest.overlay.fileCount);
}

const runtimeSource = await readText(
  'shared/overlay/playmesh-external-editor-i18n.js'
);
const createDocument = ({ language = '', elements = new Map() } = {}) => {
  let currentLanguage = language;
  return {
    body: null,
    defaultView: {
      NodeFilter: { SHOW_TEXT: 4 },
      MutationObserver: null,
    },
    documentElement: {
      getAttribute: name => (name === 'lang' ? currentLanguage : null),
      setAttribute: (name, value) => {
        if (name === 'lang') currentLanguage = value;
      },
    },
    getElementById: id => elements.get(id) || null,
    querySelectorAll: () => [],
    createTreeWalker: () => ({ nextNode: () => false, currentNode: null }),
  };
};
const createRuntimeRoot = document => {
  const root = {
    URLSearchParams,
    location: { search: '?locale=zh_CN' },
    navigator: { language: 'en-US', languages: ['en-US'] },
    document,
    addEventListener: () => {},
  };
  root.globalThis = root;
  root.window = root;
  return root;
};

const runtimeRoot = createRuntimeRoot(createDocument({ language: 'en' }));
runInNewContext(runtimeSource, runtimeRoot, { filename: 'shared-runtime.js' });
for (const locale of ['en', 'zh-CN']) {
  runInNewContext(
    await readText(`jfxr/overlay/playmesh-i18n/locales/${locale}.js`),
    runtimeRoot,
    { filename: `jfxr-${locale}.js` }
  );
}
const translator = runtimeRoot.PlaymeshExternalEditorI18n.createTranslator({
  editor: 'jfxr',
  explicitLocale: runtimeRoot.PlaymeshExternalEditorI18n.readExplicitLocale(
    runtimeRoot.location
  ),
  supportedLocales: ['en', 'zh-CN'],
  defaultLocale: 'en',
  aliases: { zh_CN: 'zh-CN' },
  documentLanguage: 'en',
  browserLanguages: ['en-US'],
});
assert.equal(translator.locale, 'zh-CN');
assert.equal(translator.translateSource('Open'), '打开');
assert.equal(
  translator.t('wrapper.title', { name: 'Laser' }),
  'GDevelop 音效编辑器（Jfxr）- Laser'
);

const makeControl = value => {
  const attributes = new Map();
  return {
    value,
    disabled: false,
    addEventListener: () => {},
    getAttribute: name => attributes.get(name) ?? null,
    setAttribute: (name, attributeValue) => {
      attributes.set(name, String(attributeValue));
    },
  };
};
const storyLanguage = makeControl('cmn-Hans-CN');
const settingsSpellcheck = makeControl('');
const toolbarSpellcheck = makeControl('');
const yarnElements = new Map([
  ['language', storyLanguage],
  ['spellcheck', settingsSpellcheck],
  ['toglSpellCheck', toolbarSpellcheck],
]);
const yarnRoot = createRuntimeRoot(
  createDocument({ language: 'en', elements: yarnElements })
);
const localizedDialogs = [];
yarnRoot.alert = message => localizedDialogs.push(['alert', message]);
yarnRoot.confirm = message => {
  localizedDialogs.push(['confirm', message]);
  return true;
};
runInNewContext(runtimeSource, yarnRoot, { filename: 'shared-runtime-yarn.js' });
for (const locale of ['en', 'zh-CN']) {
  runInNewContext(
    await readText(`yarn/overlay/playmesh-i18n/locales/${locale}.js`),
    yarnRoot,
    { filename: `yarn-${locale}.js` }
  );
}
runInNewContext(
  await readText('yarn/overlay/playmesh-i18n/install.js'),
  yarnRoot,
  { filename: 'yarn-install.js' }
);
assert.equal(yarnRoot.PlaymeshYarnI18n.locale, 'zh-CN');
assert.equal(
  storyLanguage.value,
  'cmn-Hans-CN',
  'UI localization must not rewrite Yarn Story language'
);
assert.equal(settingsSpellcheck.disabled, true);
assert.equal(toolbarSpellcheck.disabled, true);
assert.equal(
  settingsSpellcheck.getAttribute('data-playmesh-local-dictionary-available'),
  'false'
);
assert.match(settingsSpellcheck.getAttribute('title'), /英语词典/);
assert.equal(
  yarnRoot.confirm(
    'Are you sure you want to close \nchapter.yarn\nAny unsaved progress will be lost...'
  ),
  true
);
yarnRoot.alert('Speech recognition not avaiilable!');
assert.deepEqual(localizedDialogs, [
  [
    'confirm',
    '确定要关闭以下文件吗？\nchapter.yarn\n所有未保存的进度都将丢失…',
  ],
  ['alert', '语音识别不可用！'],
]);

const jfxrInstaller = await readText('jfxr/overlay/playmesh-i18n/install.js');
const yarnInstaller = await readText('yarn/overlay/playmesh-i18n/install.js');
assert.match(jfxrInstaller, /'\.soundname'/);
assert.match(jfxrInstaller, /'\.history'/);
assert.match(yarnInstaller, /'\.nodes'/);
assert.match(yarnInstaller, /'#editorTitle'/);
assert.match(yarnInstaller, /'#editorTags'/);
assert.match(yarnInstaller, /'#language'/);
assert.doesNotMatch(yarnInstaller, /language\.value\s*=/);
assert.doesNotMatch(
  yarnInstaller,
  /SpeechRecognition|webkitSpeechRecognition|speechSynthesis|localService/
);
assert.match(yarnInstaller, /installDialogAdapters/);

assert.equal(catalogs.get('jfxr').get('en').messages['action.link'], 'Link');
assert.equal(
  catalogs.get('yarn').get('zh-CN').messages['settings.storyLanguage'],
  '故事语言'
);

const rootManifest = JSON.parse(await readText('manifest.json'));
assert.deepEqual(
  rootManifest.packages.map(packageReference => packageReference.name).sort(),
  ['jfxr', 'piskel', 'yarn']
);
const sharedManifest = JSON.parse(await readText(rootManifest.sharedRuntime));
const sharedOverlayTree = await computeDirectoryTreeDigest(
  path.join(derivativesRoot, 'shared', 'overlay')
);
const requiredArchiveEntries = sharedOverlayTree.files.map(file =>
  `${sharedManifest.targetDirectory.replace('newIDE/app/public/', '')}/${
    file.relativePath
  }`
);
for (const packageReference of rootManifest.packages) {
  const packageManifest = JSON.parse(await readText(packageReference.manifest));
  const packageOverlayTree = await computeDirectoryTreeDigest(
    path.join(derivativesRoot, packageReference.name, 'overlay')
  );
  for (const file of packageOverlayTree.files) {
    requiredArchiveEntries.push(
      `external/${packageReference.name}/${packageReference.name}-editor/${
        file.relativePath
      }`
    );
  }
}
const packageSource = await readFile(
  path.join(scriptsRoot, 'package-webide-release.mjs'),
  'utf8'
);
for (const entry of requiredArchiveEntries) {
  assert.equal(
    packageSource.split(`'${entry}'`).length - 1,
    1,
    `${entry} must be audited exactly once in the final WebIDE ZIP`
  );
}

console.log('GDevelop Jfxr/Yarn local i18n derivative contracts passed.');
