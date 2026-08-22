import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  mkdtemp,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  createDeterministicWebIdeZip,
  packageWebIdeDevelopment,
  packageWebIdeRelease,
  parseWebIdeReleaseLock,
  parseWebIdeReleaseManifest,
  readZipCentralDirectory,
  readZipEntryBytes,
  verifyWebIdeRelease,
} from '../scripts/package-webide-release.mjs';
import {
  BUILD_PROVENANCE_ENTRY,
  INTEGRATION_MARKER_ENTRY,
  computeWebIdeTreeDigest,
  createBuildProvenance,
  createIntegrationMarker,
  loadFrozenProvenanceContext,
  verifyPreparedProvenance,
  writeJsonAtomically,
} from '../scripts/webide-provenance.mjs';
import { sha256Bytes } from '../scripts/source-policy-verifier-lib.mjs';
import { GDEVELOP_DISTRIBUTION_DISCLAIMER } from '../scripts/webide-distribution-compliance-lib.mjs';

const temporaryRoot = await mkdtemp(
  path.join(tmpdir(), 'playmesh-webide-release-')
);
const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const canonicalAiToolsPath = path.resolve(
  testDirectory,
  '../runtime/ai/tools.json'
);
const canonicalAiToolsBytes = await readFile(canonicalAiToolsPath);
const preparedDirectory = path.join(temporaryRoot, 'prepared');
const releaseDirectory = path.join(temporaryRoot, 'release');
const manifestPath = path.join(releaseDirectory, 'update.json');
const lockPath = path.join(temporaryRoot, 'webide-lock.json');
const sourcePolicyManifestPath = path.join(
  temporaryRoot,
  'source-policy-output-manifest.json'
);
const pendingSourcePolicyManifestPath = path.join(
  temporaryRoot,
  'source-policy-output-manifest.pending.json'
);
const artifactName = 'GDevelop-webide-v5.6.276.zip';
const fixtureBbTextReadme =
  'pixi-multistyle-text\nhttps://github.com/tleunen/pixi-multistyle-text\nMIT\n';
const fixtureBbTextDeclaration = 'export default class MultiStyleText {}\n';
const fixtureBbTextUmd = '/* pixi-multistyle-text fixture derivative */\n';
const fixtureFirebaseIntegrity = 'sha512-fixture-firebase-integrity';
const fixtureFirebaseCommit = 'd92a36260a856026263b29955551284d9ee29a58';
const fixtureFirebasePackageJson = `${JSON.stringify({
  name: 'firebase',
  version: '9.0.0-beta.2',
  license: 'Apache-2.0',
  repository: {
    type: 'git',
    url: 'https://github.com/firebase/firebase-js-sdk.git',
  },
})}\n`;
const fixtureLogoPath = path.join(
  repositoryRoot,
  'assets',
  'branding',
  'playmesh-mark.png'
);
const fixtureBbTextLicensePath = path.join(
  repositoryRoot,
  'third_party',
  'gdevelop',
  'pixi-multistyle-text-LICENSE.md'
);

const writeRelative = async (relativePath, source) => {
  const target = path.join(preparedDirectory, ...relativePath.split('/'));
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, source);
};

const lock = {
  schemaVersion: 1,
  playmeshRevision: 17,
  upstream: {
    tag: 'v5.6.276',
    commit: '9ef4a53e6a9b351618a1e60a99f7d7f4baf36361',
    sourceArchiveSha256: '9'.repeat(64),
  },
  distribution: {
    assetName: artifactName,
  },
  compliance: {
    monaco: {
      declaredVersion: '0.14.3',
      loaderReportedVersion: '0.14.6',
      loaderSha256: '',
    },
    playmeshBrandAsset: {
      sourcePath: 'assets/branding/playmesh-mark.png',
      sourceSha256: sha256Bytes(await readFile(fixtureLogoPath)),
      rightsEvidence: 'not-asserted-by-build-system',
    },
    firebaseWebIde: {
      version: '9.0.0-beta.2',
      packageIntegrity: fixtureFirebaseIntegrity,
      packageJsonSha256: sha256Bytes(Buffer.from(fixtureFirebasePackageJson)),
      dependencyCommit: fixtureFirebaseCommit,
      license: 'Apache-2.0',
      repository: 'https://github.com/firebase/firebase-js-sdk.git',
    },
    bbTextPixiMultistyleText: {
      repository: 'https://github.com/tleunen/pixi-multistyle-text.git',
      licenseCommit: '3a42873661533af916867f49917f47e764a26181',
      licenseSourceUrl:
        'https://raw.githubusercontent.com/tleunen/pixi-multistyle-text/' +
        '3a42873661533af916867f49917f47e764a26181/LICENSE.md',
      licensePath: 'third_party/gdevelop/pixi-multistyle-text-LICENSE.md',
      upstreamLicenseSha256:
        '268d10da911a73347c8c3eacc511aea1a99e1ef151ad90d7ddb5508d46b6bc7e',
      vendoredLicenseSha256: sha256Bytes(
        await readFile(fixtureBbTextLicensePath)
      ),
      vendoredFiles: {
        'Extensions/BBText/pixi-multistyle-text/README.md': sha256Bytes(
          Buffer.from(fixtureBbTextReadme)
        ),
        'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.d.ts':
          sha256Bytes(Buffer.from(fixtureBbTextDeclaration)),
        'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.umd.js':
          sha256Bytes(Buffer.from(fixtureBbTextUmd)),
      },
      exactUpstreamCodeRevision: 'unknown',
    },
  },
};
const pendingManifest = {
  sha256: '',
  version: '1.0.0',
  size: 0,
  downloads: [
    { name: 'GitHub', url: 'https://example.com/github.zip' },
    { name: 'Gitee', url: 'https://example.com/gitee.zip' },
  ],
};
const frozenSourcePolicyManifest = {
  schemaVersion: 1,
  upstream: {
    tag: lock.upstream.tag,
    commit: lock.upstream.commit,
  },
  overlay: { treeSha256: '1'.repeat(64) },
  generatedFiles: [
    {
      relativePath: 'newIDE/app/src/PlaymeshShared/Test.js',
      postPatchSha256: '2'.repeat(64),
    },
  ],
  patchedOfficialFiles: [
    {
      relativePath: 'newIDE/app/src/Test.js',
      upstreamGitBlobSha: '3'.repeat(40),
      postPatchSha256: '4'.repeat(64),
    },
  ],
};
const pendingSourcePolicyManifest = {
  ...frozenSourcePolicyManifest,
  overlay: { treeSha256: 'pending' },
};
const frozenSourcePolicyManifestSource = `${JSON.stringify(
  frozenSourcePolicyManifest,
  null,
  2
)}\n`;
let provenanceContext;
let buildProvenance;
let integrationMarker;

const fixtureLibGdJavascript = Buffer.from(
  'var wasmBinaryFile="libGD.wasm";Module["asm"]["a"]();\n',
  'utf8'
);
const fixtureLibGdWasm = Buffer.from([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
  0x03, 0x02, 0x01, 0x00,
  0x07, 0x05, 0x01, 0x01, 0x61, 0x00, 0x00,
  0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b,
]);
const fixtureMonacoLoader = Buffer.from('/*! Version: 0.14.6 */\n', 'utf8');
lock.compliance.monaco.loaderSha256 = sha256Bytes(fixtureMonacoLoader);
const fixtureBrandedIndex = `<!doctype html>
<!-- PLAYMESH_VISUAL_EDITOR_IDENTITY -->
<title>Playmesh Visual Editor</title>
<link rel="icon" href="./playmesh-logo.png">
`;
const fixturePwaManifest = `${JSON.stringify(
  {
    short_name: 'Playmesh Editor',
    name: 'Playmesh Visual Editor',
    icons: [
      { src: './playmesh-logo.png', sizes: '1280x1280', type: 'image/png' },
    ],
  },
  null,
  2
)}\n`;
const fixtureThirdPartyNotices = `
# Playmesh Visual Editor
unofficial modified distribution
${GDEVELOP_DISTRIBUTION_DISCLAIMER.english}
${GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese}
GDevelop 5.6.276
${lock.upstream.commit}
GDevelop MIT license
Monaco Editor
React and React DOM
Fira Sans
zip.js
Firebase JavaScript SDK used by the WebIDE npm application — 9.0.0-beta.2
Firebase JavaScript SDK vendored by the GDevelop GDJS runtime — 8.3.3
DialogueTree bundled bondage.js LICENSE
BBText pixi-multistyle-text byte and license evidence
exact upstream code revision is unknown
Playmesh brand asset provenance boundary
Playmesh logo build provenance (no rights conclusion)
Mechanically collected verbatim materials
Webpack-emitted attribution
`;
const fixtureLibGdProvenance = {
  kind: 'approved-legacy-prepared-exception',
  source: preparedDirectory,
  upstreamVersion: '5.6.276',
  files: {
    'libGD.js': {
      sha256: sha256Bytes(fixtureLibGdJavascript),
      size: fixtureLibGdJavascript.byteLength,
    },
    'libGD.wasm': {
      sha256: sha256Bytes(fixtureLibGdWasm),
      size: fixtureLibGdWasm.byteLength,
    },
  },
  userDecision: 'B',
};

const refreshPreparedProvenance = async () => {
  const preparedTree = await computeWebIdeTreeDigest({
    directory: preparedDirectory,
    excludedRelativePaths: [INTEGRATION_MARKER_ENTRY],
  });
  integrationMarker = createIntegrationMarker({
    context: provenanceContext,
    buildProvenance,
    preparedTreeSha256: preparedTree.sha256,
  });
  await writeJsonAtomically(
    path.join(preparedDirectory, INTEGRATION_MARKER_ENTRY),
    integrationMarker
  );
  return integrationMarker;
};

try {
  const packagerSource = await readFile(
    path.resolve(testDirectory, '../scripts/package-webide-release.mjs'),
    'utf8'
  );
  assert.doesNotMatch(
    packagerSource,
    /node:(?:child_process|http|https|net)|\bfetch\s*\(|\bgit\s+(?:add|commit|push)|\bgh\s+release/i
  );
  const workflowSource = await readFile(
    path.join(repositoryRoot, '.github/workflows/build-gdevelop-webide.yml'),
    'utf8'
  );
  for (const forbiddenRemotePublishing of [
    /publish_release/,
    /contents:\s*write/,
    /gh\s+release/,
    /--clobber/,
    /publish github release/i,
  ]) {
    assert.doesNotMatch(workflowSource, forbiddenRemotePublishing);
  }
  for (const provenanceWorkflowGate of [
    /GDevelop-source\.zip/,
    /SOURCE_ARCHIVE_SHA256/,
    /sha256sum \.upstream\/GDevelop-source\.zip/,
    /unzip -q \.upstream\/GDevelop-source\.zip/,
    /test-production-build-audit\.mjs/,
    /--source-archive \.upstream\/GDevelop-source\.zip/,
    /--source-policy-manifest/,
    /--overlay/,
    /--expect-ai session-bootstrap/,
  ]) {
    assert.match(workflowSource, provenanceWorkflowGate);
  }
  assert.doesNotMatch(
    workflowSource,
    /repository:\s*4ian\/GDevelop/,
    'production build must use the verified archive rather than a second source checkout'
  );

  for (const [relativePath, source] of [
    ['GDEVELOP-LICENSE.md', 'MIT\n'],
    ['THIRD_PARTY_NOTICES.md', fixtureThirdPartyNotices],
    ['asset-manifest.json', '{}\n'],
    ['index.html', fixtureBrandedIndex],
    ['libGD.js', fixtureLibGdJavascript],
    ['libGD.wasm', fixtureLibGdWasm],
    ['manifest.json', fixturePwaManifest],
    ['playmesh-logo.png', Buffer.from('fixture-logo')],
    ['playmesh/host-policy.css', 'body{}\n'],
    ['playmesh/host-policy.js', 'void 0;\n'],
    ['playmesh/ai/tools.json', canonicalAiToolsBytes],
    [
      'external/playmesh-i18n/playmesh-external-editor-i18n.js',
      'globalThis.PlaymeshExternalEditorI18n = {};\n',
    ],
    [
      'external/utils/parent-editor-interface.js',
      'globalThis.PlaymeshParentEditorInterface = {};\n',
    ],
    ['external/piskel/piskel-index.html', '<!doctype html>\n'],
    ['external/piskel/piskel-main.js', 'void 0;\n'],
    ['external/piskel/piskel-editor/index.html', '<!doctype html>\n'],
    [
      'external/piskel/piskel-editor/js/lib/gif/gif.ie.worker.js',
      'self.onmessage = function () {};\n',
    ],
    [
      'external/piskel/piskel-editor/playmesh-i18n/piskel-i18n.js',
      'globalThis.PlaymeshPiskelI18n = {};\n',
    ],
    [
      'external/piskel/piskel-editor/playmesh-i18n/locales/en.js',
      'void 0;\n',
    ],
    [
      'external/piskel/piskel-editor/playmesh-i18n/locales/zh-CN.js',
      'void 0;\n',
    ],
    ['external/jfxr/jfxr-index.html', '<!doctype html>\n'],
    ['external/jfxr/jfxr-main.js', 'void 0;\n'],
    ['external/jfxr/jfxr-editor/index.html', '<!doctype html>\n'],
    [
      'external/jfxr/jfxr-editor/playmesh-i18n/install.js',
      'globalThis.PlaymeshJfxrI18n = {};\n',
    ],
    [
      'external/jfxr/jfxr-editor/playmesh-i18n/locales/en.js',
      'void 0;\n',
    ],
    [
      'external/jfxr/jfxr-editor/playmesh-i18n/locales/zh-CN.js',
      'void 0;\n',
    ],
    ['external/yarn/yarn-index.html', '<!doctype html>\n'],
    ['external/yarn/yarn-main.js', 'void 0;\n'],
    ['external/yarn/yarn-editor/index.html', '<!doctype html>\n'],
    [
      'external/yarn/yarn-editor/playmesh-i18n/install.js',
      'globalThis.PlaymeshYarnI18n = {};\n',
    ],
    [
      'external/yarn/yarn-editor/playmesh-i18n/locales/en.js',
      'void 0;\n',
    ],
    [
      'external/yarn/yarn-editor/playmesh-i18n/locales/zh-CN.js',
      'void 0;\n',
    ],
    ['GDJS/Runtime/index.html', '<!doctype html>\n'],
    ['GDJS/Runtime/libs/jshashtable.js', 'class Hashtable {}\n'],
    ['static/js/main.js', 'console.log("release");\n'],
  ]) {
    await writeRelative(relativePath, source);
  }
  await mkdir(releaseDirectory, { recursive: true });
  await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
  await writeFile(
    sourcePolicyManifestPath,
    frozenSourcePolicyManifestSource
  );
  await writeFile(
    pendingSourcePolicyManifestPath,
    `${JSON.stringify(pendingSourcePolicyManifest, null, 2)}\n`
  );
  await writeFile(
    manifestPath,
    `${JSON.stringify(pendingManifest, null, 2)}\n`
  );
  provenanceContext = await loadFrozenProvenanceContext({
    lockPath,
    sourcePolicyManifestPath,
  });
  buildProvenance = createBuildProvenance({
    context: provenanceContext,
    buildTreeSha256: '5'.repeat(64),
    libGdProvenance: fixtureLibGdProvenance,
  });
  await writeJsonAtomically(
    path.join(preparedDirectory, BUILD_PROVENANCE_ENTRY),
    buildProvenance
  );
  await refreshPreparedProvenance();
  await verifyPreparedProvenance({
    preparedDirectory,
    context: provenanceContext,
  });

  const preparationInputDirectory = path.join(
    temporaryRoot,
    'preparation-input'
  );
  const preparationGdjsDirectory = path.join(temporaryRoot, 'preparation-gdjs');
  const preparationSourceDirectory = path.join(
    temporaryRoot,
    'preparation-source'
  );
  const preparationOutputDirectory = path.join(
    temporaryRoot,
    'preparation-output'
  );
  await mkdir(preparationInputDirectory, { recursive: true });
  await mkdir(path.join(preparationGdjsDirectory, 'Runtime'), {
    recursive: true,
  });
  await mkdir(preparationSourceDirectory, { recursive: true });
  await mkdir(preparationOutputDirectory, { recursive: true });
  const preparationIndexSource = `<!doctype html><html><head>
<title>GDevelop 5</title>
<meta name="title" content="GDevelop game making app" />
<meta property="og:title" content="GDevelop game making app" />
<meta name="description" content="Build your own game super fast and without programming. Publish on mobile, desktop and on the web." />
<meta property="og:description" content="Build your own game super fast and without programming. Publish on mobile, desktop and on the web." />
<meta property="og:url" content="https://gdevelop.io" />
<meta property="og:image" content="./GDevelop-editor-thumbnail.png" />
<link rel="apple-touch-icon" href="./apple-touch-icon.png" />
<link rel="icon" href="./favicon-32x32.png" />
<link rel="icon" href="./favicon-16x16.png" />
<style>.logo {
  background-image: url("data:image/svg+xml,fixture");
}</style></head><body><noscript>Enable JavaScript.</noscript></body></html>
`;
  await writeFile(
    path.join(preparationInputDirectory, 'index.html'),
    preparationIndexSource
  );
  await writeFile(
    path.join(preparationInputDirectory, 'manifest.json'),
    `${JSON.stringify({
      short_name: 'GDevelop',
      name: 'GDevelop - Create games without programming',
      screenshots: [{ src: './GDevelop-editor-thumbnail.png' }],
      icons: [{ src: './favicon-32x32.png', sizes: '32x32' }],
    })}\n`
  );
  const writePreparationInput = async (relativePath, source) => {
    const target = path.join(
      preparationInputDirectory,
      ...relativePath.split('/')
    );
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, source);
  };
  await writePreparationInput(
    'external/monaco-editor-min/vs/loader.js',
    fixtureMonacoLoader
  );
  for (let index = 0; index < 5; index += 1) {
    await writePreparationInput(
      `static/js/chunk-${index}.LICENSE.txt`,
      `webpack attribution ${index}\n`
    );
  }
  const writePreparationSource = async (relativePath, source) => {
    const target = path.join(
      preparationSourceDirectory,
      ...relativePath.split('/')
    );
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, source);
  };
  for (const relativePath of [
    'LICENSE.md',
    'Core/LICENSE.md',
    'GDJS/LICENSE.md',
    'Extensions/LICENSE.md',
    'newIDE/LICENSE.md',
  ]) {
    await writePreparationSource(relativePath, `${relativePath} license\n`);
  }
  const packageVersions = {
    'monaco-editor': '0.14.3',
    react: '18.2.0',
    'react-dom': '18.2.0',
    scheduler: '0.23.2',
    'react-is': '16.13.1',
    firebase: '9.0.0-beta.2',
  };
  await writePreparationSource(
    'newIDE/app/package-lock.json',
    `${JSON.stringify({
      packages: Object.fromEntries(
        Object.entries(packageVersions).map(([name, version]) => [
          `node_modules/${name}`,
          name === 'firebase'
            ? {
                version,
                integrity: fixtureFirebaseIntegrity,
                dependencies: {
                  '@firebase/app': `0.0.900-exp.${fixtureFirebaseCommit.slice(0, 9)}`,
                },
              }
            : { version },
        ])
      ),
    })}\n`
  );
  for (const name of [
    'monaco-editor',
    'react',
    'react-dom',
    'scheduler',
    'react-is',
  ]) {
    await writePreparationSource(
      `newIDE/app/node_modules/${name}/LICENSE`,
      `${name} license\n`
    );
  }
  await writePreparationSource(
    'newIDE/app/node_modules/monaco-editor/ThirdPartyNotices.txt',
    'monaco third-party notices\n'
  );
  await writePreparationSource(
    'newIDE/app/node_modules/firebase/package.json',
    fixtureFirebasePackageJson
  );
  await writePreparationSource(
    'Extensions/Firebase/A_firebasejs/LICENSE.md',
    'firebase license\n'
  );
  await writePreparationSource(
    'Extensions/Firebase/A_firebasejs/NOTICE.txt',
    'firebase notice\n'
  );
  await writePreparationSource(
    'Extensions/DialogueTree/bondage.js/LICENSE.md',
    'bondage MIT license\n'
  );
  await writePreparationSource(
    'Extensions/DialogueTree/bondage.js/version.txt',
    'bondage version evidence\n'
  );
  await writePreparationSource(
    'Extensions/BBText/pixi-multistyle-text/README.md',
    fixtureBbTextReadme
  );
  await writePreparationSource(
    'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.d.ts',
    fixtureBbTextDeclaration
  );
  await writePreparationSource(
    'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.umd.js',
    fixtureBbTextUmd
  );
  for (const [name, source] of [
    ['LICENSE.GDevelop.txt', 'runtime GDevelop license\n'],
    ['NOTICE.Firebase.txt', 'runtime Firebase notice\n'],
    ['SPINE-LICENSE.txt', 'runtime Spine license\n'],
  ]) {
    await writeFile(
      path.join(preparationGdjsDirectory, 'Runtime', name),
      source
    );
  }
  await writeFile(
    path.join(preparationInputDirectory, 'libGD.js'),
    fixtureLibGdJavascript
  );
  await writeFile(
    path.join(preparationInputDirectory, 'libGD.wasm'),
    fixtureLibGdWasm
  );
  const preparationBuildTree = await computeWebIdeTreeDigest({
    directory: preparationInputDirectory,
    excludedRelativePaths: [BUILD_PROVENANCE_ENTRY],
  });
  await writeJsonAtomically(
    path.join(preparationInputDirectory, BUILD_PROVENANCE_ENTRY),
    createBuildProvenance({
      context: provenanceContext,
      buildTreeSha256: preparationBuildTree.sha256,
      libGdProvenance: fixtureLibGdProvenance,
    })
  );
  await writeFile(
    path.join(preparationOutputDirectory, 'do-not-replace.txt'),
    'preserved\n'
  );
  const pendingPreparation = spawnSync(
    process.execPath,
    [
      path.resolve(testDirectory, '../scripts/prepare-webide.mjs'),
      '--input',
      preparationInputDirectory,
      '--gdjs',
      preparationGdjsDirectory,
      '--source',
      preparationSourceDirectory,
      '--output',
      preparationOutputDirectory,
      '--lock',
      lockPath,
      '--source-policy-manifest',
      pendingSourcePolicyManifestPath,
    ],
    { encoding: 'utf8' }
  );
  assert.notEqual(pendingPreparation.status, 0);
  assert.match(
    `${pendingPreparation.stdout}\n${pendingPreparation.stderr}`,
    /Source-policy output manifest is not frozen:[\s\S]*overlay\.treeSha256/
  );
  assert.deepEqual(await readdir(preparationOutputDirectory), [
    'do-not-replace.txt',
  ]);
  assert.equal(
    await readFile(
      path.join(preparationOutputDirectory, 'do-not-replace.txt'),
      'utf8'
    ),
    'preserved\n'
  );
  await writeFile(
    path.join(preparationInputDirectory, 'index.html'),
    '<!doctype html><head></head><!-- tampered after audit -->\n'
  );
  const staleBuildPreparation = spawnSync(
    process.execPath,
    [
      path.resolve(testDirectory, '../scripts/prepare-webide.mjs'),
      '--input',
      preparationInputDirectory,
      '--gdjs',
      preparationGdjsDirectory,
      '--source',
      preparationSourceDirectory,
      '--output',
      preparationOutputDirectory,
      '--lock',
      lockPath,
      '--source-policy-manifest',
      sourcePolicyManifestPath,
    ],
    { encoding: 'utf8' }
  );
  assert.notEqual(staleBuildPreparation.status, 0);
  assert.match(
    `${staleBuildPreparation.stdout}\n${staleBuildPreparation.stderr}`,
    /Build provenance is stale/
  );
  assert.deepEqual(await readdir(preparationOutputDirectory), [
    'do-not-replace.txt',
  ]);
  await writeFile(
    path.join(preparationInputDirectory, 'index.html'),
    preparationIndexSource
  );
  const frozenPreparation = spawnSync(
    process.execPath,
    [
      path.resolve(testDirectory, '../scripts/prepare-webide.mjs'),
      '--input',
      preparationInputDirectory,
      '--gdjs',
      preparationGdjsDirectory,
      '--source',
      preparationSourceDirectory,
      '--output',
      preparationOutputDirectory,
      '--lock',
      lockPath,
      '--source-policy-manifest',
      sourcePolicyManifestPath,
    ],
    { encoding: 'utf8' }
  );
  assert.equal(
    frozenPreparation.status,
    0,
    `${frozenPreparation.stdout}\n${frozenPreparation.stderr}`
  );
  const preparedOutputProvenance = await verifyPreparedProvenance({
    preparedDirectory: preparationOutputDirectory,
    context: provenanceContext,
  });
  assert.equal(preparedOutputProvenance.marker.schemaVersion, 3);
  assert.equal(
    preparedOutputProvenance.marker.buildTreeSha256,
    preparationBuildTree.sha256
  );
  assert.deepEqual(
    await readFile(
      path.join(preparationOutputDirectory, 'playmesh', 'ai', 'tools.json')
    ),
    canonicalAiToolsBytes,
    'prepare-webide must copy the one canonical AI contract byte-for-byte'
  );

  assert.throws(
    () =>
      parseWebIdeReleaseManifest({
        sha: 'a'.repeat(64),
        version: '5.6.276',
        size: 1,
        downloads: [{ name: 'GitHub', url: 'https://example.com/a.zip' }],
      }),
    /exactly: downloads, sha256, size, version/
  );
  assert.throws(
    () =>
      parseWebIdeReleaseManifest({
        sha256: 'a'.repeat(64),
        version: '5.6.276',
        size: 1,
        downloads: [{ name: 'GitHub', url: 'https://example.com/a.zip' }],
        unknown: true,
      }),
    /exactly: downloads, sha256, size, version/
  );
  assert.throws(
    () =>
      parseWebIdeReleaseManifest({
        sha256: 'A'.repeat(64),
        version: '5.6.276',
        size: 1,
        downloads: [{ name: 'GitHub', url: 'https://example.com/a.zip' }],
      }),
    /64 lowercase hexadecimal/
  );
  assert.throws(
    () =>
      parseWebIdeReleaseManifest({
        sha256: 'a'.repeat(64),
        version: '5.6.276',
        size: 1,
        downloads: [
          {
            name: 'GitHub',
            url: 'https://example.com/a.zip',
            latency: 1,
          },
        ],
      }),
    /downloads\[0\] must contain exactly: name, url/
  );
  assert.equal(
    parseWebIdeReleaseManifest({
      sha256: 'a'.repeat(64),
      version: '5.6.276',
      size: 1,
      downloads: [{ name: 'HTTP', url: 'http://example.com/a.zip' }],
    }).downloads[0].url,
    'http://example.com/a.zip',
    'credential-free HTTP download URLs must be accepted'
  );
  for (const invalidUrl of [
    'ftp://example.com/a.zip',
    'http://user:password@example.com/a.zip',
    'https://user:password@example.com/a.zip',
  ]) {
    assert.throws(
      () =>
        parseWebIdeReleaseManifest({
          sha256: 'a'.repeat(64),
          version: '5.6.276',
          size: 1,
          downloads: [{ name: 'Invalid', url: invalidUrl }],
        }),
      /credential-free HTTP or HTTPS/
    );
  }
  assert.throws(
    () =>
      parseWebIdeReleaseLock({
        ...lock,
        distribution: {
          assetName: 'gdevelop-webide-v5.6.276-pm15.zip',
        },
      }),
    new RegExp(artifactName)
  );
  assert.throws(
    () =>
      parseWebIdeReleaseLock({
        ...lock,
        upstream: {
          tag: lock.upstream.tag,
          commit: lock.upstream.commit,
        },
      }),
    /upstream\.sourceArchiveSha256/
  );

  const developmentDirectory = path.join(temporaryRoot, 'development-build');
  const developmentReleaseDirectory = path.join(temporaryRoot, 'development-release');
  const developmentManifestPath = path.join(developmentReleaseDirectory, 'update.json');
  const writeDevelopment = async (relativePath, source) => {
    const target = path.join(developmentDirectory, ...relativePath.split('/'));
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, source);
  };
  for (const [relativePath, source] of [
    ['GDEVELOP-LICENSE.md', 'MIT\n'],
    ['THIRD_PARTY_NOTICES.md', fixtureThirdPartyNotices],
    ['asset-manifest.json', '{}\n'],
    ['index.html', fixtureBrandedIndex],
    ['libGD.js', fixtureLibGdJavascript],
    ['libGD.wasm', fixtureLibGdWasm],
    ['manifest.json', fixturePwaManifest],
    ['playmesh-logo.png', Buffer.from('fixture-logo')],
    ['playmesh/host-policy.css', 'body{}\n'],
    ['playmesh/host-policy.js', 'void 0;\n'],
    ['playmesh/catalog/catalog-manifest.json', '{}\n'],
    ['GDJS/Runtime/index.html', '<!doctype html>\n'],
    ['GDJS/Runtime/libs/jshashtable.js', 'class Hashtable {}\n'],
    ['static/js/main.js', 'console.log("dev");\n'],
    ['static/js/main.js.map', '{"version":3}\n'],
  ]) {
    await writeDevelopment(relativePath, source);
  }
  await mkdir(developmentReleaseDirectory, { recursive: true });
  await writeFile(
    developmentManifestPath,
    `${JSON.stringify(pendingManifest, null, 2)}\n`
  );
  await assert.rejects(
    packageWebIdeDevelopment({
      buildDirectory: developmentDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath: developmentManifestPath,
      releaseDirectory: developmentReleaseDirectory,
    }),
    /playmesh-(?:build-provenance|integration)\.json/
  );
  const developmentPackage = await packageWebIdeDevelopment({
    buildDirectory: preparedDirectory,
    lockPath,
    sourcePolicyManifestPath,
    manifestPath: developmentManifestPath,
    releaseDirectory: developmentReleaseDirectory,
  });
  assert.equal(developmentPackage.mode, 'development-test');
  const developmentEntries = await readZipCentralDirectory(
    path.join(developmentReleaseDirectory, artifactName)
  );
  assert.equal(
    developmentEntries.some(entry => entry.name.endsWith('.map')),
    false
  );
  assert.equal(
    developmentEntries.some(entry =>
      [BUILD_PROVENANCE_ENTRY, INTEGRATION_MARKER_ENTRY].includes(entry.name)
    ),
    true
  );
  const developmentManifest = parseWebIdeReleaseManifest(
    await readFile(developmentManifestPath, 'utf8'),
    { allowUnpublished: true }
  );
  assert.equal(developmentManifest.sha256, developmentPackage.sha256);
  assert.deepEqual(developmentManifest.downloads, pendingManifest.downloads);

  const firstZip = path.join(temporaryRoot, 'first.zip');
  const secondZip = path.join(temporaryRoot, 'second.zip');
  const first = await createDeterministicWebIdeZip({
    preparedDirectory,
    outputPath: firstZip,
  });
  const second = await createDeterministicWebIdeZip({
    preparedDirectory,
    outputPath: secondZip,
  });
  assert.deepEqual(first, second);
  assert.match(first.sha256, /^[a-f0-9]{64}$/);
  assert.ok(first.size > 0);

  const unpublishedManifestSource = await readFile(manifestPath, 'utf8');
  await assert.rejects(
    packageWebIdeRelease({
      preparedDirectory,
      lockPath,
      sourcePolicyManifestPath: pendingSourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /Source-policy output manifest is not frozen:[\s\S]*overlay\.treeSha256/
  );
  assert.equal(await readFile(manifestPath, 'utf8'), unpublishedManifestSource);
  assert.deepEqual(await readdir(releaseDirectory), ['update.json']);

  for (const [field, value] of [
    ['policyRevision', lock.playmeshRevision - 1],
    ['sourcePolicyManifestSha256', 'f'.repeat(64)],
    ['sourcePolicyOverlayTreeSha256', 'e'.repeat(64)],
  ]) {
    await writeRelative(
      'playmesh-integration.json',
      `${JSON.stringify({ ...integrationMarker, [field]: value }, null, 2)}\n`
    );
    await assert.rejects(
      packageWebIdeRelease({
        preparedDirectory,
        lockPath,
        sourcePolicyManifestPath,
        manifestPath,
        releaseDirectory,
      }),
      new RegExp(`Prepared WebIDE integration marker ${field} differs`)
    );
    assert.equal(
      await readFile(manifestPath, 'utf8'),
      unpublishedManifestSource
    );
    assert.deepEqual(await readdir(releaseDirectory), ['update.json']);
  }
  await refreshPreparedProvenance();

  await writeRelative(
    INTEGRATION_MARKER_ENTRY,
    `${JSON.stringify(
      {
        ...integrationMarker,
        libGdProvenance: {
          ...integrationMarker.libGdProvenance,
          files: {
            ...integrationMarker.libGdProvenance.files,
            'libGD.js': {
              ...integrationMarker.libGdProvenance.files['libGD.js'],
              sha256: 'f'.repeat(64),
            },
          },
        },
      },
      null,
      2
    )}\n`
  );
  await assert.rejects(
    packageWebIdeRelease({
      preparedDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /marker does not bind its libGD provenance/
  );
  assert.equal(await readFile(manifestPath, 'utf8'), unpublishedManifestSource);
  await refreshPreparedProvenance();

  await writeRelative(
    INTEGRATION_MARKER_ENTRY,
    `${JSON.stringify({ ...integrationMarker, schemaVersion: 2 }, null, 2)}\n`
  );
  await assert.rejects(
    packageWebIdeRelease({
      preparedDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /unsupported schemaVersion/
  );
  assert.equal(await readFile(manifestPath, 'utf8'), unpublishedManifestSource);
  await refreshPreparedProvenance();

  const firstPackaged = await packageWebIdeRelease({
    preparedDirectory,
    lockPath,
    sourcePolicyManifestPath,
    manifestPath,
    releaseDirectory,
  });
  assert.equal(firstPackaged.artifactName, artifactName);
  assert.equal(firstPackaged.version, '5.6.276');
  const generatedManifest = parseWebIdeReleaseManifest(
    await readFile(manifestPath, 'utf8'),
    { allowUnpublished: true }
  );
  assert.equal(generatedManifest.version, '5.6.276');
  assert.equal(generatedManifest.sha256, firstPackaged.sha256);
  assert.equal(generatedManifest.size, firstPackaged.size);
  assert.deepEqual(generatedManifest.downloads, pendingManifest.downloads);

  const entries = await readZipCentralDirectory(
    path.join(releaseDirectory, artifactName)
  );
  assert.ok(entries.some(entry => entry.name === 'index.html'));
  assert.ok(entries.some(entry => entry.name === 'GDJS/Runtime/index.html'));
  const packagedEntryNames = new Set(entries.map(entry => entry.name));
  for (const externalEditorRuntimeEntry of [
    'external/utils/parent-editor-interface.js',
    'external/piskel/piskel-index.html',
    'external/piskel/piskel-main.js',
    'external/piskel/piskel-editor/js/lib/gif/gif.ie.worker.js',
    'external/jfxr/jfxr-index.html',
    'external/jfxr/jfxr-main.js',
    'external/yarn/yarn-index.html',
    'external/yarn/yarn-main.js',
  ]) {
    assert.ok(
      packagedEntryNames.has(externalEditorRuntimeEntry),
      `release ZIP must retain ${externalEditorRuntimeEntry}`
    );
  }
  assert.equal(
    entries.filter(entry => entry.name === 'playmesh/ai/tools.json').length,
    1,
    'release ZIP must contain exactly one installed AI contract entry'
  );
  const packagedAiToolsEntry = entries.find(
    entry => entry.name === 'playmesh/ai/tools.json'
  );
  assert.deepEqual(
    await readZipEntryBytes({
      archivePath: path.join(releaseDirectory, artifactName),
      entry: packagedAiToolsEntry,
      maximumBytes: canonicalAiToolsBytes.byteLength,
    }),
    canonicalAiToolsBytes,
    'release ZIP must retain the canonical AI contract bytes exactly'
  );
  assert.ok(entries.every(entry => !entry.name.startsWith('gdevelop-webide/')));

  const firstPublishedManifestSource = await readFile(manifestPath, 'utf8');
  await writeRelative('static/js/main.js', 'console.log("replacement");\n');
  await assert.rejects(
    packageWebIdeRelease({
      preparedDirectory,
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /Prepared WebIDE provenance is stale/
  );
  assert.equal(
    await readFile(manifestPath, 'utf8'),
    firstPublishedManifestSource,
    'tampered prepared input must fail before release-manifest mutation'
  );
  await refreshPreparedProvenance();
  const packaged = await packageWebIdeRelease({
    preparedDirectory,
    lockPath,
    sourcePolicyManifestPath,
    manifestPath,
    releaseDirectory,
  });
  assert.notEqual(packaged.sha256, firstPackaged.sha256);
  assert.equal(
    parseWebIdeReleaseManifest(await readFile(manifestPath, 'utf8'), {
      allowUnpublished: true,
    }).sha256,
    packaged.sha256
  );
  assert.deepEqual(
    (await readdir(releaseDirectory)).filter(name =>
      /\.(?:tmp|backup)-/.test(name)
    ),
    []
  );
  const verified = await verifyWebIdeRelease({
    lockPath,
    sourcePolicyManifestPath,
    manifestPath,
    releaseDirectory,
  });
  assert.equal(verified.sha256, packaged.sha256);
  assert.equal(verified.size, packaged.size);
  assert.equal(verified.fileCount, 37);
  assert.equal(verified.downloads.length, 2);

  const missingDisclaimerReleaseDirectory = path.join(
    temporaryRoot,
    'missing-disclaimer-release'
  );
  const missingDisclaimerManifestPath = path.join(
    missingDisclaimerReleaseDirectory,
    'update.json'
  );
  await writeRelative(
    'THIRD_PARTY_NOTICES.md',
    fixtureThirdPartyNotices.replace(
      GDEVELOP_DISTRIBUTION_DISCLAIMER.english,
      'not affiliated with or endorsed by GDevelop Ltd'
    )
  );
  await refreshPreparedProvenance();
  const missingDisclaimerZip = await createDeterministicWebIdeZip({
    preparedDirectory,
    outputPath: path.join(missingDisclaimerReleaseDirectory, artifactName),
  });
  await writeFile(
    missingDisclaimerManifestPath,
    `${JSON.stringify(
      {
        sha256: missingDisclaimerZip.sha256,
        version: '5.6.276',
        size: missingDisclaimerZip.size,
        downloads: pendingManifest.downloads,
      },
      null,
      2
    )}\n`
  );
  await assert.rejects(
    verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath,
      manifestPath: missingDisclaimerManifestPath,
      releaseDirectory: missingDisclaimerReleaseDirectory,
    }),
    new RegExp(
      `THIRD_PARTY_NOTICES\\.md is missing required marker: ${GDEVELOP_DISTRIBUTION_DISCLAIMER.english}`
    )
  );
  await writeRelative('THIRD_PARTY_NOTICES.md', fixtureThirdPartyNotices);
  await refreshPreparedProvenance();

  await writeRelative(
    'static/js/main.js',
    'console.log("committed-with-retained-backup");\n'
  );
  await refreshPreparedProvenance();
  const cleanupFailurePackaged = await packageWebIdeRelease({
    preparedDirectory,
    lockPath,
    sourcePolicyManifestPath,
    manifestPath,
    releaseDirectory,
    removeCommittedBackup: async () => {
      throw new Error('injected committed-backup cleanup failure');
    },
  });
  assert.notEqual(cleanupFailurePackaged.sha256, packaged.sha256);
  const cleanupFailureManifest = parseWebIdeReleaseManifest(
    await readFile(manifestPath, 'utf8')
  );
  assert.equal(
    cleanupFailureManifest.sha256,
    cleanupFailurePackaged.sha256,
    'backup cleanup failure must not roll back only the ZIP after manifest commit'
  );
  assert.equal(cleanupFailureManifest.size, cleanupFailurePackaged.size);
  assert.deepEqual(cleanupFailureManifest.downloads, pendingManifest.downloads);
  const retainedBackups = (await readdir(releaseDirectory)).filter(name =>
    name.includes(`.${artifactName}.backup-`)
  );
  assert.equal(retainedBackups.length, 1);
  const verifiedAfterCleanupFailure = await verifyWebIdeRelease({
    lockPath,
    sourcePolicyManifestPath,
    manifestPath,
    releaseDirectory,
  });
  assert.equal(
    verifiedAfterCleanupFailure.sha256,
    cleanupFailurePackaged.sha256
  );
  await rm(path.join(releaseDirectory, retainedBackups[0]), { force: true });

  await assert.rejects(
    verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath: pendingSourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /Source-policy output manifest is not frozen:[\s\S]*overlay\.treeSha256/
  );

  const staleTreeReleaseDirectory = path.join(
    temporaryRoot,
    'stale-tree-release'
  );
  const staleTreeManifestPath = path.join(
    staleTreeReleaseDirectory,
    'update.json'
  );
  await writeRelative(
    'static/js/main.js',
    'console.log("stale-packaged-tree");\n'
  );
  const staleTreeZip = await createDeterministicWebIdeZip({
    preparedDirectory,
    outputPath: path.join(staleTreeReleaseDirectory, artifactName),
  });
  await writeFile(
    staleTreeManifestPath,
    `${JSON.stringify(
      {
        sha256: staleTreeZip.sha256,
        version: '5.6.276',
        size: staleTreeZip.size,
        downloads: pendingManifest.downloads,
      },
      null,
      2
    )}\n`
  );
  await assert.rejects(
    verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath,
      manifestPath: staleTreeManifestPath,
      releaseDirectory: staleTreeReleaseDirectory,
    }),
    /Packaged WebIDE provenance is stale/
  );
  await refreshPreparedProvenance();

  const invalidReleaseDirectory = path.join(
    temporaryRoot,
    'invalid-marker-release'
  );
  const invalidManifestPath = path.join(
    invalidReleaseDirectory,
    'update.json'
  );
  await writeRelative(
    'playmesh-integration.json',
    `${JSON.stringify(
      { ...integrationMarker, policyRevision: lock.playmeshRevision - 1 },
      null,
      2
    )}\n`
  );
  const invalidZip = await createDeterministicWebIdeZip({
    preparedDirectory,
    outputPath: path.join(invalidReleaseDirectory, artifactName),
  });
  await writeFile(
    invalidManifestPath,
    `${JSON.stringify(
      {
        sha256: invalidZip.sha256,
        version: '5.6.276',
        size: invalidZip.size,
        downloads: pendingManifest.downloads,
      },
      null,
      2
    )}\n`
  );
  await assert.rejects(
    verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath,
      manifestPath: invalidManifestPath,
      releaseDirectory: invalidReleaseDirectory,
    }),
    /Packaged WebIDE integration marker policyRevision differs/
  );
  await refreshPreparedProvenance();

  await writeFile(
    path.join(releaseDirectory, artifactName),
    Buffer.from('tampered')
  );
  await assert.rejects(
    verifyWebIdeRelease({
      lockPath,
      sourcePolicyManifestPath,
      manifestPath,
      releaseDirectory,
    }),
    /size differs/
  );

  process.stdout.write(
    'GDevelop WebIDE release package tests passed: pending or mismatched ' +
      'source-policy provenance fails before release mutation; frozen inputs ' +
      'retain strict SHA-256, deterministic root ZIP, atomic replacement, ' +
      'committed-backup cleanup isolation, unchanged download configuration ' +
      'and final ZIP provenance/tamper detection.\n'
  );
} finally {
  assert.match(path.basename(temporaryRoot), /^playmesh-webide-release-/);
  await rm(temporaryRoot, { recursive: true, force: true });
}
