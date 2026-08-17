import { randomUUID } from 'node:crypto';
import {
  cp,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  BUILD_PROVENANCE_ENTRY,
  INTEGRATION_MARKER_ENTRY,
  computeWebIdeTreeDigest,
  createIntegrationMarker,
  loadFrozenProvenanceContext,
  verifyBuildProvenance,
  verifyPreparedProvenance,
  writeJsonAtomically,
} from './webide-provenance.mjs';
import { verifyGeneratedCatalogDirectory } from './catalog-verifier-lib.mjs';
import {
  applyPlaymeshVisualEditorBrand,
  auditPlaymeshVisualEditorBrand,
  writeWebIdeThirdPartyNotices,
} from './webide-distribution-compliance-lib.mjs';

const parseArguments = argv => {
  if (argv.length % 2 !== 0) {
    throw new TypeError('Every command line option must have one value');
  }
  const allowed = new Set([
    '--input',
    '--output',
    '--gdjs',
    '--source',
    '--lock',
    '--source-policy-manifest',
  ]);
  const output = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!allowed.has(name) || output.has(name)) {
      throw new TypeError(`Unknown or duplicate command line option: ${name}`);
    }
    output.set(name, argv[index + 1]);
  }
  return output;
};

const argumentsMap = parseArguments(process.argv.slice(2));
const inputArgument = argumentsMap.get('--input');
const outputArgument = argumentsMap.get('--output');
const gdjsArgument = argumentsMap.get('--gdjs');
const sourceArgument = argumentsMap.get('--source');
if (!inputArgument || !outputArgument || !gdjsArgument || !sourceArgument) {
  throw new Error(
    'Usage: node prepare-webide.mjs --input <audited upstream build> ' +
      '--gdjs <built GDJS directory> --source <patched source> ' +
      '--output <prepared build> ' +
      '[--lock <webide-lock.json>] ' +
      '[--source-policy-manifest <frozen manifest>]'
  );
}

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const repositoryRoot = path.resolve(playmeshDirectory, '../../../../..');
const lockPath = path.resolve(
  argumentsMap.get('--lock') || path.join(playmeshDirectory, 'webide-lock.json')
);
const sourcePolicyManifestPath = path.resolve(
  argumentsMap.get('--source-policy-manifest') ||
    path.join(playmeshDirectory, 'source-policy-output-manifest.json')
);
const inputDirectory = path.resolve(inputArgument);
const outputDirectory = path.resolve(outputArgument);
const gdjsDirectory = path.resolve(gdjsArgument);
const sourceDirectory = path.resolve(sourceArgument);
const generatedCatalogDirectory = path.join(
  playmeshDirectory,
  'catalog',
  'generated'
);
const aiToolContractSource = path.join(
  playmeshDirectory,
  'runtime',
  'ai',
  'tools.json'
);
const aiToolContractBytes = await readFile(aiToolContractSource);
JSON.parse(aiToolContractBytes.toString('utf8'));

// Catalog search/list content is an offline production input. Refuse the old
// three-file/no-SHA layout before any prepared output is touched.
await verifyGeneratedCatalogDirectory(generatedCatalogDirectory);

const isWithin = (parent, candidate) => {
  const relative = path.relative(parent, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
};
if (
  isWithin(inputDirectory, outputDirectory) ||
  isWithin(outputDirectory, inputDirectory) ||
  isWithin(outputDirectory, gdjsDirectory)
) {
  throw new Error(
    'Prepared output must be separate from the audited build and GDJS inputs'
  );
}

// 生产准备不能带入 pending；开发预览使用 prepare-dev-webide.mjs。
// 冻结上下文和输入 build 的来源证明必须在接触 output 前全部通过。
const context = await loadFrozenProvenanceContext({
  lockPath,
  sourcePolicyManifestPath,
});
const inputProvenance = await verifyBuildProvenance({
  buildDirectory: inputDirectory,
  context,
});
await readFile(path.join(inputDirectory, 'index.html'), 'utf8');
const gdjsRuntimeDirectory = path.join(gdjsDirectory, 'Runtime');
if (!(await stat(gdjsRuntimeDirectory)).isDirectory()) {
  throw new Error('Built GDJS Runtime directory is missing');
}

const removeSourceMaps = async directory => {
  let removedFiles = 0;
  let removedBytes = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      const nested = await removeSourceMaps(entryPath);
      removedFiles += nested.removedFiles;
      removedBytes += nested.removedBytes;
    } else if (entry.isFile() && entry.name.endsWith('.map')) {
      removedBytes += (await stat(entryPath)).size;
      await rm(entryPath);
      removedFiles += 1;
    }
  }
  return { removedFiles, removedBytes };
};

const outputParent = path.dirname(outputDirectory);
const outputName = path.basename(outputDirectory);
const transactionId = `${process.pid}-${randomUUID()}`;
const stagingDirectory = path.join(
  outputParent,
  `.${outputName}.staging-${transactionId}`
);
const backupDirectory = path.join(
  outputParent,
  `.${outputName}.backup-${transactionId}`
);
let outputMovedToBackup = false;
let stagingCommitted = false;
let removedSourceMaps;

await mkdir(outputParent, { recursive: true });
try {
  await mkdir(stagingDirectory);
  await cp(inputDirectory, stagingDirectory, { recursive: true });

  // 验证复制到 staging 的确实是刚审计的 build，再进行任何裁剪或注入。
  await verifyBuildProvenance({
    buildDirectory: stagingDirectory,
    context,
  });
  await rm(path.join(stagingDirectory, 'GDJS', 'Runtime'), {
    recursive: true,
    force: true,
  });
  await cp(
    gdjsRuntimeDirectory,
    path.join(stagingDirectory, 'GDJS', 'Runtime'),
    { recursive: true }
  );
  removedSourceMaps = await removeSourceMaps(stagingDirectory);

  const runtimeOutputDirectory = path.join(stagingDirectory, 'playmesh');
  await rm(runtimeOutputDirectory, { recursive: true, force: true });
  await mkdir(runtimeOutputDirectory, { recursive: true });
  await cp(
    path.join(playmeshDirectory, 'runtime', 'host-policy.js'),
    path.join(runtimeOutputDirectory, 'host-policy.js')
  );
  await cp(
    path.join(playmeshDirectory, 'runtime', 'host-policy.css'),
    path.join(runtimeOutputDirectory, 'host-policy.css')
  );
  await cp(
    generatedCatalogDirectory,
    path.join(runtimeOutputDirectory, 'catalog'),
    { recursive: true }
  );
  const aiOutputDirectory = path.join(runtimeOutputDirectory, 'ai');
  await mkdir(aiOutputDirectory, { recursive: true });
  await writeFile(
    path.join(aiOutputDirectory, 'tools.json'),
    aiToolContractBytes
  );
  await cp(
    path.resolve(playmeshDirectory, '..', 'official', 'LICENSE.md'),
    path.join(stagingDirectory, 'GDEVELOP-LICENSE.md')
  );
  await applyPlaymeshVisualEditorBrand({
    directory: stagingDirectory,
    logoPath: path.join(repositoryRoot, 'assets', 'branding', 'playmesh-mark.png'),
    repositoryRoot,
    brandEvidence: JSON.parse(await readFile(lockPath, 'utf8')).compliance
      .playmeshBrandAsset,
  });
  await auditPlaymeshVisualEditorBrand({ directory: stagingDirectory });
  await writeWebIdeThirdPartyNotices({
    buildDirectory: inputDirectory,
    sourceDirectory,
    runtimeDirectory: path.join(stagingDirectory, 'GDJS', 'Runtime'),
    baseNoticePath: path.join(
      repositoryRoot,
      'assets',
      'legal',
      'gdevelop-webide-third-party-notices-base.md'
    ),
    lock: JSON.parse(await readFile(lockPath, 'utf8')),
    outputDirectory: stagingDirectory,
  });

  const outputIndex = path.join(stagingDirectory, 'index.html');
  let html = await readFile(outputIndex, 'utf8');
  const policyMarker = '<!-- PLAYMESH_GDEVELOP_POLICY -->';
  if (html.includes(policyMarker)) {
    throw new Error('Playmesh policy was already injected');
  }
  if (!html.includes('</head>')) {
    throw new Error('GDevelop build index.html has no </head>');
  }
  const policyInjection = `${policyMarker}
    <link rel="stylesheet" href="./playmesh/host-policy.css">
    <script src="./playmesh/host-policy.js"></script>`;
  html = html.replace('</head>', `${policyInjection}\n  </head>`);
  await writeFile(outputIndex, html, 'utf8');

  const preparedTree = await computeWebIdeTreeDigest({
    directory: stagingDirectory,
    excludedRelativePaths: [INTEGRATION_MARKER_ENTRY],
  });
  const integrationMarker = createIntegrationMarker({
    context,
    buildProvenance: inputProvenance.value,
    preparedTreeSha256: preparedTree.sha256,
  });
  await writeJsonAtomically(
    path.join(stagingDirectory, INTEGRATION_MARKER_ENTRY),
    integrationMarker
  );
  await verifyPreparedProvenance({
    preparedDirectory: stagingDirectory,
    context,
  });

  try {
    await rename(outputDirectory, backupDirectory);
    outputMovedToBackup = true;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  try {
    await rename(stagingDirectory, outputDirectory);
    stagingCommitted = true;
  } catch (error) {
    if (outputMovedToBackup) {
      await rename(backupDirectory, outputDirectory);
      outputMovedToBackup = false;
    }
    throw error;
  }
  if (outputMovedToBackup) {
    try {
      await rm(backupDirectory, { recursive: true, force: true });
      outputMovedToBackup = false;
    } catch (error) {
      process.stderr.write(
        `Prepared WebIDE committed; retained backup ${backupDirectory}: ${
          error?.message || String(error)
        }\n`
      );
    }
  }
} finally {
  if (!stagingCommitted) {
    await rm(stagingDirectory, { recursive: true, force: true });
  }
}

process.stdout.write(
  `Prepared Web IDE at ${outputDirectory}\n` +
    `Bound audited build provenance ${BUILD_PROVENANCE_ENTRY}\n` +
    `Bundled local GDJS Runtime from ${gdjsDirectory}\n` +
    `Removed ${removedSourceMaps.removedFiles} source map file(s), ` +
    `${removedSourceMaps.removedBytes} byte(s)\n`
);
