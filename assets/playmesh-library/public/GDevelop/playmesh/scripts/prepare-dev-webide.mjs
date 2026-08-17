import { cp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  applyPlaymeshVisualEditorBrand,
  auditPlaymeshVisualEditorBrand,
  writeWebIdeThirdPartyNotices,
} from './webide-distribution-compliance-lib.mjs';

const argumentsMap = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsMap.set(process.argv[index], process.argv[index + 1]);
}

const sourceRoot = argumentsMap.get('--source');
const libgdDirectory = argumentsMap.get('--libgd');
const buildDirectory = argumentsMap.get('--build');
const gdjsDirectory =
  argumentsMap.get('--gdjs') || path.join(sourceRoot || '', 'GDJS');
if (!sourceRoot) {
  throw new Error(
    'Usage: node prepare-dev-webide.mjs --source <patched GDevelop root> ' +
      '[--gdjs <directory containing built Runtime>] ' +
      '[--libgd <directory containing libGD.js and libGD.wasm>] ' +
      '[--build <static build directory>]'
  );
}

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const repositoryRoot = path.resolve(playmeshDirectory, '../../../../..');
const webIdeLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
const aiToolContractSource = path.join(
  playmeshDirectory,
  'runtime',
  'ai',
  'tools.json'
);
const aiToolContractBytes = await readFile(aiToolContractSource);
JSON.parse(aiToolContractBytes.toString('utf8'));
const appDirectory = path.join(sourceRoot, 'newIDE', 'app');
const publicDirectory = path.join(appDirectory, 'public');
const publicRuntimeDirectory = path.join(publicDirectory, 'GDJS');
const sourceRuntimeDirectory = path.join(gdjsDirectory, 'Runtime');
await stat(path.join(sourceRuntimeDirectory, 'libs', 'jshashtable.js'));

if (libgdDirectory) {
  await cp(
    path.join(libgdDirectory, 'libGD.js'),
    path.join(publicDirectory, 'libGD.js')
  );
  await cp(
    path.join(libgdDirectory, 'libGD.wasm'),
    path.join(publicDirectory, 'libGD.wasm')
  );
}
for (const filename of ['libGD.js', 'libGD.wasm']) {
  const filePath = path.join(publicDirectory, filename);
  const fileSize = (await stat(filePath)).size;
  if (fileSize < 100000) {
    throw new Error(
      `${filePath} is missing or incomplete (${fileSize} bytes). ` +
        'Pass --libgd with a verified libGD directory from the pinned GDevelop version.'
    );
  }
}

// BrowserS3GDJSFinder points to ./GDJS in Playmesh builds. The production
// preparation script copies this into build/. Development mode serves public/.
await rm(publicRuntimeDirectory, { recursive: true, force: true });
await mkdir(path.join(publicRuntimeDirectory, 'Runtime'), { recursive: true });
await cp(
  sourceRuntimeDirectory,
  path.join(publicRuntimeDirectory, 'Runtime'),
  { recursive: true }
);
await applyPlaymeshVisualEditorBrand({
  directory: publicDirectory,
  logoPath: path.join(repositoryRoot, 'assets', 'branding', 'playmesh-mark.png'),
  repositoryRoot,
  brandEvidence: webIdeLock.compliance.playmeshBrandAsset,
});
await auditPlaymeshVisualEditorBrand({ directory: publicDirectory });
await cp(
  path.join(
    repositoryRoot,
    'assets',
    'legal',
    'gdevelop-webide-third-party-notices.md'
  ),
  path.join(publicDirectory, 'THIRD_PARTY_NOTICES.md')
);

const publicPolicyDirectory = path.join(publicDirectory, 'playmesh');
await mkdir(publicPolicyDirectory, { recursive: true });
await cp(
  path.join(playmeshDirectory, 'runtime', 'host-policy.js'),
  path.join(publicPolicyDirectory, 'host-policy.js')
);
await cp(
  path.join(playmeshDirectory, 'runtime', 'host-policy.css'),
  path.join(publicPolicyDirectory, 'host-policy.css')
);
await rm(path.join(publicPolicyDirectory, 'catalog'), {
  recursive: true,
  force: true,
});
await cp(
  path.join(playmeshDirectory, 'catalog', 'generated'),
  path.join(publicPolicyDirectory, 'catalog'),
  { recursive: true }
);
await mkdir(path.join(publicPolicyDirectory, 'ai'), { recursive: true });
await writeFile(
  path.join(publicPolicyDirectory, 'ai', 'tools.json'),
  aiToolContractBytes
);

const indexPath = path.join(publicDirectory, 'index.html');
let html = await readFile(indexPath, 'utf8');
const marker = '<!-- PLAYMESH_GDEVELOP_DEV_POLICY -->';
if (!html.includes(marker)) {
  const injection = `${marker}
    <link rel="stylesheet" href="%PUBLIC_URL%/playmesh/host-policy.css">
    <script src="%PUBLIC_URL%/playmesh/host-policy.js"></script>`;
  if (!html.includes('</head>')) {
    throw new Error('GDevelop development index.html has no </head>');
  }
  html = html.replace('</head>', `${injection}\n  </head>`);
  await writeFile(indexPath, html, 'utf8');
}

if (buildDirectory) {
  const buildIndexPath = path.join(buildDirectory, 'index.html');
  await readFile(buildIndexPath, 'utf8');

  // GDevelop's import-libGD build step may leave zero-byte files when its
  // online prebuilt download is unavailable. Always restore the verified
  // pinned files after a static build before serving it from Windows.
  for (const filename of ['libGD.js', 'libGD.wasm']) {
    const sourcePath = path.join(publicDirectory, filename);
    const destinationPath = path.join(buildDirectory, filename);
    await cp(sourcePath, destinationPath);
    const fileSize = (await stat(destinationPath)).size;
    if (fileSize < 100000) {
      throw new Error(
        `${destinationPath} is missing or incomplete (${fileSize} bytes).`
      );
    }
  }

  const buildRuntimeDirectory = path.join(buildDirectory, 'GDJS');
  await rm(buildRuntimeDirectory, { recursive: true, force: true });
  await mkdir(path.join(buildRuntimeDirectory, 'Runtime'), { recursive: true });
  await cp(
    sourceRuntimeDirectory,
    path.join(buildRuntimeDirectory, 'Runtime'),
    { recursive: true }
  );
  await applyPlaymeshVisualEditorBrand({
    directory: buildDirectory,
    logoPath: path.join(repositoryRoot, 'assets', 'branding', 'playmesh-mark.png'),
    repositoryRoot,
    brandEvidence: webIdeLock.compliance.playmeshBrandAsset,
  });
  await auditPlaymeshVisualEditorBrand({ directory: buildDirectory });
  await writeWebIdeThirdPartyNotices({
    buildDirectory,
    sourceDirectory: sourceRoot,
    runtimeDirectory: path.join(buildDirectory, 'GDJS', 'Runtime'),
    baseNoticePath: path.join(
      repositoryRoot,
      'assets',
      'legal',
      'gdevelop-webide-third-party-notices-base.md'
    ),
    lock: webIdeLock,
    outputDirectory: buildDirectory,
  });

  const buildPolicyDirectory = path.join(buildDirectory, 'playmesh');
  await mkdir(buildPolicyDirectory, { recursive: true });
  await cp(
    path.join(playmeshDirectory, 'runtime', 'host-policy.js'),
    path.join(buildPolicyDirectory, 'host-policy.js')
  );
  await cp(
    path.join(playmeshDirectory, 'runtime', 'host-policy.css'),
    path.join(buildPolicyDirectory, 'host-policy.css')
  );
  await rm(path.join(buildPolicyDirectory, 'catalog'), {
    recursive: true,
    force: true,
  });
  await cp(
    path.join(playmeshDirectory, 'catalog', 'generated'),
    path.join(buildPolicyDirectory, 'catalog'),
    { recursive: true }
  );
  await mkdir(path.join(buildPolicyDirectory, 'ai'), { recursive: true });
  await writeFile(
    path.join(buildPolicyDirectory, 'ai', 'tools.json'),
    aiToolContractBytes
  );

  let buildHtml = await readFile(buildIndexPath, 'utf8');
  if (!buildHtml.includes('playmesh/host-policy.js')) {
    const buildMarker = '<!-- PLAYMESH_GDEVELOP_STATIC_POLICY -->';
    const buildInjection = `${buildMarker}
    <link rel="stylesheet" href="./playmesh/host-policy.css">
    <script src="./playmesh/host-policy.js"></script>`;
    if (!buildHtml.includes('</head>')) {
      throw new Error('GDevelop static build index.html has no </head>');
    }
    buildHtml = buildHtml.replace(
      '</head>',
      `${buildInjection}\n  </head>`
    );
    await writeFile(buildIndexPath, buildHtml, 'utf8');
  }

  process.stdout.write(
    `Prepared static development build at ${buildDirectory}\n` +
      'Restored verified libGD and local GDJS Runtime for Windows hosting.\n'
  );
}

process.stdout.write(
  `Prepared GDevelop development server at ${appDirectory}\n` +
    'Verified libGD, copied local GDJS Runtime and injected the Playmesh host policy.\n'
);
