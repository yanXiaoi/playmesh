import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  collectStaticModuleExports,
  parseStaticImportClause,
  verifyStaticModuleImportContract,
} from '../scripts/source-policy-verifier-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const fixtures = JSON.parse(
  await readFile(
    path.join(testDirectory, 'fixtures', 'source-policy-module-contracts.json'),
    'utf8'
  )
);

for (const fixture of fixtures.positive) {
  const result = verifyStaticModuleImportContract({
    importClause: fixture.importClause,
    moduleSource: fixture.moduleSource,
  });
  assert.equal(result.missingDefault, false, fixture.name);
  assert.deepEqual(result.missingNamed, [], fixture.name);
}

for (const fixture of fixtures.negative) {
  const result = verifyStaticModuleImportContract({
    importClause: fixture.importClause,
    moduleSource: fixture.moduleSource,
  });
  assert.equal(result.missingDefault, fixture.missingDefault, fixture.name);
  assert.deepEqual(result.missingNamed, fixture.missingNamed, fixture.name);
}

assert.deepEqual(parseStaticImportClause('type { ProjectShape }'), {
  declarationKind: 'type',
  defaultImport: null,
  namespaceImport: null,
  namedImports: [
    {
      importedName: 'ProjectShape',
      localName: 'ProjectShape',
      importKind: 'value',
    },
  ],
});
assert.deepEqual(parseStaticImportClause('typeof RuntimeConstructor'), {
  declarationKind: 'typeof',
  defaultImport: 'RuntimeConstructor',
  namespaceImport: null,
  namedImports: [],
});
assert.deepEqual(
  parseStaticImportClause('{ type ProjectShape, typeof RuntimeValue }')
    .namedImports,
  [
    {
      importedName: 'ProjectShape',
      localName: 'ProjectShape',
      importKind: 'type',
    },
    {
      importedName: 'RuntimeValue',
      localName: 'RuntimeValue',
      importKind: 'typeof',
    },
  ]
);
assert.deepEqual(
  collectStaticModuleExports(
    'const implementation = value => value; module.exports = { mapVector: implementation };'
  ),
  {
    hasDefaultExport: true,
    namedExports: ['mapVector'],
    usesCommonJs: true,
  }
);

const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex !== -1) {
  const sourceArgument = process.argv[sourceArgumentIndex + 1];
  if (!sourceArgument) {
    throw new Error('--source requires a patched GDevelop source root');
  }
  const sourceRoot = path.resolve(sourceArgument);
  const canonicalAiDirectory = path.join(
    playmeshDirectory,
    'overlays',
    'newIDE',
    'app',
    'src',
    'PlaymeshAi'
  );
  const sourceAiDirectory = path.join(
    sourceRoot,
    'newIDE',
    'app',
    'src',
    'PlaymeshAi'
  );
  const walkFiles = async directory => {
    const files = [];
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isDirectory()) files.push(...(await walkFiles(entryPath)));
      else if (entry.isFile()) files.push(entryPath);
    }
    return files;
  };
  const readRelativeModule = async (importerPath, specifier) => {
    const modulePath = path.resolve(path.dirname(importerPath), specifier);
    for (const candidate of [
      modulePath,
      `${modulePath}.js`,
      `${modulePath}.jsx`,
      path.join(modulePath, 'index.js'),
      path.join(modulePath, 'index.jsx'),
    ]) {
      try {
        return { path: candidate, source: await readFile(candidate, 'utf8') };
      } catch (error) {
        if (error && (error.code === 'ENOENT' || error.code === 'EISDIR')) {
          continue;
        }
        throw error;
      }
    }
    throw new Error(
      `Unable to resolve ${JSON.stringify(specifier)} from ${importerPath}`
    );
  };

  const errors = [];
  let checkedImports = 0;
  let checkedTypeImports = 0;
  let checkedCommonJsImports = 0;
  const importPattern = /\bimport\s+([^;]+?)\s+from\s+['"](\.\.\/[^'"]+)['"]\s*;/g;
  for (const canonicalImporterPath of await walkFiles(canonicalAiDirectory)) {
    if (!/\.jsx?$/.test(canonicalImporterPath)) continue;
    const relativeImporterPath = path.relative(
      canonicalAiDirectory,
      canonicalImporterPath
    );
    const sourceImporterPath = path.join(
      sourceAiDirectory,
      relativeImporterPath
    );
    const importerSource = await readFile(canonicalImporterPath, 'utf8');
    for (const match of importerSource.matchAll(importPattern)) {
      const [, importClause, specifier] = match;
      const target = await readRelativeModule(sourceImporterPath, specifier);
      const contract = verifyStaticModuleImportContract({
        importClause,
        moduleSource: target.source,
      });
      if (contract.missingDefault) {
        errors.push(
          `${relativeImporterPath} imports a missing default from ${specifier}`
        );
      }
      for (const missingName of contract.missingNamed) {
        errors.push(
          `${relativeImporterPath} imports missing named ${missingName} from ${specifier}`
        );
      }
      if (
        contract.parsedImport.declarationKind !== 'value' ||
        contract.parsedImport.namedImports.some(
          binding => binding.importKind !== 'value'
        )
      ) {
        checkedTypeImports += 1;
      }
      if (contract.moduleExports.usesCommonJs) checkedCommonJsImports += 1;
      checkedImports += 1;
    }
  }
  assert.ok(checkedImports > 0, 'no real GDevelop imports were checked');
  assert.ok(checkedTypeImports > 0, 'no real Flow type imports were checked');
  assert.ok(
    checkedCommonJsImports > 0,
    'no real CommonJS module imports were checked'
  );
  assert.deepEqual(errors, [], errors.join('\n'));
  process.stdout.write(
    `Verified ${checkedImports} real pinned GDevelop module contracts (${checkedTypeImports} Flow type imports, ${checkedCommonJsImports} CommonJS imports).\n`
  );
}

process.stdout.write(
  `Verified ${fixtures.positive.length} positive and ${
    fixtures.negative.length
  } negative static module contract fixtures.\n`
);
