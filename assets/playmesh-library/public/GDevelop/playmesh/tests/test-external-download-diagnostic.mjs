import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const catalogRoot = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshCatalog'
);
let diagnosticSource = await readFile(
  path.join(catalogRoot, 'PlaymeshExternalDownloadDiagnostic.js'),
  'utf8'
);
const presenterSource = await readFile(
  path.join(catalogRoot, 'PlaymeshExternalDownloadErrorPresenter.js'),
  'utf8'
);
const runtimeSource = await readFile(
  path.join(catalogRoot, 'PlaymeshCatalogRuntime.js'),
  'utf8'
);

diagnosticSource = diagnosticSource
  .replace(/^\/\/ @flow\s*/, '')
  .replace(/type MixedRecord = \{[^\n]+\};\s*/, '')
  .replace(/export type PlaymeshExternalDownloadFailure = \{\|[\s\S]*?\|\};\s*/, '')
  .replace(/\(value: any\)/g, 'value')
  .replace(
    'const recordOf = (value: mixed): ?MixedRecord =>',
    'const recordOf = value =>'
  )
  .replace(
    'const boundedField = (value: mixed, fallback: string): string =>',
    'const boundedField = (value, fallback) =>'
  )
  .replace(
    'export const sanitizePlaymeshExternalUrl = (value: mixed): string =>',
    'export const sanitizePlaymeshExternalUrl = value =>'
  )
  .replace(
    /\}: \{\|[\s\S]*?\|\}\): PlaymeshExternalDownloadFailure =>/,
    '}) =>'
  )
  .replace(
    /\(\s*intro: string,\s*failure: PlaymeshExternalDownloadFailure\s*\): string =>/,
    '(intro, failure) =>'
  )
  .replace(
    /\(\s*failure: PlaymeshExternalDownloadFailure\s*\): void =>/,
    'failure =>'
  );

const diagnostic = await import(
  `data:text/javascript;base64,${Buffer.from(diagnosticSource).toString(
    'base64'
  )}`
);

assert.equal(
  diagnostic.sanitizePlaymeshExternalUrl(
    'https://user:password@example.com/file.zip?page=2&TOKEN=secret&filter=stable&x-amz-signature=signed#fragment'
  ),
  'https://example.com/file.zip?page=2&filter=stable'
);
assert.equal(
  diagnostic.sanitizePlaymeshExternalUrl(
    'https://example.com/body.json?lang=zh-CN&API_KEY=secret&cursor=next'
  ),
  'https://example.com/body.json?lang=zh-CN&cursor=next'
);
assert.equal(
  diagnostic.sanitizePlaymeshExternalUrl('file:///private/token.txt'),
  ''
);

const failure = diagnostic.normalizePlaymeshExternalDownloadFailure({
  rawError: {
    code: 'gateway_download_failed',
    status: 502,
    requestId: 'dev-fixture',
    operation: 'gdevelop.catalog.artifact.acquire',
    stage: 'artifact_download',
    reason: 'upstream_http_error',
    targetUrl:
      'https://example.com/body.json?part=1&authorization=secret#private',
  },
});
assert.deepEqual(failure, {
  targetUrl: 'https://example.com/body.json?part=1',
  stage: 'artifact_download',
  status: 502,
  code: 'gateway_download_failed',
  reason: 'upstream_http_error',
  requestId: 'dev-fixture',
  operation: 'gdevelop.catalog.artifact.acquire',
});
assert.match(
  diagnostic.formatPlaymeshExternalDownloadFailure('Download failed.', failure),
  /URL: https:\/\/example\.com\/body\.json\?part=1[\s\S]*stage=artifact_download status=502[\s\S]*requestId=dev-fixture/
);

assert.match(presenterSource, /showErrorBox\(\{/);
assert.match(presenterSource, /doNotReport: true/);
assert.match(presenterSource, /new Error\([\s\S]*failure\.requestId/);
assert.doesNotMatch(presenterSource, /rawError:\s*rawError/);
assert.match(runtimeSource, /targetUrl: artifact\.url/);
assert.match(runtimeSource, /reason: responseReason/);

process.stdout.write('PlayMesh external download diagnostic contracts passed.\n');
