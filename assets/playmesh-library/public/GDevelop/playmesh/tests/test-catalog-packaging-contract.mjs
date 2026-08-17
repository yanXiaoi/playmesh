import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmesh = path.resolve(testDirectory, '..');
const read = relative => readFile(path.join(playmesh, ...relative.split('/')), 'utf8');
const [generator, prepare, verifier, lock] = await Promise.all([
  read('scripts/generate-catalog.mjs'),
  read('scripts/prepare-webide.mjs'),
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
assert.match(verifier, /不包含资产商店|包含资产商店/);
assert.match(verifier, /exact commit\/path\/sha\/size/);

process.stdout.write('GDevelop catalog generation/package gate contract passed.\n');
