import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testRoot = path.dirname(fileURLToPath(import.meta.url));
const playmeshRoot = path.resolve(testRoot, '..');
const helperSource = await readFile(
  path.join(
    playmeshRoot,
    'overlays',
    'newIDE',
    'app',
    'src',
    'PlaymeshCatalog',
    'PlaymeshExtensionSourceUrl.js'
  ),
  'utf8'
);
const helper = await import(
  `data:text/javascript;base64,${Buffer.from(helperSource).toString('base64')}`
);
const validate = value =>
  helper.getSafePlaymeshExtensionSourceUrl({
    value,
    baseUrl: 'http://127.0.0.1:8768/',
  });
const commit = 'de361fba046e0670a8414cbc657dd53788dbfc48';
const canonical = `https://raw.githubusercontent.com/GDevelopApp/GDevelop-extensions/${commit}/extensions/reviewed/CameraShake.json`;
const safe = validate(canonical);
assert.equal(safe.kind, 'external');
assert.equal(safe.provider, 'raw.githubusercontent.com');
assert.equal(safe.url, canonical);

for (const unsafe of [
  'javascript:alert(1)',
  'data:text/plain,bad',
  'https://user:password@raw.githubusercontent.com/GDevelopApp/GDevelop-extensions/' + commit + '/extensions/reviewed/CameraShake.json',
  'https://evil.example/' + commit + '/extensions/reviewed/CameraShake.json',
]) {
  assert.equal(validate(unsafe), null, unsafe);
}
assert.equal(
  validate('https://raw.githubusercontent.com/example/repository/main/file.json')
    .kind,
  'external'
);
const internal = validate('./playmesh/catalog/CameraShake.json');
assert.equal(internal.kind, 'internal');
assert.equal(internal.displayUrl, './playmesh/catalog/CameraShake.json');

const componentSource = await readFile(
  path.join(
    playmeshRoot,
    'overlays',
    'newIDE',
    'app',
    'src',
    'PlaymeshCatalog',
    'PlaymeshExtensionSourceLink.js'
  ),
  'utf8'
);
assert.match(componentSource, /value: extensionHeader\.url/);
assert.match(componentSource, /safeSource\.kind === 'external'/);
assert.match(componentSource, /Window\.openExternalURL\(safeSource\.url\)/);

const policySource = await readFile(
  path.join(playmeshRoot, 'scripts', 'apply-source-policy.mjs'),
  'utf8'
);
assert.match(
  policySource,
  /import PlaymeshExtensionSourceLink from '\.\.\/\.\.\/PlaymeshCatalog\/PlaymeshExtensionSourceLink';/
);
assert.match(
  policySource,
  /<PlaymeshExtensionSourceLink header=\{extensionShortHeader\} \/>/
);

const index = JSON.parse(
  await readFile(
    path.join(playmeshRoot, 'catalog', 'generated', 'extensions-index.json'),
    'utf8'
  )
);
assert.equal(index.headers.length, 219);
for (const header of index.headers) {
  const source = helper.getSafePlaymeshExtensionSourceUrl({
    value: header.url,
    baseUrl: 'http://127.0.0.1:8768/',
  });
  assert.equal(source && source.kind, 'external', header.name);
  assert.ok(source.url.includes(`/${index.source.commit}/`));
}

process.stdout.write('GDevelop existing extension source URL contracts passed.\n');
