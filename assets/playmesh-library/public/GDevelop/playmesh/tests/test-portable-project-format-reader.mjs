import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { transformFlow } from './test-webide-babel.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceDirectory = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshProjectImport'
);

const importSource = async source =>
  import(`data:text/javascript;base64,${Buffer.from(
    transformFlow(source),
    'utf8'
  ).toString('base64')}`);

const formatSource = await readFile(
  path.join(sourceDirectory, 'PlaymeshPortableProjectFormat.js'),
  'utf8'
);
const format = await importSource(formatSource);

const entry = (
  filename,
  uncompressedSize = 8,
  compressedSize = Math.max(1, Math.ceil(uncompressedSize / 2)),
  extra = {}
) => ({
  filename,
  uncompressedSize,
  compressedSize,
  directory: filename.endsWith('/'),
  ...extra,
});

const expectCode = (action, code) =>
  assert.throws(action, error => error && error.code === code);
const captureError = action => {
  try {
    action();
  } catch (error) {
    return error;
  }
  assert.fail('Expected the action to throw.');
};

assert.equal(
  format.normalizePortableProjectPath('assets/a.png'),
  'assets/a.png'
);
assert.equal(
  format.normalizePortableProjectPath('assets/', { directory: true }),
  'assets'
);
for (const unsafePath of [
  '',
  '/game.json',
  'C:/game.json',
  'assets/a:b.png',
  'javascript:resource',
  'assets\\a.png',
  'assets//a.png',
  './game.json',
  'assets/../game.json',
  'assets/\u0000.png',
]) {
  expectCode(
    () => format.normalizePortableProjectPath(unsafePath),
    'invalid_archive_path'
  );
}
expectCode(
  () => format.normalizePortableProjectPath('assets/', { directory: false }),
  'invalid_archive_path'
);
const pathLimitError = captureError(() =>
  format.normalizePortableProjectPath('abcdef', {
    limits: { maxPathLength: 5 },
  })
);
assert.equal(pathLimitError.code, 'archive_path_too_long');
assert.deepEqual(pathLimitError.details, {
  limitCode: 'maxPathLength',
  actual: 6,
  max: 5,
  path: 'abcdef',
});
expectCode(
  () => format.resolvePortableImportLimits({ maxArchiveBytes: 0 }),
  'invalid_import_limits'
);
assert.equal(
  format.resolvePortableImportLimits({ maxCompressionRatio: 1.5 })
    .maxCompressionRatio,
  1.5
);

const validEntries = [
  entry('assets/', 0, 0),
  entry('game.json', 64, 32),
  entry('assets/a.png', 12, 10),
];
const inspected = format.inspectPortableProjectEntries({
  archiveBytes: 100,
  entries: validEntries,
});
assert.deepEqual([...inspected.files.keys()], ['game.json', 'assets/a.png']);
assert.equal(inspected.limits.maxArchiveBytes, 100 * 1024 * 1024);

expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('folder/game.json')],
    }),
  'missing_project_json'
);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json'), entry('game.json')],
    }),
  'duplicate_archive_path'
);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json'), entry('Assets/a'), entry('assets/A')],
    }),
  'ambiguous_archive_path'
);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json', 8, 4, { encrypted: true })],
    }),
  'encrypted_archive_entry'
);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json'), entry('link', 1, 1, { unixMode: 0xa000 })],
    }),
  'symlink_archive_entry'
);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json', 8, 60), entry('asset.bin', 8, 60)],
    }),
  'invalid_archive_entry'
);

const archiveLimitError = captureError(() =>
  format.inspectPortableProjectEntries({
    archiveBytes: 11,
    entries: [entry('game.json')],
    limits: { maxArchiveBytes: 10 },
  })
);
assert.equal(archiveLimitError.code, 'archive_too_large');
assert.deepEqual(archiveLimitError.details, {
  limitCode: 'maxArchiveBytes',
  actual: 11,
  max: 10,
});
const ratioLimitError = captureError(() =>
  format.inspectPortableProjectEntries({
    archiveBytes: 100,
    entries: [entry('game.json', 2048, 1)],
    limits: { maxCompressionRatio: 10 },
  })
);
assert.equal(ratioLimitError.code, 'suspicious_compression_ratio');
assert.equal(ratioLimitError.details.limitCode, 'maxCompressionRatio');
assert.equal(ratioLimitError.details.actual, 2048);
assert.equal(ratioLimitError.details.max, 10);
expectCode(
  () =>
    format.inspectPortableProjectEntries({
      archiveBytes: 100,
      entries: [entry('game.json', 10), entry('asset.bin', 20)],
      limits: { maxSingleResourceBytes: 19 },
    }),
  'resource_too_large'
);

const encoder = new TextEncoder();
assert.deepEqual(
  format.parsePortableProjectJson(
    encoder.encode(JSON.stringify({ gdVersion: { major: 5 }, properties: {} }))
  ),
  { gdVersion: { major: 5 }, properties: {} }
);
expectCode(
  () => format.parsePortableProjectJson(new Uint8Array([0xc3, 0x28])),
  'invalid_project_json'
);
expectCode(
  () => format.parsePortableProjectJson(encoder.encode('[]')),
  'invalid_project_json'
);
expectCode(
  () =>
    format.parsePortableProjectJson(
      encoder.encode(JSON.stringify({ eventsFunctions: [] }))
    ),
  'extension_document'
);
expectCode(
  () =>
    format.parsePortableProjectJson(
      encoder.encode(
        JSON.stringify({
          gdVersion: {},
          external: { __REFERENCE_TO_SPLIT_OBJECT: 'file.json' },
        })
      )
    ),
  'split_project_not_supported'
);
expectCode(
  () =>
    format.parsePortableProjectJson(
      encoder.encode(JSON.stringify({ gdVersion: {}, nested: { value: 1 } })),
      { maxJsonDepth: 1 }
    ),
  'project_json_too_deep'
);

const resourcePlan = format.planPortableProjectResources({
  inspectedArchive: inspected,
  projectResources: [
    { name: 'A', file: 'assets/a.png' },
    { name: 'A-copy', file: 'assets/a.png' },
    { name: 'Remote', file: 'HTTPS://example.invalid/image.png' },
  ],
});
assert.equal(resourcePlan.localFiles.length, 1);
assert.deepEqual(
  resourcePlan.localFiles[0].resources.map(resource => resource.name),
  ['A', 'A-copy']
);
assert.equal(resourcePlan.externalResources.length, 1);
expectCode(
  () =>
    format.planPortableProjectResources({
      inspectedArchive: inspected,
      projectResources: [{ name: 'Missing', file: 'assets/missing.png' }],
    }),
  'missing_resource'
);
expectCode(
  () =>
    format.planPortableProjectResources({
      inspectedArchive: inspected,
      projectResources: [{ name: 'Session', file: 'blob:fixture' }],
    }),
  'session_resource_url'
);
expectCode(
  () =>
    format.planPortableProjectResources({
      inspectedArchive: inspected,
      projectResources: [],
    }),
  'unexpected_archive_file'
);

globalThis.__portableFormatForReaderTest = format;
let readerSource = await readFile(
  path.join(sourceDirectory, 'PlaymeshPortableZipReader.js'),
  'utf8'
);
readerSource = readerSource
  .replace(/^\/\/ @flow\s*/, '')
  .replace(
    /import \{ initializeZipJs \} from ["'][^"']+["'];/,
    'const initializeZipJs = () => { throw new Error("unexpected initializer"); };'
  )
  .replace(
    /import \{[\s\S]*?\} from ["']\.\/PlaymeshPortableProjectFormat["'];/,
    `const {
  inspectPortableProjectEntries,
  PlaymeshProjectImportError,
} = globalThis.__portableFormatForReaderTest;`
  );
const reader = await importSource(readerSource);

const makeZipJs = ({ fixtureEntries, bodies, onRead = () => {} }) => {
  let closeCount = 0;
  const preparedEntries = fixtureEntries.map(metadata => ({
    ...metadata,
    getData(writer, onend, _onprogress, checkCrc32) {
      onRead(metadata.filename, checkCrc32);
      const body = bodies.get(metadata.filename) || new Uint8Array();
      const onerror = error => {
        throw error;
      };
      writer.init(
        () =>
          writer.writeUint8Array(
            body,
            () => writer.getData(onend, onerror),
            onerror
          ),
        onerror
      );
    },
  }));
  return {
    BlobReader: class BlobReader {
      constructor(blob) {
        this.blob = blob;
      }
    },
    createReader(_blobReader, onready) {
      onready({
        getEntries: callback => callback(preparedEntries),
        close: callback => {
          closeCount++;
          if (callback) callback();
        },
      });
    },
    get closeCount() {
      return closeCount;
    },
  };
};

const gameBody = new Uint8Array([1, 2, 3]);
const assetBody = new Uint8Array([4, 5]);
const reads = [];
const zipJs = makeZipJs({
  fixtureEntries: [
    entry('game.json', gameBody.byteLength, gameBody.byteLength),
    entry('assets/a.png', assetBody.byteLength, assetBody.byteLength),
  ],
  bodies: new Map([['game.json', gameBody], ['assets/a.png', assetBody]]),
  onRead: (filename, checkCrc32) => reads.push({ filename, checkCrc32 }),
});
const archive = await reader.openPlaymeshPortableZip(
  new Blob(['zip-archive']),
  {
    zipJs,
  }
);
const extracted = await archive.readBlob({
  path: 'game.json',
  contentType: 'application/json',
  maxBytes: 10,
});
assert.deepEqual(new Uint8Array(await extracted.arrayBuffer()), gameBody);
assert.deepEqual(reads, [{ filename: 'game.json', checkCrc32: true }]);
await assert.rejects(
  archive.readBlob({
    path: 'missing',
    contentType: 'application/octet-stream',
    maxBytes: 10,
  }),
  error => error.code === 'missing_archive_entry'
);
await archive.close();
assert.equal(zipJs.closeCount, 1);

const mismatchZipJs = makeZipJs({
  fixtureEntries: [entry('game.json', 2, 2)],
  bodies: new Map([['game.json', new Uint8Array([1])]]),
});
const mismatchArchive = await reader.openPlaymeshPortableZip(
  new Blob(['zip']),
  { zipJs: mismatchZipJs }
);
await assert.rejects(
  mismatchArchive.readBlob({
    path: 'game.json',
    contentType: 'application/json',
    maxBytes: 2,
  }),
  error => error.code === 'expanded_entry_size_mismatch'
);
await mismatchArchive.close();

const oversizedZipJs = makeZipJs({
  fixtureEntries: [entry('game.json', 2, 2)],
  bodies: new Map([['game.json', new Uint8Array([1, 2, 3])]]),
});
const oversizedArchive = await reader.openPlaymeshPortableZip(
  new Blob(['zip']),
  { zipJs: oversizedZipJs }
);
await assert.rejects(
  oversizedArchive.readBlob({
    path: 'game.json',
    contentType: 'application/json',
    maxBytes: 2,
  }),
  error =>
    error.code === 'expanded_entry_too_large' &&
    error.details.limitCode === 'entryActualBytes' &&
    error.details.actual === 3 &&
    error.details.max === 2
);
await oversizedArchive.close();

await assert.rejects(
  reader.openPlaymeshPortableZip(new Blob(['1234']), {
    zipJs,
    limits: { maxArchiveBytes: 3 },
  }),
  error =>
    error.code === 'archive_too_large' &&
    error.details.limitCode === 'maxArchiveBytes'
);

await assert.rejects(
  reader.openPlaymeshPortableZip(new Blob(['zip']), {
    zipJs: {
      BlobReader: class BlobReader {},
      createReader() {
        throw new Error('synchronous ZIP open failure');
      },
    },
  }),
  error => error.code === 'invalid_zip'
);

delete globalThis.__portableFormatForReaderTest;
process.stdout.write('GDevelop portable project format/reader tests passed.\n');
