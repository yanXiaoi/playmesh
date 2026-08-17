import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const sourceIndex = process.argv.indexOf('--source');
const sourceRoot =
  sourceIndex === -1 ? '' : path.resolve(process.argv[sourceIndex + 1] || '');
if (!sourceRoot) {
  throw new Error(
    'Usage: node test-behavior-install-catalog-contract.mjs --source <patched GDevelop root>'
  );
}

const [installExtension, catalog, newBehaviorDialog, catalogSource] = await Promise.all([
  readFile(
    path.join(
      sourceRoot,
      'newIDE',
      'app',
      'src',
      'AssetStore',
      'ExtensionStore',
      'InstallExtension.js'
    ),
    'utf8'
  ),
  readFile(
    path.join(
      playmeshDirectory,
      'catalog',
      'generated',
      'extensions-index.json'
    ),
    'utf8'
  ).then(JSON.parse),
  readFile(
    path.join(
      sourceRoot,
      'newIDE',
      'app',
      'src',
      'BehaviorsEditor',
      'NewBehaviorDialog.js'
    ),
    'utf8'
  ),
  readFile(
    path.join(
      sourceRoot,
      'newIDE',
      'app',
      'src',
      'PlaymeshCatalog',
      'PlaymeshCatalogSource.js'
    ),
    'utf8'
  ),
]);

const extensionHeadersByName = new Map(
  catalog.headers.map(header => [header.name, header])
);
assert.ok(extensionHeadersByName.size > 0, 'extension catalog must not be empty');
assert.ok(
  catalog.behavior.headers.length > 0,
  'behavior catalog must not be empty'
);

let behaviorWithDifferentOwnerNameCount = 0;
let behaviorWithExtensionDependencyCount = 0;
for (const behavior of catalog.behavior.headers) {
  if (behavior.name !== behavior.extensionName) {
    behaviorWithDifferentOwnerNameCount++;
  }

  const ownerHeader = extensionHeadersByName.get(behavior.extensionName);
  assert.ok(
    ownerHeader,
    `behavior ${behavior.name} owner ${behavior.extensionName} is missing`
  );
  assert.deepEqual(
    behavior.requiredExtensions || [],
    ownerHeader.requiredExtensions || [],
    `behavior ${behavior.extensionName}:${behavior.name} must carry its owning extension dependencies`
  );

  const pendingHeaders = [ownerHeader];
  const visited = new Set();
  while (pendingHeaders.length > 0) {
    const header = pendingHeaders.shift();
    if (visited.has(header.name)) continue;
    visited.add(header.name);

    assert.equal(
      typeof header.artifactId,
      'string',
      `extension ${header.name} has no body artifact id`
    );
    const artifact = catalog.artifacts[header.artifactId];
    assert.ok(artifact, `extension ${header.name} body artifact is missing`);
    assert.equal(artifact.id, header.artifactId);
    assert.equal(artifact.kind, 'extension');
    assert.equal(artifact.repository, catalog.source.repository);
    assert.equal(artifact.commit, catalog.source.commit);
    assert.equal(artifact.rootTreeSha, catalog.source.rootTreeSha);
    assert.match(artifact.sha256, /^[a-f0-9]{64}$/);

    for (const dependency of header.requiredExtensions || []) {
      behaviorWithExtensionDependencyCount++;
      const dependencyHeader = extensionHeadersByName.get(
        dependency.extensionName
      );
      assert.ok(
        dependencyHeader,
        `extension ${header.name} dependency ${dependency.extensionName} is missing`
      );
      pendingHeaders.push(dependencyHeader);
    }
  }
}

assert.ok(
  behaviorWithDifferentOwnerNameCount > 0,
  'fixture must cover behavior names that differ from their owning extension'
);
assert.ok(
  behaviorWithExtensionDependencyCount > 0,
  'fixture must cover behavior owner dependency traversal'
);

assert.match(newBehaviorDialog, /await getExtensionsRegistry\(\)/);
assert.match(
  newBehaviorDialog,
  /installExtensionShortHeadersByName\[extensionShortHeader\.name\]/
);
assert.match(
  newBehaviorDialog,
  /extensionShortHeadersByName:\s*installExtensionShortHeadersByName/
);
assert.match(
  newBehaviorDialog,
  /getExtensionHeader\(\s*installExtensionShortHeadersByName,\s*behaviorShortHeader\.extensionName/
);
assert.match(newBehaviorDialog, /presentPlaymeshExternalDownloadFailure/);
assert.match(newBehaviorDialog, /stage: 'behavior_extension_download'/);
assert.match(installExtension, /presentPlaymeshExternalDownloadFailure/);
assert.match(installExtension, /reason === 'behavior'/);
assert.match(installExtension, /stage:\s*reason === 'behavior'/);
assert.match(installExtension, /if \(reason === 'asset'\) throw rawError/);
assert.match(catalogSource, /const resolveCatalogExtensionName =/);
assert.match(
  catalogSource,
  /'extensionName' in header && header\.extensionName\s*\? header\.extensionName\s*:\s*header\.name/
);

process.stdout.write(
  `GDevelop behavior install owner/dependency/body contract passed for ${
    catalog.behavior.headers.length
  } behaviors.\n`
);
