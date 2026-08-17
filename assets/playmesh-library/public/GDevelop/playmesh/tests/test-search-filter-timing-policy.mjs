import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshRoot = path.resolve(testDirectory, '..');
const [policy, outputContract] = await Promise.all([
  readFile(path.join(playmeshRoot, 'scripts/apply-source-policy.mjs'), 'utf8'),
  readFile(
    path.join(testDirectory, 'test-resource-editor-source-contract.mjs'),
    'utf8'
  ),
]);

const plainTimingMessage =
  'Filtered items by category/filters in \\${totalTime.toFixed(3)}ms.';
const structuredTimingMessage =
  'Filtered items by category/filters/tier in \\${totalTime.toFixed(3)}ms.';

assert.equal(
  policy.split(plainTimingMessage).length - 1,
  1,
  'the non-structured filter timing call must have one exact removal rule'
);
assert.equal(
  policy.split(structuredTimingMessage).length - 1,
  1,
  'the structured filter timing call must keep its exact removal rule'
);
assert.match(
  policy,
  /silence search item filtering timing info while preserving errors/
);
assert.match(policy, /silence structured search filtering timing info/);
assert.match(
  outputContract,
  /UseSearchItem\.js[\s\S]*?category\\\/filters in/,
  'the output contract must cover category/filters'
);
assert.match(
  outputContract,
  /UseSearchStructuredItem\.js[\s\S]*?category\\\/filters\\\/tier in/,
  'the output contract must cover category/filters/tier'
);
assert.equal(
  outputContract.split(
    "console\\.error\\('Error while indexing items: ', error\\)"
  ).length - 1,
  2,
  'both search hooks must retain their error diagnostic contract'
);

process.stdout.write('Search filter timing source-policy contracts passed.\n');
