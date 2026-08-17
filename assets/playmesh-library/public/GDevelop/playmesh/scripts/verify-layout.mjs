import { access, readFile, stat } from 'node:fs/promises';
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
