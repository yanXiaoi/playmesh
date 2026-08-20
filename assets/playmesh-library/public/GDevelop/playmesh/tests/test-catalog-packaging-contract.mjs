import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmesh = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const read = relative => readFile(path.join(playmesh, ...relative.split('/')), 'utf8');
const readRepository = relative =>
  readFile(path.join(repositoryRoot, ...relative.split('/')), 'utf8');
const [
  generator,
  prepare,
  prepareDevelopment,
  packageRelease,
  pipeline,
  layoutVerifier,
  catalogSource,
  developerHttpSupport,
  pubspec,
  verifier,
  lock,
] = await Promise.all([
  read('scripts/generate-catalog.mjs'),
  read('scripts/prepare-webide.mjs'),
  read('scripts/prepare-dev-webide.mjs'),
  read('scripts/package-webide-release.mjs'),
  read('scripts/webide-pipeline.mjs'),
  read('scripts/verify-layout.mjs'),
  read('overlays/newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogSource.js'),
  readRepository(
    'lib/core/developer/operations/infrastructure/developer_http_support.dart'
  ),
  readRepository('pubspec.yaml'),
  read('scripts/catalog-verifier-lib.mjs'),
  read('catalog-lock.json').then(JSON.parse),
]);

assert.equal(lock.sources.extensions.commit.length, 40);
assert.equal(lock.sources.examples.commit.length, 40);
assert.match(generator, /extensions-manifest\.v1\.json/);
assert.match(generator, /examples-manifest\.v1\.json/);
assert.match(generator, /contentSha256ByPath/);
assert.match(generator, /verifyGeneratedCatalogDirectory\(stagingDirectory\)/);
assert.match(prepare, /verifyGeneratedCatalogDirectory/);
assert.match(layoutVerifier, /playmesh\/extensions\/index\.json/);
assert.match(
  catalogSource,
  /['"]\/playmesh\/GDevelop\/playmesh\/extensions\/['"]/,
  'the WebIDE must load the local extension index from the public Library route'
);
assert.match(catalogSource, /LOCAL_EXTENSION_INDEX_PATH/);
assert.doesNotMatch(catalogSource, /Playmesh\.json/);
assert.match(developerHttpSupport, /route\.substring\('\/playmesh\/'.length\)/);
assert.match(
  developerHttpSupport,
  /assets\/playmesh-library\/public\/\$relativePath/
);
assert.match(
  pubspec,
  /assets\/playmesh-library\/public\/GDevelop\/playmesh\/extensions\//
);
for (const source of [generator, prepare, prepareDevelopment, packageRelease, pipeline]) {
  assert.doesNotMatch(
    source,
    /(?:canonicalExtensionsDirectory|playmesh\/extensions\/Playmesh\.json|GDevelop\/playmesh\/extensions\/Playmesh\.json)/,
    'the canonical extension body must not be copied into or bound to the WebIDE package pipeline'
  );
}
assert.doesNotMatch(
  generator,
  /playmesh[\\/]extensions[\\/]Playmesh\.json/,
  'the bundled Playmesh extension must stay outside the generated official catalog'
);
assert.match(verifier, /不包含资产商店|包含资产商店/);
assert.match(verifier, /exact commit\/path\/sha\/size/);

process.stdout.write('GDevelop catalog generation/package gate contract passed.\n');
