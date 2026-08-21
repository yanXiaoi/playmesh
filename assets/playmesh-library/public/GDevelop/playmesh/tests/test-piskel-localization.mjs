import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

import { computeDirectoryTreeDigest } from '../scripts/source-policy-verifier-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const gdevelopDirectory = path.resolve(playmeshDirectory, '..');
const derivativeDirectory = path.join(
  playmeshDirectory,
  'external-editors',
  'piskel'
);
const sharedDirectory = path.join(
  playmeshDirectory,
  'external-editors',
  'shared'
);
const manifest = JSON.parse(
  await readFile(path.join(derivativeDirectory, 'manifest.json'), 'utf8')
);
const sharedManifest = JSON.parse(
  await readFile(path.join(sharedDirectory, 'manifest.json'), 'utf8')
);
const officialManifest = JSON.parse(
  await readFile(path.join(gdevelopDirectory, 'official', 'external-editors.json'), 'utf8')
);
const officialPiskel = officialManifest.editors.find(
  editor => editor.name === 'piskel'
);

assert.equal(manifest.derivedVersion, '5.5.228-playmesh.1');
assert.deepEqual(manifest.base, {
  gdevelopExternalEditorVersion: officialPiskel.version,
  officialArchiveSha256: officialPiskel.officialArchiveSha256,
  officialTreeSha256: officialPiskel.treeSha256,
});
assert.deepEqual(
  manifest.locales.map(locale => locale.id).sort(),
  ['en', 'zh-CN']
);
assert.deepEqual(
  manifest.coverage.neverTranslate,
  [
    'sprite-names',
    'frame-names',
    'layer-names',
    'palette-names',
    'file-names',
    'resource-paths',
    'user-descriptions',
    'user-entered-text',
  ]
);

const officialTree = await computeDirectoryTreeDigest(
  path.join(
    gdevelopDirectory,
    'official',
    'external-editors',
    'piskel',
    'piskel-editor'
  )
);
assert.equal(officialTree.sha256, officialPiskel.treeSha256);
assert.equal(officialTree.files.length, officialPiskel.fileCount);

const sharedTree = await computeDirectoryTreeDigest(
  path.join(sharedDirectory, 'overlay')
);
assert.equal(sharedTree.sha256, sharedManifest.overlay.treeSha256);
assert.equal(sharedTree.files.length, sharedManifest.overlay.fileCount);
const derivativeTree = await computeDirectoryTreeDigest(
  path.join(derivativeDirectory, 'overlay')
);
assert.equal(derivativeTree.sha256, manifest.overlay.treeSha256);
assert.equal(derivativeTree.files.length, manifest.overlay.fileCount);

const captureCatalog = async localeEntry => {
  const registrations = [];
  const root = Object.freeze({
    PlaymeshExternalEditorI18n: Object.freeze({
      registerCatalog: catalog => registrations.push(catalog),
    }),
  });
  vm.runInNewContext(
    await readFile(
      path.join(
        derivativeDirectory,
        'overlay',
        ...localeEntry.catalog.split('/')
      ),
      'utf8'
    ),
    { globalThis: root, window: root }
  );
  assert.equal(registrations.length, 1);
  return registrations[0];
};
const catalogs = new Map();
for (const localeEntry of manifest.locales) {
  const catalog = await captureCatalog(localeEntry);
  assert.equal(catalog.editor, 'piskel');
  assert.equal(catalog.locale, localeEntry.id);
  assert.equal(Object.keys(catalog.messages).length, localeEntry.messageCount);
  assert.ok(Object.values(catalog.messages).every(value => typeof value === 'string'));
  catalogs.set(localeEntry.id, catalog.messages);
}
assert.deepEqual(
  Object.keys(catalogs.get('en')).sort(),
  Object.keys(catalogs.get('zh-CN')).sort(),
  'both Piskel locales must expose the same message keys'
);

const sharedRuntimePath = path.join(
  sharedDirectory,
  'overlay',
  'playmesh-external-editor-i18n.js'
);
const piskelRuntimePath = path.join(
  derivativeDirectory,
  'overlay',
  'playmesh-i18n',
  'piskel-i18n.js'
);
const runtimeContext = {
  URLSearchParams,
  location: { search: '?locale=zh-CN' },
  navigator: { language: 'en-US', languages: ['en-US'] },
  document: {
    documentElement: { getAttribute: () => 'en' },
  },
};
runtimeContext.globalThis = runtimeContext;
runtimeContext.window = runtimeContext;
vm.createContext(runtimeContext);
vm.runInContext(await readFile(sharedRuntimePath, 'utf8'), runtimeContext);
for (const localeEntry of manifest.locales) {
  vm.runInContext(
    await readFile(
      path.join(
        derivativeDirectory,
        'overlay',
        ...localeEntry.catalog.split('/')
      ),
      'utf8'
    ),
    runtimeContext
  );
}
vm.runInContext(await readFile(piskelRuntimePath, 'utf8'), runtimeContext);
assert.equal(runtimeContext.PlaymeshPiskelI18n.locale, 'zh-CN');
assert.equal(runtimeContext.PlaymeshPiskelI18n.t('panel.layers'), '图层');
assert.equal(
  runtimeContext.PlaymeshPiskelI18n.translateKnownRuntimeMessage(
    'Are you sure you want to delete palette 用户自定义调色板'
  ),
  '确定删除调色板“用户自定义调色板”吗？'
);
assert.equal(
  runtimeContext.PlaymeshPiskelI18n.translateKnownRuntimeMessage(
    '玩家输入/火焰_第01帧.png'
  ),
  '玩家输入/火焰_第01帧.png',
  'unregistered user content must pass through byte-for-byte'
);
assert.equal(
  runtimeContext.PlaymeshExternalEditorI18n.resolveLocale({
    explicitLocale: 'zh-TW',
    documentLanguage: 'en',
    browserLanguages: ['zh-CN'],
    supportedLocales: ['en', 'zh-CN'],
    defaultLocale: 'en',
    aliases: { zh: 'zh-CN', 'zh-Hans': 'zh-CN' },
  }),
  'en',
  'an unsupported explicit locale must not silently become Simplified Chinese'
);

const piskelRuntimeSource = await readFile(piskelRuntimePath, 'utf8');
assert.doesNotMatch(piskelRuntimeSource, /TreeWalker|SHOW_TEXT|NodeFilter/);
for (const forbiddenSelector of [
  '.layer-name',
  '.piskel-name',
  '.import-image-file-name',
  '.session-details-title',
  '.snapshot-details-title',
]) {
  assert.ok(
    !piskelRuntimeSource.includes(`rule('${forbiddenSelector}'`),
    `user/model selector must not be translated: ${forbiddenSelector}`
  );
}

const applyPolicySource = await readFile(
  path.join(playmeshDirectory, 'scripts', 'apply-source-policy.mjs'),
  'utf8'
);
assert.match(
  applyPolicySource,
  /getPlaymeshPromptLocale\(\)[\s\S]*?externalEditorWindow\.location = externalEditorUrl\.toString\(\)/
);
assert.match(
  applyPolicySource,
  /editorFrameEl\.src = piskelEditorUrl\.toString\(\)/
);
assert.match(
  applyPolicySource,
  /window\.PlaymeshPiskelI18n\.beforePiskelInit\(pskl\);[\s\S]*?pskl\.app\.init\(\);[\s\S]*?window\.PlaymeshPiskelI18n\.afterPiskelInit\(\);/
);
assert.match(
  applyPolicySource,
  /join\(','\) !== 'jfxr,piskel,yarn'/
);
assert.match(applyPolicySource, /localeKeySets\.get\('en'\)/);

const pipelineSource = await readFile(
  path.join(playmeshDirectory, 'scripts', 'webide-pipeline.mjs'),
  'utf8'
);
assert.match(
  pipelineSource,
  /localExternalEditorDerivativesTreeSha256:[\s\S]*?root: localExternalEditorDerivativesPath/
);

process.stdout.write(
  `Piskel localization contract passed (${manifest.derivedVersion}, ${
    manifest.locales[0].messageCount
  } keys per locale).\n`
);
