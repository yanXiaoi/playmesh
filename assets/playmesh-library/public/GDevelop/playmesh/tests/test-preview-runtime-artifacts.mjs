import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const sourceIndex = process.argv.indexOf('--source');
const source =
  sourceIndex === -1
    ? ''
    : path.resolve(process.argv[sourceIndex + 1] || '');
if (!source) {
  throw new Error(
    'Usage: node test-preview-runtime-artifacts.mjs --source <patched GDevelop root>'
  );
}

const archiver = await readFile(
  path.join(
    source,
    'newIDE',
    'app',
    'src',
    'Utils',
    'BrowserArchiver.js'
  ),
  'utf8'
);
const previewPackage = await readFile(
  path.join(
    source,
    'newIDE',
    'app',
    'src',
    'PlaymeshPreview',
    'PlaymeshGatewayPreviewPackage.js'
  ),
  'utf8'
);
const exporterHelper = await readFile(
  path.join(source, 'GDJS', 'GDJS', 'IDE', 'ExporterHelper.cpp'),
  'utf8'
);

assert.match(archiver, /!filePath\.endsWith\('\.map'\)/);
assert.match(archiver, /!urlPath\.endsWith\('\.map'\)/);
assert.match(archiver, /url\.indexOf\('\.h'\) === -1/);
assert.doesNotMatch(
  archiver,
  /if \(!response\.ok\).*return|erroredUrls\.length\s*===\s*0/,
  'only source maps may be optional; other missing runtime files must still fail preview'
);

assert.match(
  previewPackage,
  /setNonRuntimeScriptsCacheBurst\(0\)/,
  'DeveloperRun preview must preserve generated data.js/codeN.js physical filenames'
);
assert.doesNotMatch(
  previewPackage,
  /setNonRuntimeScriptsCacheBurst\(Date\.now\(\)\)/,
  'a query cache burst makes BrowserFileSystem omit every generated absolute include from index.html'
);
const completeIndexStart = exporterHelper.indexOf(
  'bool ExporterHelper::CompleteIndexFile('
);
const includeResolverStart = exporterHelper.indexOf(
  'gd::String ExporterHelper::GetExportedIncludeFilename('
);
assert.ok(completeIndexStart !== -1 && includeResolverStart !== -1);
const completeIndexSource = exporterHelper.slice(
  completeIndexStart,
  includeResolverStart
);
assert.ok(
  completeIndexSource.indexOf('GetExportedIncludeFilename(') <
    completeIndexSource.indexOf('fs.FileExists(absoluteFilename)'),
  'the pinned exporter resolves cache-busted include names before checking BrowserFileSystem existence'
);
const includeResolverSource = exporterHelper.slice(includeResolverStart);
assert.match(
  includeResolverSource,
  /if \(nonRuntimeScriptsCacheBurst == 0\) \{\s*return resolvedInclude;\s*\}/,
  'zero is the pinned exporter contract for retaining data.js and all codeN.js filenames'
);

process.stdout.write(
  'GDevelop preview/publish runtime artifact and generated-script filename contracts passed.\n'
);
