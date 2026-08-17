import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

import { sha256Bytes } from './catalog-generator-lib.mjs';

const readJson = async filePath => {
  const bytes = await readFile(filePath);
  return { bytes, value: JSON.parse(bytes.toString('utf8')) };
};

const verifyDescriptor = async (root, descriptor, expectedPath) => {
  if (
    !descriptor ||
    descriptor.path !== expectedPath ||
    descriptor.mediaType !== 'application/json' ||
    !Number.isSafeInteger(descriptor.bytes) ||
    descriptor.bytes < 1 ||
    !/^[a-f0-9]{64}$/.test(descriptor.sha256 || '')
  ) {
    throw new Error(`目录 descriptor 无效：${expectedPath}`);
  }
  const file = path.join(root, expectedPath);
  const bytes = await readFile(file);
  if (bytes.byteLength !== descriptor.bytes || sha256Bytes(bytes) !== descriptor.sha256) {
    throw new Error(`目录 descriptor 摘要不匹配：${expectedPath}`);
  }
  return JSON.parse(bytes.toString('utf8'));
};

const verifyArtifact = (artifact, source, label) => {
  if (
    !artifact ||
    artifact.repository !== source.repository ||
    artifact.commit !== source.commit ||
    artifact.rootTreeSha !== source.rootTreeSha ||
    typeof artifact.path !== 'string' ||
    !artifact.path ||
    artifact.path.split('/').some(segment => !segment || segment === '.' || segment === '..') ||
    !Number.isSafeInteger(artifact.declaredBytes) ||
    artifact.declaredBytes < 1 ||
    !/^[a-f0-9]{64}$/.test(artifact.sha256 || '') ||
    typeof artifact.mediaType !== 'string' ||
    !artifact.mediaType
  ) {
    throw new Error(`目录 artifact 未固定 exact commit/path/sha/size：${label}`);
  }
};

export const verifyGeneratedCatalogDirectory = async rootArgument => {
  const root = path.resolve(rootArgument);
  if (!(await stat(root)).isDirectory()) throw new Error(`目录产物不存在：${root}`);
  const { value: manifest } = await readJson(path.join(root, 'catalog-manifest.json'));
  if (
    manifest.schemaVersion !== 1 ||
    !manifest.catalogRevision ||
    !manifest.sources ||
    !manifest.features ||
    'assets' in manifest.features
  ) {
    throw new Error('目录根清单无效或包含资产商店');
  }
  const featureDefinitions = [
    ['extensions', 'extensions-manifest.v1.json', 'extensions-index.json'],
    ['examples', 'examples-manifest.v1.json', 'examples-index.json'],
  ];
  const indexes = {};
  for (const [feature, featurePath, indexPath] of featureDefinitions) {
    const featureManifest = await verifyDescriptor(
      root,
      manifest.features[feature],
      featurePath
    );
    const source = manifest.sources[feature];
    if (
      featureManifest.schemaVersion !== 1 ||
      featureManifest.kind !== feature ||
      featureManifest.catalogRevision !== manifest.catalogRevision ||
      JSON.stringify(featureManifest.engine) !== JSON.stringify(manifest.engine) ||
      JSON.stringify(featureManifest.source) !== JSON.stringify(source)
    ) {
      throw new Error(`${feature} 版本化清单与根清单不一致`);
    }
    indexes[feature] = await verifyDescriptor(root, featureManifest.index, indexPath);
  }

  const extensionIndex = indexes.extensions;
  for (const [id, artifact] of Object.entries(extensionIndex.artifacts || {})) {
    verifyArtifact(artifact, manifest.sources.extensions, id);
    if (artifact.kind !== 'extension' || !artifact.path.startsWith('extensions/')) {
      throw new Error(`扩展 artifact 类型或路径无效：${id}`);
    }
  }
  if (!Array.isArray(extensionIndex.headers) || extensionIndex.headers.length === 0) {
    throw new Error('扩展本地搜索清单为空');
  }

  const exampleIndex = indexes.examples;
  if (!Array.isArray(exampleIndex.headers) || exampleIndex.headers.length === 0) {
    throw new Error('示例本地搜索清单为空');
  }
  for (const header of exampleIndex.headers) {
    verifyArtifact(header.project, manifest.sources.examples, `example:${header.id}:project`);
    for (const file of header.files || []) {
      verifyArtifact(
        {
          repository: manifest.sources.examples.repository,
          commit: manifest.sources.examples.commit,
          rootTreeSha: manifest.sources.examples.rootTreeSha,
          path: `${header.root}/${file.relativePath}`,
          ...file,
        },
        manifest.sources.examples,
        `example:${header.id}:${file.relativePath}`
      );
    }
  }
  return Object.freeze({
    root,
    catalogRevision: manifest.catalogRevision,
    extensions: extensionIndex.headers.length,
    examples: exampleIndex.headers.length,
  });
};
