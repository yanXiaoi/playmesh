import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const modulePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshCrypto/PlaymeshSha256.js'
);
const source = await readFile(modulePath, 'utf8');
const moduleUrl = `data:text/javascript;base64,${Buffer.from(source).toString(
  'base64'
)}`;
const { sha256Hex, sha256HexFallback } = await import(moduleUrl);

const encoder = new TextEncoder();
const vectors = [
  ['', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'],
  ['abc', 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'],
  [
    'The quick brown fox jumps over the lazy dog',
    'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
  ],
];

for (const [value, expected] of vectors) {
  const bytes = encoder.encode(value);
  assert.equal(sha256HexFallback(bytes), expected);
  assert.equal(await sha256Hex(bytes, {}), expected);
}

const large = new Uint8Array(1024 * 1024 + 13);
for (let index = 0; index < large.length; index++) {
  large[index] = (index * 31 + 17) & 0xff;
}
const expectedLarge = createHash('sha256').update(large).digest('hex');
assert.equal(await sha256Hex(large, {}), expectedLarge);

const offsetBacking = new Uint8Array([99, ...encoder.encode('abc'), 77]);
assert.equal(
  await sha256Hex(offsetBacking.subarray(1, 4), {}),
  vectors[1][1],
  'typed-array byteOffset and byteLength must be honored'
);

const directSubtleCalls = [
  '../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryEvidence.js',
  '../overlays/newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogRuntime.js',
  '../overlays/newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer.js',
  '../overlays/newIDE/app/src/PlaymeshProjects/PlaymeshProjectAllocationCoordinator.js',
  '../overlays/newIDE/app/src/PlaymeshAi/PlaymeshAiClient.js',
];
for (const relativePath of directSubtleCalls) {
  const content = await readFile(path.resolve(testDirectory, relativePath), 'utf8');
  assert.doesNotMatch(content, /(?:crypto|cryptoImplementation)\.subtle/);
  assert.match(content, /PlaymeshSha256/);
}

process.stdout.write(
  'LAN HTTP SHA-256 fallback and lowest-level hashing contracts passed.\n'
);
