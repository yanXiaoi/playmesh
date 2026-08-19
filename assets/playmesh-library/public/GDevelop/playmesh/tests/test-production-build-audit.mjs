import assert from 'node:assert/strict';
import { copyFile, readFile, readdir, realpath, stat } from 'node:fs/promises';
import path from 'node:path';

import {
  computeDirectoryTreeDigest,
  parseExpectedAiState,
  verifyExpectedAiFeatureState,
} from '../scripts/source-policy-verifier-lib.mjs';
import {
  loadFrozenProvenanceContext,
  parseLibGdProvenance,
  verifyLibGdFilesAgainstProvenance,
  verifyBuildProvenance,
  verifyPatchedSourceInputs,
  writeBuildProvenance,
} from '../scripts/webide-provenance.mjs';

const argument = name => {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1] || null;
};
const explicitArgument = name => {
  const indexes = process.argv
    .map((value, index) => (value === name ? index : -1))
    .filter(index => index !== -1);
  if (indexes.length > 1) {
    throw new TypeError(`${name} must be provided exactly once`);
  }
  if (indexes.length === 0) return null;
  const value = process.argv[indexes[0] + 1];
  return value && !value.startsWith('--') ? value : null;
};
const buildRootArgument = argument('--build');
const lockPathArgument = argument('--lock');
const sourceRootArgument = argument('--source');
const sourceArchiveArgument = argument('--source-archive');
const sourcePolicyManifestArgument = argument('--source-policy-manifest');
const overlayDirectoryArgument = argument('--overlay');
const libGdKindArgument = explicitArgument('--libgd-kind');
const libGdSourceArgument = explicitArgument('--libgd-source');
const libGdUpstreamVersionArgument = explicitArgument(
  '--libgd-upstream-version'
);
const libGdJsSha256Argument = explicitArgument('--libgd-js-sha256');
const libGdJsSizeArgument = explicitArgument('--libgd-js-size');
const libGdWasmSha256Argument = explicitArgument('--libgd-wasm-sha256');
const libGdWasmSizeArgument = explicitArgument('--libgd-wasm-size');
const libGdUserDecisionArgument = explicitArgument('--libgd-user-decision');
if (process.argv.includes('--allow-pending-output-manifest')) {
  throw new Error(
    'Production build audit forbids --allow-pending-output-manifest'
  );
}
const expectedAiState = parseExpectedAiState(process.argv);
if (
  !buildRootArgument ||
  !lockPathArgument ||
  !sourceRootArgument ||
  !sourceArchiveArgument ||
  !sourcePolicyManifestArgument ||
  !overlayDirectoryArgument ||
  !libGdKindArgument ||
  !libGdSourceArgument ||
  !libGdUpstreamVersionArgument ||
  !libGdJsSha256Argument ||
  !libGdJsSizeArgument ||
  !libGdWasmSha256Argument ||
  !libGdWasmSizeArgument ||
  !libGdUserDecisionArgument
) {
  throw new Error(
    'Usage: node test-production-build-audit.mjs --build <app build> ' +
      '--lock <webide-lock.json> --source <patched source root> ' +
      '--source-archive <official source ZIP> ' +
      '--source-policy-manifest <frozen manifest> --overlay <overlay root> ' +
      '--libgd-kind <official-exact-commit-artifact|approved-legacy-prepared-exception> ' +
      '--libgd-source <exact official commit URL|absolute canonical prepared directory> ' +
      '--libgd-upstream-version <version> ' +
      '--libgd-js-sha256 <sha256> --libgd-js-size <bytes> ' +
      '--libgd-wasm-sha256 <sha256> --libgd-wasm-size <bytes> ' +
      '--libgd-user-decision <not-required|B> ' +
      '--expect-ai session-bootstrap'
  );
}

const buildRoot = path.resolve(buildRootArgument);
const lockPath = path.resolve(lockPathArgument);
const sourceRoot = path.resolve(sourceRootArgument);
const sourceArchivePath = path.resolve(sourceArchiveArgument);
const sourcePolicyManifestPath = path.resolve(sourcePolicyManifestArgument);
const overlayDirectory = path.resolve(overlayDirectoryArgument);
const playmeshRoot = path.dirname(overlayDirectory);
const parsePositiveSize = (value, label) => {
  if (!/^\d+$/.test(value || '')) {
    throw new TypeError(`${label} must be a positive safe integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new TypeError(`${label} must be a positive safe integer`);
  }
  return parsed;
};
const canonicalLibGdSource =
  libGdKindArgument === 'approved-legacy-prepared-exception'
    ? await realpath(libGdSourceArgument)
    : libGdSourceArgument;
if (
  libGdKindArgument === 'approved-legacy-prepared-exception' &&
  libGdSourceArgument !== canonicalLibGdSource
) {
  throw new TypeError(
    `--libgd-source must be canonical: ${canonicalLibGdSource}`
  );
}
const libGdProvenance = parseLibGdProvenance({
  kind: libGdKindArgument,
  source: canonicalLibGdSource,
  upstreamVersion: libGdUpstreamVersionArgument,
  files: {
    'libGD.js': {
      sha256: libGdJsSha256Argument,
      size: parsePositiveSize(libGdJsSizeArgument, '--libgd-js-size'),
    },
    'libGD.wasm': {
      sha256: libGdWasmSha256Argument,
      size: parsePositiveSize(libGdWasmSizeArgument, '--libgd-wasm-size'),
    },
  },
  userDecision: libGdUserDecisionArgument,
});
const context = await loadFrozenProvenanceContext({
  lockPath,
  sourcePolicyManifestPath,
});
const lock = context.lock.lock;
const revision = lock.playmeshRevision;
assert.equal(libGdProvenance.upstreamVersion, lock.upstream.tag.slice(1));
assert.ok(Number.isSafeInteger(revision) && revision > 0);
assert.equal(
  lock.distribution.assetName,
  `GDevelop-webide-${lock.upstream.tag}.zip`
);
for (const remoteField of ['strategy', 'releaseTag', 'downloadUrl']) {
  assert.equal(
    remoteField in lock.distribution,
    false,
    `webide-lock must not contain remote publishing field ${remoteField}`
  );
}

if (libGdProvenance.kind === 'approved-legacy-prepared-exception') {
  // B 是一次显式、可审计的旧版例外。只在该证明类型下验证并复制来源目录；
  // 正常的精确官方 commit 产物必须已由官方 build 导入，审计不会覆盖它。
  await verifyLibGdFilesAgainstProvenance({
    directory: canonicalLibGdSource,
    provenance: libGdProvenance,
    label: 'Approved legacy prepared source libGD',
  });
  for (const fileName of ['libGD.js', 'libGD.wasm']) {
    await copyFile(
      path.join(canonicalLibGdSource, fileName),
      path.join(buildRoot, fileName)
    );
  }
}
await verifyLibGdFilesAgainstProvenance({
  directory: buildRoot,
  provenance: libGdProvenance,
  label: 'Materialized production build libGD',
});

for (const requiredFile of [
  'index.html',
  'asset-manifest.json',
  'libGD.js',
  'libGD.wasm',
]) {
  assert.ok((await stat(path.join(buildRoot, requiredFile))).isFile());
}

const externalEditorsManifest = JSON.parse(
  await readFile(
    path.resolve(
      playmeshRoot,
      '..',
      'official',
      'external-editors.json'
    ),
    'utf8'
  )
);
const localExternalEditorsManifest = JSON.parse(
  await readFile(
    path.resolve(playmeshRoot, 'external-editors', 'manifest.json'),
    'utf8'
  )
);
assert.equal(externalEditorsManifest.schemaVersion, 1);
assert.equal(externalEditorsManifest.gdevelopVersion, lock.upstream.tag.slice(1));
assert.deepEqual(
  externalEditorsManifest.editors.map(editor => editor.name).sort(),
  ['jfxr', 'piskel', 'yarn']
);
assert.equal(localExternalEditorsManifest.schemaVersion, 1);
assert.equal(
  localExternalEditorsManifest.gdevelopVersion,
  lock.upstream.tag.slice(1)
);
assert.deepEqual(
  localExternalEditorsManifest.packages.map(item => item.name).sort(),
  ['jfxr', 'piskel', 'yarn']
);
const localExternalEditorPackages = new Map(
  await Promise.all(
    localExternalEditorsManifest.packages.map(async item => [
      item.name,
      JSON.parse(
        await readFile(
          path.resolve(
            playmeshRoot,
            'external-editors',
            ...item.manifest.split('/')
          ),
          'utf8'
        )
      ),
    ])
  )
);
for (const editor of externalEditorsManifest.editors) {
  assert.match(editor.version, /^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$/);
  assert.match(editor.officialArchiveSha256, /^[a-f0-9]{64}$/);
  assert.match(editor.treeSha256, /^[a-f0-9]{64}$/);
  assert.ok(Number.isSafeInteger(editor.fileCount) && editor.fileCount > 0);
  const localPackage = localExternalEditorPackages.get(editor.name);
  assert.ok(localPackage, `missing local ${editor.name} derivative manifest`);
  assert.equal(localPackage.name, editor.name);
  assert.equal(localPackage.base.gdevelopExternalEditorVersion, editor.version);
  assert.equal(
    localPackage.base.officialArchiveSha256,
    editor.officialArchiveSha256
  );
  assert.equal(localPackage.base.officialTreeSha256, editor.treeSha256);
  assert.ok(
    Number.isSafeInteger(localPackage.overlay.fileCount) &&
      localPackage.overlay.fileCount > 0
  );
  const expectedPatchedFileCount =
    editor.fileCount + localPackage.overlay.fileCount;
  const builtEditorRoot = path.join(
    buildRoot,
    'external',
    editor.name,
    `${editor.name}-editor`
  );
  const patchedSourceEditorRoot = path.join(
    sourceRoot,
    'newIDE',
    'app',
    'public',
    'external',
    editor.name,
    `${editor.name}-editor`
  );
  const patchedSourceTree = await computeDirectoryTreeDigest(
    patchedSourceEditorRoot
  );
  const builtTree = await computeDirectoryTreeDigest(builtEditorRoot);
  assert.equal(
    builtTree.sha256,
    patchedSourceTree.sha256,
    `production build changed the locked ${editor.name} editor tree`
  );
  assert.equal(
    builtTree.files.length,
    expectedPatchedFileCount,
    `production build has an incomplete ${editor.name} editor tree`
  );
  assert.equal(
    patchedSourceTree.files.length,
    expectedPatchedFileCount,
    `source policy did not materialize the complete ${editor.name} derivative tree`
  );
}

const staticJsRoot = path.join(buildRoot, 'static/js');
const javascriptFiles = (await readdir(staticJsRoot)).filter(name =>
  name.endsWith('.js')
);
let aiChunkName = null;
let aiChunkSource = null;
for (const name of javascriptFiles) {
  const source = await readFile(path.join(staticJsRoot, name), 'utf8');
  if (
    source.includes('/dev/api/gdevelop/ai/tools') &&
    source.includes('executionKind') &&
    source.includes('editor_function') &&
    source.includes('incompatible_ai_tools') &&
    source.includes('playmesh-ai-chat-tab') &&
    source.includes('playmesh-ai-agent-tab')
  ) {
    aiChunkName = name;
    aiChunkSource = source;
    break;
  }
}
assert.ok(
  aiChunkName,
  'production build does not contain the Playmesh AI chunk'
);
assert.ok(aiChunkSource);

let builtEventSender = null;
let builtPreviewRouter = null;
let builtLocalGdjsFinder = null;
const bundledSourceNames = new Set();
for (const name of javascriptFiles) {
  const mapPath = path.join(staticJsRoot, `${name}.map`);
  try {
    const map = JSON.parse(await readFile(mapPath, 'utf8'));
    map.sources.forEach((source, index) => {
      bundledSourceNames.add(source);
      if (source.endsWith('Utils/Analytics/EventSender.js')) {
        builtEventSender = map.sourcesContent[index];
      }
      if (source.endsWith('PlaymeshPreview/PlaymeshPreviewLauncherRouter.js')) {
        builtPreviewRouter = map.sourcesContent[index];
      }
      if (source.endsWith('GameEngineFinder/BrowserS3GDJSFinder.js')) {
        builtLocalGdjsFinder = map.sourcesContent[index];
      }
    });
    if (!Array.isArray(map.sources) || !Array.isArray(map.sourcesContent)) {
      throw new TypeError(`${name}.map has no source content`);
    }
  } catch (_) {}
}
assert.equal(typeof builtEventSender, 'string');
assert.doesNotMatch(
  builtEventSender,
  /posthog-js|app\.posthog\.com|resources\.gdevelop\.io\/a\/gea\.js/
);
assert.match(
  builtEventSender,
  /export const installAnalyticsEvents = \(\) => \{\};/
);
assert.doesNotMatch(builtEventSender, /posthog\.(init|capture|identify|alias|reset)/);

assert.equal(typeof builtPreviewRouter, 'string');
assert.match(builtPreviewRouter, /BrowserSWPreviewLauncher/);
assert.match(builtPreviewRouter, /PlaymeshGatewayPreviewLauncher/);
assert.doesNotMatch(
  builtPreviewRouter,
  /BrowserS3PreviewLauncher|BrowserS3FileSystem|GDevelopServices\/Preview|uploadPendingObjects/
);
for (const forbiddenSuffix of [
  'ExportAndShare/BrowserExporters/BrowserS3PreviewLauncher/index.js',
  'ExportAndShare/BrowserExporters/BrowserS3FileSystem.js',
  'EventsFunctionsExtensionsLoader/CodeWriters/BrowserS3EventsFunctionCodeWriter.js',
  'Utils/GDevelopServices/Preview.js',
]) {
  assert.equal(
    [...bundledSourceNames].some(source => source.endsWith(forbiddenSuffix)),
    false,
    `production build retained the forbidden S3 preview module: ${forbiddenSuffix}`
  );
}
assert.equal(typeof builtLocalGdjsFinder, 'string');
assert.match(builtLocalGdjsFinder, /new URL\('\.\/GDJS', documentBaseUri\)/);
assert.doesNotMatch(
  builtLocalGdjsFinder,
  /resources\.gdevelop-app\.com|storage\.googleapis\.com|amazonaws\.com|localhost:5002/
);

const sourceMap = JSON.parse(
  await readFile(path.join(staticJsRoot, `${aiChunkName}.map`), 'utf8')
);
const sourceContent = suffix => {
  const index = sourceMap.sources.findIndex(source => source.endsWith(suffix));
  assert.notEqual(index, -1, `production sourcemap is missing ${suffix}`);
  const content = sourceMap.sourcesContent[index];
  assert.equal(typeof content, 'string');
  return content;
};

const featureFlags = sourceContent('PlaymeshAi/PlaymeshAiFeatureFlags.js');
const mainFrame = sourceContent('MainFrame/index.js');
const titlebar = sourceContent('MainFrame/TabsTitlebar.js');
const integrationFacade = sourceContent(
  'PlaymeshAi/PlaymeshAiIntegration.js'
);
const sessionController = sourceContent(
  'PlaymeshAi/PlaymeshAiSessionController.js'
);
const aiClient = sourceContent('PlaymeshAi/PlaymeshAiClient.js');
const aiProtocol = sourceContent('PlaymeshAi/PlaymeshAiProtocol.js');
const aiPanel = sourceContent('PlaymeshAi/PlaymeshAiPanel.js');
const aiEditorContainer = sourceContent(
  'PlaymeshAi/PlaymeshAiEditorContainer.js'
);
for (const component of [
  'PlaymeshAi/PlaymeshAiApprovalDialog.js',
  'PlaymeshAi/PlaymeshAiAgentRunLoop.js',
]) {
  sourceContent(component);
}

verifyExpectedAiFeatureState({
  featureFlagsSource: featureFlags,
  expectedAiState,
});

// The official GDevelop shell is only allowed to consume the narrow Playmesh
// integration facade. Playmesh feature policy, lifecycle, branding, renderer,
// titlebar UI and tool snapshot reads must remain owned by Playmesh
// modules so an upstream source update does not absorb product-specific logic.
for (const officialShellSource of [mainFrame, titlebar]) {
  assert.doesNotMatch(
    officialShellSource,
    /PlaymeshAi\/(?:PlaymeshAiFeatureFlags|PlaymeshAiSessionController|PlaymeshAiToolRegistration|playmesh-ai-tools\.json)/
  );
  assert.doesNotMatch(
    officialShellSource,
    /\/dev\/api\/gdevelop\/ai|registerPlaymeshAiToolContract|registerTools\s*\(/
  );
}
assert.match(
  mainFrame,
  /from ['"]\.\.\/PlaymeshAi\/PlaymeshAiIntegration['"]/
);
for (const facadeApiUse of [
  /usePlaymeshAiIntegration\(state\.editorTabs\)/,
  /if \(!canOpenPlaymeshAi\(\)\) return/,
  /const hideAskAi = !canOpenPlaymeshAi\(\)/,
  /PLAYMESH_AI_EDITOR_LABEL/,
  /<PlaymeshAiIntegrationHost/,
  /renderPlaymeshAiEditorContainer as renderAskAiEditorContainer/,
  /getPlaymeshAiEditorExtraProps\(/,
]) {
  assert.match(mainFrame, facadeApiUse);
}
assert.match(
  titlebar,
  /import \{ PlaymeshAiTitlebarActions \} from ['"]\.\.\/PlaymeshAi\/PlaymeshAiIntegration['"]/
);
assert.match(titlebar, /<PlaymeshAiTitlebarActions/);

for (const facadeOwnershipMarker of [
  /from ['"]\.\/PlaymeshAiFeatureFlags['"]/,
  /from ['"]\.\/PlaymeshAiSessionLifecycleHost['"]/,
  /from ['"]\.\/PlaymeshAiEditorContainer['"]/,
  /export const PLAYMESH_AI_EDITOR_LABEL = ['"]PlayMesh AI['"]/,
  /export const canOpenPlaymeshAi/,
  /getIsPlaymeshAiEnabled\(\)/,
  /export const PlaymeshAiIntegrationHost/,
  /export const PlaymeshAiTitlebarActions/,
]) {
  assert.match(integrationFacade, facadeOwnershipMarker);
}

// The installed package owns one immutable runtime contract snapshot. WebIDE
// pages only GET it from the Gateway and never register a page-local copy.
assert.doesNotMatch(aiChunkSource, /\/dev\/api\/gdevelop\/ai\/tools\/register/);
assert.doesNotMatch(aiClient, /registerTools\s*\(|\/tools\/register/);
assert.doesNotMatch(
  sessionController,
  /registerPlaymeshAiToolContract|PlaymeshAiToolRegistration/
);
assert.doesNotMatch(
  integrationFacade,
  /registerPlaymeshAiToolContract|PlaymeshAiToolRegistration/
);

// The production chunk must carry the editor-session 4 approval setting all
// the way from the wire contract through the WebIDE-owned client and UI.
assert.match(
  aiProtocol,
  /PLAYMESH_AI_SESSION_PROTOCOL_VERSION\s*=\s*['"]4\.0\.0['"]/
);
assert.match(
  aiProtocol,
  /value === ['"]request_approval['"] \|\| value === ['"]always_allow['"]/
);
assert.match(aiClient, /editor-settings[\s\S]*approval-mode/);
assert.match(aiClient, /async updateApprovalMode\s*\(/);
assert.match(sessionController, /updateApprovalMode\s*\(/);
assert.match(aiPanel, /id=['"]playmesh-ai-approval-mode['"]/);
assert.match(aiPanel, /toggled=\{approvalMode === ['"]always_allow['"]\}/);
assert.match(
  aiEditorContainer,
  /onApprovalModeChanged=\{changeApprovalMode\}/
);
const toolContractPath = path.join(
  playmeshRoot,
  'runtime',
  'ai',
  'tools.json'
);
const toolContract = JSON.parse(await readFile(toolContractPath, 'utf8'));
assert.ok(Array.isArray(toolContract.tools));
assert.equal(toolContract.toolCount, toolContract.tools.length);
assert.ok(toolContract.tools.length > 0);
assert.ok(
  toolContract.tools.every(
    tool =>
      tool &&
      typeof tool.name === 'string' &&
      tool.name.length > 0 &&
      typeof tool.executionKind === 'string' &&
      tool.executionKind.length > 0
  )
);
assert.equal(typeof toolContract.protocolVersion, 'string');
assert.equal(typeof toolContract.toolsVersion, 'string');

// 只有 build 内容、明确 AI 状态和精确源码输入全部通过后才签发 build 证明。
// 任一失败都不会创建或覆盖 playmesh-build-provenance.json。
await verifyPatchedSourceInputs({
  context,
  sourceArchivePath,
  sourceRoot,
  overlayDirectory,
});
const provenance = await writeBuildProvenance({
  buildDirectory: buildRoot,
  context,
  libGdProvenance,
});
await verifyBuildProvenance({ buildDirectory: buildRoot, context });

process.stdout.write(
  `GDevelop production build audit passed for pm${revision}; AI chunk ${aiChunkName} ` +
    `is packaged, the AI authority is ${expectedAiState}, and build ` +
    `provenance ${provenance.value.buildTreeSha256} was written.\n`
);
