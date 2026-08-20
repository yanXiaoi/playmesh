import { access, readFile, readdir, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  assertManifestMatchesWebIdeLock,
  listRegularFiles,
  loadSourcePolicyOutputManifest,
  verifyOverlayTreeDigest,
  verifyOutputManifestFreezeState,
} from './source-policy-verifier-lib.mjs';
import { classifyPlaymeshTestFiles } from './layout-verifier-lib.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const gdevelopDirectory = path.resolve(playmeshDirectory, '..');

const requiredInfrastructureFiles = [
  'official/LICENSE.md',
  'playmesh/README.md',
  'playmesh/webide-lock.json',
  'playmesh/source-policy-output-manifest.json',
  'playmesh/service-policy.json',
  'playmesh/catalog-lock.json',
  'playmesh/catalog/README.md',
  'playmesh/catalog/generated/catalog-manifest.json',
  'playmesh/catalog/generated/extensions-index.json',
  'playmesh/catalog/generated/examples-index.json',
  'playmesh/runtime/host-policy.js',
  'playmesh/runtime/host-policy.css',
  '../developer/gdevelop-authority-bootstrap.js',
  '../developer/gdevelop-multiplayer-bridge.js',
  'playmesh/scripts/apply-source-policy.mjs',
  'playmesh/scripts/layout-verifier-lib.mjs',
  'playmesh/scripts/source-policy-verifier-lib.mjs',
  'playmesh/scripts/fetch-catalog-sources.mjs',
  'playmesh/scripts/generate-catalog.mjs',
  'playmesh/scripts/prepare-dev-webide.mjs',
  'playmesh/scripts/prepare-webide.mjs',
  'playmesh/scripts/package-webide-release.mjs',
  'playmesh/extensions/README.md',
  'playmesh/extensions/index.json',
];

for (const relativePath of requiredInfrastructureFiles) {
  const filePath = path.join(gdevelopDirectory, ...relativePath.split('/'));
  await access(filePath);
  if (!(await stat(filePath)).isFile()) {
    throw new Error(
      `Required GDevelop infrastructure path is not a file: ${relativePath}`
    );
  }
}

// Overlay 与测试目录按实际文件树校验，新增文件无需再维护易遗漏的手写清单。
const overlayDirectory = path.join(playmeshDirectory, 'overlays');
const overlayFiles = await listRegularFiles(overlayDirectory);
if (overlayFiles.length === 0)
  throw new Error('GDevelop overlay tree is empty');
const testFiles = await listRegularFiles(path.join(playmeshDirectory, 'tests'));
const { executableTestFiles, fixtureDataFiles } =
  classifyPlaymeshTestFiles(testFiles);
for (const file of [
  ...overlayFiles,
  ...executableTestFiles,
  ...fixtureDataFiles,
]) {
  if ((await stat(file.absolutePath)).size === 0) {
    throw new Error(`GDevelop canonical file is empty: ${file.relativePath}`);
  }
}

const lock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
const outputManifest = await loadSourcePolicyOutputManifest(
  path.join(playmeshDirectory, 'source-policy-output-manifest.json')
);
assertManifestMatchesWebIdeLock({ manifest: outputManifest, lock });
const allowPendingOutputManifest = process.argv.includes(
  '--allow-pending-output-manifest'
);
const manifestFreeze = verifyOutputManifestFreezeState({
  manifest: outputManifest,
  allowPending: allowPendingOutputManifest,
});
const overlayTree = await verifyOverlayTreeDigest({
  manifest: outputManifest,
  overlayDirectory,
  allowPending: allowPendingOutputManifest,
});
const pendingWarnings = [...manifestFreeze.warnings, ...overlayTree.warnings];
if (pendingWarnings.length > 0) {
  process.stderr.write(
    `\n=== DEVELOPMENT OVERRIDE: OUTPUT MANIFEST IS PENDING ===\n${pendingWarnings
      .map(warning => `- ${warning}`)
      .join('\n')}\n` +
      'This layout run is not release evidence.\n' +
      '========================================================\n\n'
  );
}
if (!/^v\d+\.\d+\.\d+$/.test(lock.upstream.tag)) {
  throw new Error(`Invalid upstream tag: ${lock.upstream.tag}`);
}
if (!/^[a-f0-9]{40}$/.test(lock.upstream.commit)) {
  throw new Error(`Invalid upstream commit: ${lock.upstream.commit}`);
}
if (!Number.isInteger(lock.playmeshRevision) || lock.playmeshRevision < 1) {
  throw new Error(`Invalid Playmesh policy revision: ${lock.playmeshRevision}`);
}
const expectedAssetName = `GDevelop-webide-${lock.upstream.tag}.zip`;
if (lock.distribution.assetName !== expectedAssetName) {
  throw new Error(`Artifact name must be ${expectedAssetName}`);
}
for (const remoteField of ['strategy', 'releaseTag', 'downloadUrl']) {
  if (remoteField in lock.distribution) {
    throw new Error(
      `webide-lock must not contain remote publishing field: ${remoteField}`
    );
  }
}

const catalogLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'catalog-lock.json'), 'utf8')
);
if (
  catalogLock.schemaVersion !== 1 ||
  catalogLock.engine.version !== lock.upstream.tag.slice(1) ||
  catalogLock.engine.commit !== lock.upstream.commit ||
  catalogLock.acquisition ||
  catalogLock.sources.extensions.blobBatchSize ||
  catalogLock.sources.examples.blobBatchSize ||
  catalogLock.sources.extensions.archiveSha256 ||
  catalogLock.sources.examples.archiveSha256
) {
  throw new Error(
    'Catalog lock must use fixed commit/tree metadata without archive/blob acquisition'
  );
}
for (const sourceName of ['extensions', 'examples']) {
  const source = catalogLock.sources[sourceName];
  if (
    !/^GDevelopApp\/GDevelop-(?:extensions|examples)$/.test(
      source.repository
    ) ||
    !/^[a-f0-9]{40}$/.test(source.commit) ||
    !/^[a-f0-9]{40}$/.test(source.rootTreeSha)
  ) {
    throw new Error(`Invalid fixed catalog source: ${sourceName}`);
  }
}

const localExtensionsDirectory = path.join(
  playmeshDirectory,
  'extensions'
);
const localExtensionDirectoryEntries = await readdir(
  localExtensionsDirectory,
  { withFileTypes: true }
);
if (localExtensionDirectoryEntries.some(entry => !entry.isFile())) {
  throw new Error('Local extension directory must contain regular files only');
}
const localExtensionFileNames = localExtensionDirectoryEntries.map(
  entry => entry.name
);
if (
  new Set(localExtensionFileNames.map(name => name.toLowerCase())).size !==
  localExtensionFileNames.length
) {
  throw new Error('Local extension directory has case-insensitive duplicates');
}
const localExtensionIndexBytes = await readFile(
  path.join(localExtensionsDirectory, 'index.json')
);
if (
  localExtensionIndexBytes.byteLength < 1 ||
  localExtensionIndexBytes.byteLength > 256 * 1024
) {
  throw new Error('Local extension index has an invalid byte size');
}
let localExtensionIndex;
try {
  localExtensionIndex = JSON.parse(localExtensionIndexBytes.toString('utf8'));
} catch (error) {
  throw new Error(`Local extension index is invalid JSON: ${error.message}`);
}
if (
  !localExtensionIndex ||
  typeof localExtensionIndex !== 'object' ||
  Array.isArray(localExtensionIndex) ||
  localExtensionIndex.schemaVersion !== 1 ||
  Object.keys(localExtensionIndex).sort().join(',') !==
    'extensions,schemaVersion' ||
  !Array.isArray(localExtensionIndex.extensions) ||
  localExtensionIndex.extensions.length < 1 ||
  localExtensionIndex.extensions.length > 64
) {
  throw new Error('Local extension index has an invalid schema');
}
const supportedFunctionTypes = new Set([
  'StringExpression',
  'Expression',
  'Action',
  'Condition',
  'ExpressionAndCondition',
  'ActionWithOperator',
]);
const lifecycleFunctionNames = new Set(['onFirstSceneLoaded']);
const indexedPaths = new Set();
const indexedNames = new Set();
const bodyNames = new Set();
const expectedDirectoryFiles = new Set(['README.md', 'index.json']);
for (const descriptor of localExtensionIndex.extensions) {
  if (
    !descriptor ||
    typeof descriptor !== 'object' ||
    Array.isArray(descriptor) ||
    !Object.keys(descriptor).every(key => key === 'name' || key === 'path') ||
    !Object.prototype.hasOwnProperty.call(descriptor, 'path') ||
    Object.keys(descriptor).length > 2 ||
    typeof descriptor.path !== 'string' ||
    !/^[A-Za-z][A-Za-z0-9_.-]*\.json$/.test(descriptor.path) ||
    descriptor.path.toLowerCase() === 'index.json' ||
    descriptor.path.includes('/') ||
    descriptor.path.includes('\\') ||
    (descriptor.name !== undefined &&
      (typeof descriptor.name !== 'string' ||
        !/^[A-Za-z][A-Za-z0-9_]*$/.test(descriptor.name)))
  ) {
    throw new Error('Local extension index has an invalid entry');
  }
  const foldedPath = descriptor.path.toLowerCase();
  const foldedDeclaredName = descriptor.name?.toLowerCase();
  if (
    indexedPaths.has(foldedPath) ||
    (foldedDeclaredName && indexedNames.has(foldedDeclaredName))
  ) {
    throw new Error('Local extension index has a duplicate path or name');
  }
  indexedPaths.add(foldedPath);
  if (foldedDeclaredName) indexedNames.add(foldedDeclaredName);
  expectedDirectoryFiles.add(descriptor.path);

  const extensionBytes = await readFile(
    path.join(localExtensionsDirectory, descriptor.path)
  );
  if (
    extensionBytes.byteLength < 1 ||
    extensionBytes.byteLength > catalogLock.limits.extensionBytes
  ) {
    throw new Error(`Local extension has an invalid byte size: ${descriptor.path}`);
  }
  let extension;
  try {
    extension = JSON.parse(extensionBytes.toString('utf8'));
  } catch (error) {
    throw new Error(
      `Local extension is invalid JSON (${descriptor.path}): ${error.message}`
    );
  }
  if (
    !extension ||
    typeof extension !== 'object' ||
    Array.isArray(extension) ||
    !/^[A-Za-z][A-Za-z0-9_]*$/.test(extension.name || '') ||
    (descriptor.name !== undefined && extension.name !== descriptor.name) ||
    !/^\d+\.\d+\.\d+$/.test(extension.version || '') ||
    (extension.gdevelopVersion !== undefined &&
      typeof extension.gdevelopVersion !== 'string') ||
    !Array.isArray(extension.eventsFunctions) ||
    !Array.isArray(extension.eventsBasedBehaviors) ||
    !Array.isArray(extension.eventsBasedObjects)
  ) {
    throw new Error(
      `Local extension has an invalid root schema: ${descriptor.path}`
    );
  }
  const foldedBodyName = extension.name.toLowerCase();
  if (bodyNames.has(foldedBodyName)) {
    throw new Error(`Local extension name is duplicated: ${extension.name}`);
  }
  bodyNames.add(foldedBodyName);
  const extensionFunctionNames = new Set();
  for (const eventsFunction of extension.eventsFunctions) {
    const isLifecycleFunction =
      lifecycleFunctionNames.has(eventsFunction?.name) &&
      eventsFunction?.fullName === '';
    if (
      !eventsFunction ||
      typeof eventsFunction !== 'object' ||
      Array.isArray(eventsFunction) ||
      !/^[A-Za-z][A-Za-z0-9_]*$/.test(eventsFunction.name || '') ||
      (!isLifecycleFunction &&
        eventsFunction.functionType !== 'ActionWithOperator' &&
        (typeof eventsFunction.fullName !== 'string' ||
          eventsFunction.fullName.length === 0)) ||
      (isLifecycleFunction &&
        (!Array.isArray(eventsFunction.parameters) ||
          eventsFunction.parameters.length !== 0)) ||
      !supportedFunctionTypes.has(eventsFunction.functionType)
    ) {
      throw new Error(
        `Local extension has an invalid event function: ${descriptor.path}`
      );
    }
    if (extensionFunctionNames.has(eventsFunction.name)) {
      throw new Error(
        `Local extension has a duplicate function: ${extension.name}::${eventsFunction.name}`
      );
    }
    extensionFunctionNames.add(eventsFunction.name);
  }
}
if (
  expectedDirectoryFiles.size !== localExtensionFileNames.length ||
  localExtensionFileNames.some(name => !expectedDirectoryFiles.has(name))
) {
  throw new Error(
    'Local extension directory and index are not a one-to-one file set'
  );
}

const generatedCatalogDirectory = path.join(
  playmeshDirectory,
  'catalog',
  'generated'
);
const catalogManifest = JSON.parse(
  await readFile(
    path.join(generatedCatalogDirectory, 'catalog-manifest.json'),
    'utf8'
  )
);
if (
  catalogManifest.catalogRevision !== catalogLock.catalogRevision ||
  catalogManifest.generatedAt ||
  catalogManifest.sources.examples.commit !==
    catalogLock.sources.examples.commit ||
  catalogManifest.treeMetadata.rootTreeSha !==
    catalogLock.sources.examples.rootTreeSha
) {
  throw new Error('Generated catalog manifest is stale or non-deterministic');
}
const generatedIndexes = {};
for (const featureName of ['extensions', 'examples']) {
  const descriptor = catalogManifest.features[featureName];
  const manifestBytes = await readFile(
    path.join(generatedCatalogDirectory, descriptor.path)
  );
  const manifestDigest = createHash('sha256')
    .update(manifestBytes)
    .digest('hex');
  if (
    manifestBytes.byteLength !== descriptor.bytes ||
    manifestBytes.byteLength > catalogLock.limits.catalogFileBytes ||
    manifestDigest !== descriptor.sha256
  ) {
    throw new Error(
      `Generated ${featureName} manifest digest/size is invalid`
    );
  }
  const featureManifest = JSON.parse(manifestBytes.toString('utf8'));
  const indexDescriptor = featureManifest.index;
  if (
    featureManifest.schemaVersion !== 1 ||
    featureManifest.kind !== featureName ||
    featureManifest.catalogRevision !== catalogLock.catalogRevision ||
    featureManifest.source?.commit !== catalogLock.sources[featureName].commit ||
    featureManifest.source?.rootTreeSha !==
      catalogLock.sources[featureName].rootTreeSha ||
    !indexDescriptor ||
    typeof indexDescriptor.path !== 'string' ||
    path.basename(indexDescriptor.path) !== indexDescriptor.path
  ) {
    throw new Error(`Generated ${featureName} feature manifest is invalid`);
  }
  const indexBytes = await readFile(
    path.join(generatedCatalogDirectory, indexDescriptor.path)
  );
  const indexDigest = createHash('sha256').update(indexBytes).digest('hex');
  if (
    indexBytes.byteLength !== indexDescriptor.bytes ||
    indexBytes.byteLength > catalogLock.limits.catalogFileBytes ||
    indexDigest !== indexDescriptor.sha256
  ) {
    throw new Error(`Generated ${featureName} index digest/size is invalid`);
  }
  generatedIndexes[featureName] = JSON.parse(indexBytes.toString('utf8'));
}
const assertPublishedIntegrity = (value, label, maxBytes) => {
  if (
    !/^[a-f0-9]{64}$/.test(value.sha256 || '') ||
    !Number.isSafeInteger(value.declaredBytes) ||
    value.declaredBytes < 1 ||
    value.declaredBytes > maxBytes ||
    'bytes' in value
  ) {
    throw new Error(`${label} has invalid SHA-256/declaredBytes evidence`);
  }
};
for (const artifact of Object.values(generatedIndexes.extensions.artifacts)) {
  assertPublishedIntegrity(
    artifact,
    `Extension ${artifact.id}`,
    catalogLock.limits.extensionBytes
  );
  if (
    artifact.commit !== catalogLock.sources.extensions.commit ||
    artifact.rootTreeSha !== catalogLock.sources.extensions.rootTreeSha
  ) {
    throw new Error(`Extension artifact source is not pinned: ${artifact.id}`);
  }
}
if (generatedIndexes.examples.schemaVersion !== 2) {
  throw new Error('Examples index must use the lightweight tree schema');
}
for (const header of generatedIndexes.examples.headers) {
  assertPublishedIntegrity(
    header.project,
    `Example project ${header.id}`,
    catalogLock.limits.exampleProjectBytes
  );
  if (
    header.project.commit !== catalogLock.sources.examples.commit ||
    header.project.rootTreeSha !== catalogLock.sources.examples.rootTreeSha ||
    header.root !== `examples/${header.slug}` ||
    header.category !== 'official-examples'
  ) {
    throw new Error(`Example source identity is invalid: ${header.id}`);
  }
  for (const file of header.files) {
    assertPublishedIntegrity(
      file,
      `Example tree file ${header.id}/${file.relativePath}`,
      catalogLock.limits.exampleResourceBytes
    );
    if ('artifact' in file || !/^[a-f0-9]{40}$/.test(file.gitBlobOid || '')) {
      throw new Error(
        `Example tree file is not compact/provenanced: ${header.id}`
      );
    }
  }
}

const policy = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'service-policy.json'), 'utf8')
);
for (const requiredFeature of [
  'gdevelop-ai',
  'gdevelop-asset-store',
  'gdevelop-cloud-projects',
  'gdevelop-multiplayer-services',
  'gdevelop-analytics-and-telemetry',
]) {
  if (!policy.disabledFeatures.includes(requiredFeature)) {
    throw new Error(`Missing disabled feature: ${requiredFeature}`);
  }
}

process.stdout.write('GDevelop directory layout is valid.\n');
