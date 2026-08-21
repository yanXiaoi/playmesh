import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const extensionPath = path.join(
  playmeshDirectory,
  'extensions',
  'Playmesh.json'
);
const generatorPath = path.join(
  playmeshDirectory,
  'scripts',
  'generate-playmesh-extension.mjs'
);
const brandIconPath = path.join(
  repositoryRoot,
  'assets',
  'playmesh-library',
  'public',
  'developer',
  'playmesh-logo.png'
);

const [extensionSource, brandIconBytes] = await Promise.all([
  readFile(extensionPath, 'utf8'),
  readFile(brandIconPath),
]);
const extension = JSON.parse(extensionSource);
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

assert.ok(
  brandIconBytes.length >= 1024 && brandIconBytes.length <= 256 * 1024,
  'the extension icon must be a useful but bounded brand image'
);
assert.deepEqual(brandIconBytes.subarray(0, 8), pngSignature);
assert.equal(brandIconBytes.readUInt32BE(8), 13, 'PNG IHDR length');
assert.equal(brandIconBytes.subarray(12, 16).toString('ascii'), 'IHDR');
assert.equal(brandIconBytes.readUInt32BE(16), 256, 'brand icon width');
assert.equal(brandIconBytes.readUInt32BE(20), 256, 'brand icon height');
assert.equal(brandIconBytes[24], 8, 'brand icon bit depth');
assert.equal(brandIconBytes[25], 6, 'brand icon must be RGBA');
assert.notDeepEqual(
  [brandIconBytes.readUInt32BE(16), brandIconBytes.readUInt32BE(20)],
  [1, 1],
  'a one-pixel placeholder is not a usable extension icon'
);

const expectedDataUri =
  `data:image/png;base64,${brandIconBytes.toString('base64')}`;
assert.equal(
  extension.iconUrl,
  expectedDataUri,
  'iconUrl must embed the current public Playmesh brand derivative byte-for-byte'
);
assert.equal(
  extension.previewIconUrl,
  expectedDataUri,
  'previewIconUrl must embed the current public Playmesh brand derivative byte-for-byte'
);
assert.equal(extension.iconUrl, extension.previewIconUrl);

const dataUriMatch =
  /^data:image\/png;base64,([A-Za-z0-9+/]+={0,2})$/u.exec(extension.iconUrl);
assert.ok(dataUriMatch, 'the local catalog accepts a strict inline PNG data URI');
const decodedIconBytes = Buffer.from(dataUriMatch[1], 'base64');
assert.equal(
  decodedIconBytes.toString('base64'),
  dataUriMatch[1],
  'the icon must use canonical base64 without ignored characters'
);
assert.deepEqual(decodedIconBytes, brandIconBytes);

const generatorCheck = spawnSync(
  process.execPath,
  [generatorPath, '--check'],
  {
    cwd: repositoryRoot,
    encoding: 'utf8',
    windowsHide: true,
  }
);
assert.equal(
  generatorCheck.status,
  0,
  `extension generator check failed:\n${generatorCheck.stdout || ''}${
    generatorCheck.stderr || ''
  }`
);

process.stdout.write(
  'Playmesh extension uses the current 256x256 inline PNG brand icon.\n'
);
