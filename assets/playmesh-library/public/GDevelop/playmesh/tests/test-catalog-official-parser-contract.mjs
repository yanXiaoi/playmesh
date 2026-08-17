import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const sourceIndex = process.argv.indexOf('--source');
const source = sourceIndex === -1 ? '' : path.resolve(process.argv[sourceIndex + 1] || '');
if (!source) {
  throw new Error('Usage: node test-catalog-official-parser-contract.mjs --source <patched GDevelop root>');
}

const read = relative => readFile(path.join(source, ...relative.split('/')), 'utf8');
const [extensionService, officialInstaller, runtime, catalogSource] = await Promise.all([
  read('newIDE/app/src/Utils/GDevelopServices/Extension.js'),
  read('newIDE/app/src/AssetStore/ExtensionStore/InstallExtension.js'),
  read('newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogRuntime.js'),
  read('newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogSource.js'),
]);

assert.match(extensionService, /getPlaymeshExtension/);
assert.match(catalogSource, /const resolveCatalogExtensionName =/);
assert.equal(
  (catalogSource.match(/candidate\.name === extensionName/g) || []).length,
  2,
  'behavior/object headers must resolve their owning extension for both details and body downloads'
);
assert.match(officialInstaller, /gd\.Serializer\.fromJSObject\(\s*serializedExtensions\s*\)/);
assert.match(officialInstaller, /project\.unserializeAndInsertExtensionsFrom/);
assert.doesNotMatch(catalogSource, /unserializeAndInsertExtensionsFrom/);
assert.match(runtime, /\/dev\/api\/gdevelop\/catalog\/artifact/);
assert.doesNotMatch(runtime, /fetchWithRetry\(\{\s*url:\s*validatedArtifact\.url/);

process.stdout.write(
  'GDevelop catalog Gateway transport and official extension parser contract passed.\n'
);
