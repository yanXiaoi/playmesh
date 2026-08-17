import { createHash } from 'node:crypto';
import { cp, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import {
  assertManifestMatchesWebIdeLock,
  loadSourcePolicyOutputManifest,
  sha256Bytes,
  verifyOverlayTreeDigest,
  verifyRecordedSourcePolicyOutputs,
} from './source-policy-verifier-lib.mjs';

const argumentsMap = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsMap.set(process.argv[index], process.argv[index + 1]);
}

const sourceRoot = argumentsMap.get('--source');
if (!sourceRoot) {
  throw new Error(
    'Usage: node apply-source-policy.mjs --source <GDevelop root>'
  );
}

const gitBlobSha = bytes => {
  const header = Buffer.from(`blob ${bytes.length}\0`, 'utf8');
  return createHash('sha1')
    .update(header)
    .update(bytes)
    .digest('hex');
};

const patchedOfficialOutputRecords = [];
const generatedOutputRecords = [];

const replaceExactly = (content, from, to, description) => {
  const firstIndex = content.indexOf(from);
  if (firstIndex === -1)
    throw new Error(`Missing source fragment: ${description}`);
  if (content.indexOf(from, firstIndex + from.length) !== -1) {
    throw new Error(`Source fragment is not unique: ${description}`);
  }
  return (
    content.slice(0, firstIndex) + to + content.slice(firstIndex + from.length)
  );
};

const replaceSectionExactly = (
  content,
  startMarker,
  endMarker,
  replacement,
  description
) => {
  const startIndex = content.indexOf(startMarker);
  if (startIndex === -1)
    throw new Error(`Missing section start: ${description}`);
  if (content.indexOf(startMarker, startIndex + startMarker.length) !== -1) {
    throw new Error(`Section start is not unique: ${description}`);
  }
  const endIndex = content.indexOf(endMarker, startIndex + startMarker.length);
  if (endIndex === -1)
    throw new Error(`Missing section end: ${description}`);
  if (content.indexOf(endMarker, endIndex + endMarker.length) !== -1) {
    throw new Error(`Section end is not unique: ${description}`);
  }
  return content.slice(0, startIndex) + replacement + content.slice(endIndex);
};

const replaceAllExactly = (
  content,
  from,
  to,
  expectedCount,
  description
) => {
  const actualCount = content.split(from).length - 1;
  if (actualCount !== expectedCount) {
    throw new Error(
      `Expected ${expectedCount} source fragments for ${description}, found ${actualCount}`
    );
  }
  return content.split(from).join(to);
};

const patchFile = async ({ relativePath, expectedGitBlobSha, transform }) => {
  const filePath = path.join(sourceRoot, ...relativePath.split('/'));
  const originalBytes = await readFile(filePath);
  const actualGitBlobSha = gitBlobSha(originalBytes);
  if (actualGitBlobSha !== expectedGitBlobSha) {
    throw new Error(
      `${relativePath} changed upstream. Expected ${expectedGitBlobSha}, got ${actualGitBlobSha}. ` +
        'Review the new GDevelop version before updating the lock file.'
    );
  }

  const original = originalBytes.toString('utf8');
  const patched = transform(original);
  if (patched === original)
    throw new Error(`Policy did not change ${relativePath}`);
  await writeFile(filePath, patched, 'utf8');
  patchedOfficialOutputRecords.push({
    relativePath,
    upstreamGitBlobSha: expectedGitBlobSha,
    postPatchSha256: sha256Bytes(Buffer.from(patched, 'utf8')),
  });
  process.stdout.write(`Patched ${relativePath}\n`);
};

const patchGeneratedOfficialFile = async ({
  relativePath,
  expectedSha256,
  transform,
}) => {
  const filePath = path.join(sourceRoot, ...relativePath.split('/'));
  const originalBytes = await readFile(filePath);
  const actualSha256 = sha256Bytes(originalBytes);
  if (actualSha256 !== expectedSha256) {
    throw new Error(
      `${relativePath} changed upstream. Expected sha256 ${expectedSha256}, got ${actualSha256}. ` +
        'Review the generated GDevelop source before updating the lock.'
    );
  }
  const original = originalBytes.toString('utf8');
  const patched = transform(original);
  if (patched === original)
    throw new Error(`Policy did not change ${relativePath}`);
  await writeFile(filePath, patched, 'utf8');
  generatedOutputRecords.push({
    relativePath,
    postPatchSha256: sha256Bytes(Buffer.from(patched, 'utf8')),
  });
  process.stdout.write(`Patched generated official source ${relativePath}\n`);
};

const assertOfficialSourceFile = async ({
  relativePath,
  expectedGitBlobSha,
  forbiddenPattern,
}) => {
  const filePath = path.join(sourceRoot, ...relativePath.split('/'));
  const bytes = await readFile(filePath);
  const actualGitBlobSha = gitBlobSha(bytes);
  if (actualGitBlobSha !== expectedGitBlobSha) {
    throw new Error(
      `${relativePath} changed upstream. Expected ${expectedGitBlobSha}, got ${actualGitBlobSha}. ` +
        'Playmesh must not patch the official Multiplayer runtime.'
    );
  }
  const content = bytes.toString('utf8');
  if (forbiddenPattern && forbiddenPattern.test(content)) {
    throw new Error(`${relativePath} contains a forbidden Playmesh reference.`);
  }
  process.stdout.write(`Verified unchanged official source ${relativePath}\n`);
};

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const overlayDirectory = path.join(playmeshDirectory, 'overlays');
await cp(overlayDirectory, sourceRoot, { recursive: true });
const sharedManifestSource = path.resolve(
  scriptDirectory,
  '..',
  '..',
  '..',
  'developer',
  'playmesh-game-manifest.js'
);
const sharedManifestTarget = path.resolve(
  sourceRoot,
  'newIDE',
  'app',
  'src',
  'PlaymeshShared',
  'GameManifest.js'
);
await mkdir(path.dirname(sharedManifestTarget), { recursive: true });
await cp(sharedManifestSource, sharedManifestTarget);
const sharedManifestSourceHash = createHash('sha256')
  .update(await readFile(sharedManifestSource))
  .digest('hex');
const sharedManifestTargetHash = createHash('sha256')
  .update(await readFile(sharedManifestTarget))
  .digest('hex');
if (sharedManifestSourceHash !== sharedManifestTargetHash) {
  throw new Error(
    'Shared Playmesh game manifest copy failed hash verification'
  );
}
generatedOutputRecords.push({
  relativePath: 'newIDE/app/src/PlaymeshShared/GameManifest.js',
  postPatchSha256: sharedManifestTargetHash,
});
process.stdout.write('Copied Playmesh source overlays\n');

const generateCanonicalBrowserSourceModule = async ({
  sourceFilename,
  targetFilename,
  requiredMarkers,
  label,
}) => {
  const sourcePath = path.resolve(
    scriptDirectory,
    '..',
    '..',
    '..',
    'developer',
    sourceFilename
  );
  const targetPath = path.resolve(
    sourceRoot,
    'newIDE',
    'app',
    'src',
    'PlaymeshShared',
    targetFilename
  );
  const sourceText = await readFile(sourcePath, 'utf8');
  if (requiredMarkers.some(marker => !sourceText.includes(marker))) {
    throw new Error(`Canonical ${label} source is invalid`);
  }
  await mkdir(path.dirname(targetPath), { recursive: true });
  await writeFile(
    targetPath,
    `// @flow\n// Generated by apply-source-policy.mjs from the canonical Playmesh source.\nconst source: string = ${JSON.stringify(
      sourceText
    )};\nexport default source;\n`,
    'utf8'
  );
  generatedOutputRecords.push({
    relativePath: `newIDE/app/src/PlaymeshShared/${targetFilename}`,
    postPatchSha256: sha256Bytes(await readFile(targetPath)),
  });
  process.stdout.write(`Generated canonical ${label} source module\n`);
};

await generateCanonicalBrowserSourceModule({
  sourceFilename: 'gdevelop-authority-bootstrap.js',
  targetFilename: 'GDevelopAuthorityBootstrapSource.js',
  requiredMarkers: [
    'playmeshGDevelopAuthorityBootstrap',
    'playmesh.gdevelop.multiplayer.v1',
  ],
  label: 'GDevelop Authority bootstrap',
});
await generateCanonicalBrowserSourceModule({
  sourceFilename: 'gdevelop-multiplayer-bridge.js',
  targetFilename: 'GDevelopMultiplayerBridgeSource.js',
  requiredMarkers: [
    'playmesh.runtime.backends.v1',
    'playmesh.gdevelop.multiplayer.coordinator.v1',
    'playmesh.gdevelop.multiplayer.v1',
  ],
  label: 'GDevelop Multiplayer bridge',
});
await generateCanonicalBrowserSourceModule({
  sourceFilename: 'gdevelop-fps-probe.js',
  targetFilename: 'GDevelopFpsProbeSource.js',
  requiredMarkers: [
    'playmesh.gdevelop.fps-probe.v1',
    'performanceApi.reportFrame()',
  ],
  label: 'GDevelop FPS probe',
});
await generateCanonicalBrowserSourceModule({
  sourceFilename: 'gdevelop-app-runtime-debugger-client.js',
  targetFilename: 'GDevelopAppRuntimeDebuggerClientSource.js',
  requiredMarkers: [
    '__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__',
    'PlaymeshAppRuntimeDebuggerClient',
    "protocolVersion: '1.0.0'",
  ],
  label: 'GDevelop App runtime debugger client',
});

await patchFile({
  relativePath: 'newIDE/app/package.json',
  expectedGitBlobSha: '8b4e42cc4fd22731f71adf6ebb1c4109ff03fb54',
  transform: content =>
    replaceExactly(
      content,
      `    "import-resources": "npm run make-version-metadata && npm run import-zipped-external-editors && npm run build-theme-resources && npm run make-service-worker && cd scripts && node import-libGD.js && node import-GDJS-Runtime.js && node import-monaco-editor.js && node import-zipped-external-libs.js",`,
      `    "import-resources": "npm run make-version-metadata && npm run build-theme-resources && npm run make-service-worker && cd scripts && node import-libGD.js && node import-GDJS-Runtime.js && node import-monaco-editor.js && node import-zipped-external-libs.js",`,
      'skip downloads for browser external editors disabled by Playmesh'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/scripts/make-version-metadata.js',
  expectedGitBlobSha: '73b9cf1f28173f516251b43e0b83a89b8d789ac0',
  transform: content =>
    replaceExactly(
      content,
      `const gitHashShellString = shell.exec(\`git rev-parse "HEAD"\`, {
  silent: true,
});

let gitHash = gitHashShellString.stdout.trim();
if (gitHashShellString.stderr || gitHashShellString.code) {
  shell.echo(\`⚠️ Can't find the hash or branch of the associated commit.\`);
  gitHash = 'unknown-hash';
}`,
      `const lockedGitHash = process.env.PLAYMESH_GDEVELOP_SOURCE_COMMIT || '';
let gitHash = lockedGitHash;
if (!/^[0-9a-f]{40}$/.test(gitHash)) {
  const gitHashShellString = shell.exec(\`git rev-parse "HEAD"\`, {
    silent: true,
  });
  gitHash = gitHashShellString.stdout.trim();
  if (gitHashShellString.stderr || gitHashShellString.code) {
    shell.echo(\`⚠️ Can't find the hash or branch of the associated commit.\`);
    gitHash = 'unknown-hash';
  }
}`,
      'bind generated IDE version metadata to the locked upstream commit'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/Analytics/EventSender.js',
  expectedGitBlobSha: '40c16b0f480f9f9d1d90d7bea7be28b114784fd2',
  transform: content => {
    content = replaceExactly(
      content,
      `import posthog from 'posthog-js';\n`,
      '',
      'remove the PostHog runtime import at the official EventSender seam'
    );
    content = replaceSectionExactly(
      content,
      `// Flag helpful to know if posthog is ready to send events.`,
      `export const setCurrentlyRunningInAppTutorial = (`,
      `// Playmesh 本地 WebIDE 不初始化任何官方遥测传输或远程脚本。\nlet currentlyRunningInAppTutorial = null;\n\n`,
      'remove PostHog and gea.js initialization state and retry loader'
    );
    content = replaceSectionExactly(
      content,
      `/**\n * Used to send an event to the analytics.`,
      `/**\n * Used once at the beginning of the app to initialize the analytics.`,
      `/** Playmesh 本地 WebIDE 的官方分析事件统一在此最低层变为空操作。 */\nconst recordEvent = (name: string, metadata?: { [string]: any }) => {};\n\n`,
      'turn all official analytics event sends into a local no-op'
    );
    content = replaceSectionExactly(
      content,
      `/**\n * Used once at the beginning of the app to initialize the analytics.`,
      `/**\n * Must be called every time the user is fetched`,
      `/** Playmesh 本地 WebIDE 不安装 PostHog、gea.js 或其重试任务。 */\nexport const installAnalyticsEvents = () => {};\n\n`,
      'disable official analytics installation and automatic retries'
    );
    content = replaceSectionExactly(
      content,
      `/**\n * Must be called every time the user is fetched`,
      `/**\n * Must be called on signup,`,
      `/** Playmesh 本地 WebIDE 不向遥测服务识别用户。 */\nexport const identifyUserForAnalytics = (\n  authenticatedUser: AuthenticatedUser\n) => {};\n\n`,
      'disable official analytics user identification and retries'
    );
    content = replaceSectionExactly(
      content,
      `/**\n * Must be called on signup,`,
      `export const onUserLogoutForAnalytics = () => {`,
      `/** Playmesh 本地 WebIDE 不创建 PostHog 用户别名。 */\nexport const aliasUserForAnalyticsAfterSignUp = (\n  // $FlowFixMe[value-as-type]\n  firebaseUser: FirebaseUser\n) => {};\n\n`,
      'disable official analytics signup aliasing and retries'
    );
    content = replaceSectionExactly(
      content,
      `export const onUserLogoutForAnalytics = () => {`,
      `export const sendProgramOpening = () => {`,
      `export const onUserLogoutForAnalytics = () => {\n  // 保留本机匿名身份生命周期，不调用任何遥测 SDK。\n  resetUserUUID();\n};\n\n`,
      'keep local UUID lifecycle while removing PostHog reset'
    );
    content = replaceSectionExactly(
      content,
      `export const sendInAppTutorialProgress = ({`,
      `export const sendAssetSwapStart = ({`,
      `export const sendInAppTutorialProgress = ({\n  step,\n  tutorialId,\n  isCompleted,\n  isUIRestricted,\n}: {|\n  tutorialId: string,\n  step: number,\n  isCompleted: boolean,\n  isUIRestricted: boolean,\n|}) => {};\n\n`,
      'remove deferred tutorial analytics timers'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/BrowserApp.js',
  expectedGitBlobSha: '6619110b08ff0e12e7d3ee74db77fefa626307da',
  transform: content => {
    content = replaceExactly(
      content,
      `import BrowserSWPreviewLauncher from './ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher';
import BrowserS3PreviewLauncher from './ExportAndShare/BrowserExporters/BrowserS3PreviewLauncher';`,
      `import PlaymeshPreviewLauncherRouter from './PlaymeshPreview/PlaymeshPreviewLauncherRouter';`,
      'route embedded previews locally and ordinary previews through Playmesh without importing S3'
    );
    content = replaceExactly(
      content,
      `import { makeBrowserSWEventsFunctionCodeWriter } from './EventsFunctionsExtensionsLoader/CodeWriters/BrowserSWEventsFunctionCodeWriter';
import { makeBrowserS3EventsFunctionCodeWriter } from './EventsFunctionsExtensionsLoader/CodeWriters/BrowserS3EventsFunctionCodeWriter';`,
      `import { makePlaymeshEventsFunctionCodeWriter } from './EventsFunctionsExtensionsLoader/CodeWriters/PlaymeshEventsFunctionCodeWriter';`,
      'replace browser IndexedDB and cloud event code writers with App session memory'
    );
    content = replaceExactly(
      content,
      `import { isServiceWorkerSupported } from './ServiceWorkerSetup';
import { ensureBrowserSWPreviewSession } from './ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher/BrowserSWPreviewIndexedDB';
`,
      '',
      'initialize the local preview transport only when embedded editing is requested'
    );
    content = replaceExactly(
      content,
      `import Providers from './MainFrame/Providers';`,
      `import Providers from './MainFrame/Providers';
import { PlaymeshLocalizationSessionProvider } from './PlaymeshLocalization/PlaymeshLocalizationProvider';`,
      'import the Playmesh GDevelop session localization provider'
    );
    content = replaceExactly(
      content,
      `import { PlaymeshLocalizationSessionProvider } from './PlaymeshLocalization/PlaymeshLocalizationProvider';`,
      `import { PlaymeshLocalizationSessionProvider } from './PlaymeshLocalization/PlaymeshLocalizationProvider';
import { activatePlaymeshLocalizationSession } from './PlaymeshLocalization/PlaymeshLocalizationSession';
import { PlaymeshProjectMutationGuard } from './PlaymeshProjectMutation/PlaymeshProjectMutationGuard';
import { cleanupPlaymeshLegacyBrowserPersistence } from './PlaymeshBrowserPersistence/PlaymeshBrowserPersistenceCleanup';`,
      'import the Playmesh localization session activator'
    );
    content = replaceExactly(
      content,
      `export const create = (authentication: Authentication): React.Node => {
  Window.setUpContextMenu();`,
      `export const create = (authentication: Authentication): React.Node => {
  activatePlaymeshLocalizationSession();
  cleanupPlaymeshLegacyBrowserPersistence();
  Window.setUpContextMenu();`,
      'activate Playmesh localization and browser persistence cleanup only for the browser integration entry'
    );
    content = replaceExactly(
      content,
      `  // TODO: make a hook that allows this to change, so we can switch to S3
  // (and log this into Posthog).
  const canUseBrowserSW = isServiceWorkerSupported();
  if (canUseBrowserSW) ensureBrowserSWPreviewSession();

`,
      '',
      'do not create the official browser preview session or IndexedDB database'
    );
    content = replaceExactly(
      content,
      `      makeEventsFunctionCodeWriter={
        canUseBrowserSW
          ? makeBrowserSWEventsFunctionCodeWriter
          : makeBrowserS3EventsFunctionCodeWriter
      }`,
      `      makeEventsFunctionCodeWriter={makePlaymeshEventsFunctionCodeWriter}`,
      'write generated event code through the App session gateway'
    );
    content = replaceExactly(
      content,
      `import CloudStorageProvider from './ProjectsStorage/CloudStorageProvider';`,
      `import PlaymeshLocalStorageProvider from './ProjectsStorage/PlaymeshLocalStorageProvider';`,
      'replace GDevelop Cloud storage with Playmesh local storage'
    );
    content = replaceExactly(
      content,
      `import browserResourceExternalEditors from './ResourcesList/BrowserResourceExternalEditors';\n`,
      '',
      'remove browser Piskel external editor registration'
    );
    content = replaceExactly(
      content,
      `import ShareDialog from './ExportAndShare/ShareDialog';`,
      `import ShareDialog from './ExportAndShare/PlaymeshPublishDialog';`,
      'replace all GDevelop export and invite options with Playmesh HTML publishing'
    );
    content = replaceExactly(
      content,
      `              resourceExternalEditors={browserResourceExternalEditors}`,
      `              resourceExternalEditors={[]}`,
      'disable Piskel and other browser external editors'
    );
    content = replaceExactly(
      content,
      `          storageProviders={[
            UrlStorageProvider,
            CloudStorageProvider,
            DownloadFileStorageProvider,
          ]}
          defaultStorageProvider={UrlStorageProvider}`,
      `          storageProviders={[
            PlaymeshLocalStorageProvider,
            UrlStorageProvider,
            DownloadFileStorageProvider,
          ]}
          defaultStorageProvider={PlaymeshLocalStorageProvider}`,
      'register Playmesh local storage as the browser default'
    );
    content = replaceExactly(
      content,
      `              renderPreviewLauncher={(props, ref) =>
                canUseBrowserSW ? (
                  // $FlowFixMe[incompatible-type]
                  <BrowserSWPreviewLauncher {...props} ref={ref} />
                ) : (
                  // $FlowFixMe[incompatible-type]
                  <BrowserS3PreviewLauncher {...props} ref={ref} />
                )
              }`,
      `              renderPreviewLauncher={(props, ref) => (
                // $FlowFixMe[incompatible-type]
                <PlaymeshPreviewLauncherRouter {...props} ref={ref} />
              )}`,
      'route embedded preview locally and ordinary preview through the Playmesh DeveloperRun chain'
    );
    content = replaceExactly(
      content,
      `  app = (
    <Providers`,
      `  app = (
    <PlaymeshLocalizationSessionProvider>
      <PlaymeshProjectMutationGuard>
        <Providers`,
      'initialize the App locale before mounting GDevelop providers'
    );
    content = replaceExactly(
      content,
      `    </Providers>
  );`,
      `        </Providers>
      </PlaymeshProjectMutationGuard>
    </PlaymeshLocalizationSessionProvider>
  );`,
      'keep localization and the project write guard authoritative for this entry'
    );
    return content;
  },
});

await patchGeneratedOfficialFile({
  relativePath:
    'newIDE/app/src/ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher/BrowserSWPreviewIndexedDB.js',
  expectedSha256:
    '3623fe43ad0420f9c8f3773c1636c8160d1c89e747abd3ee3802ef93da228882',
  transform: content =>
    replaceExactly(
      content,
      `export const getBrowserSWPreviewRootUrl = (): string => {
  const origin = window.location.origin;
  return \`${'${origin}'}/browser_sw_preview\`;
};`,
      `export const getBrowserSWPreviewRootUrl = (): string => {
  // Keep the preview under this WebIDE document. window.location.href is the
  // same local document when the DOM base URI is unavailable; never fall back
  // to the origin root or a remote preview launcher.
  const documentBaseUri: string = document.baseURI || window.location.href;
  return new URL(
    'browser_sw_preview',
    new URL('.', documentBaseUri)
  ).href.replace(/\\/$/, '');
};`,
      'scope Browser SW preview storage URLs to the current WebIDE directory'
    ),
});

await patchFile({
  relativePath:
    'newIDE/app/src/ExportAndShare/BrowserExporters/BrowserFileSystem.js',
  expectedGitBlobSha: '3fd390fadad65ce2a90f1e611832351fd30790fe',
  transform: content =>
    replaceExactly(
      content,
      `  copyFile = (source: string, dest: string): any => {\n    // URLs are not copied, but marked as to be downloaded.`,
      `  copyFile = (source: string, dest: string): any => {\n    const normalizedSource = pathPosix.normalize(source);\n    const normalizedDest = pathPosix.normalize(dest);\n    const hasOwnProperty /*: any */ = Object.prototype.hasOwnProperty;\n\n    // ExporterHelper can ask the browser filesystem to copy generated event\n    // code from its final export path back to that exact same path. Keep this\n    // as a no-op only when the normalized source entity actually exists. A\n    // missing source, including a missing self-copy, must still reach the\n    // normal diagnostic below.\n    if (\n      normalizedSource === normalizedDest &&\n      (hasOwnProperty.call(this._textFiles, normalizedSource) ||\n        hasOwnProperty.call(this._filesToDownload, normalizedSource))\n    ) {\n      return true;\n    }\n\n    // URLs are not copied, but marked as to be downloaded.`,
      'treat an existing normalized BrowserFileSystem self-copy as a no-op'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/index.js',
  expectedGitBlobSha: '859f1048ed28256c1a57369308ef8a3f0b27fe64',
  transform: content => {
    content = replaceExactly(
      content,
      `import VersionMetadata from './Version/VersionMetadata';\n`,
      `import VersionMetadata from './Version/VersionMetadata';
import { ensureGDevelopJsPlatformIsRegistered } from './PlaymeshShared/PlaymeshGDevelopPlatform';\n`,
      'share one process-wide GDevelop JS platform initialization guard'
    );
    content = replaceExactly(
      content,
      `        global.gd = gd;\n`,
      `        ensureGDevelopJsPlatformIsRegistered(gd);
        global.gd = gd;\n`,
      'register the JS platform before any project deserialize or export path'
    );
    content = replaceExactly(
      content,
      `import { registerServiceWorker } from './ServiceWorkerSetup';\n`,
      '',
      'remove the official Service Worker registration import'
    );
    content = replaceExactly(
      content,
      `\nregisterServiceWorker();\n`,
      '\n',
      'do not register the official browser preview Service Worker'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/ProjectCache.js',
  expectedGitBlobSha: 'c58926d96b6812e0fda01655b0f7ea0812f85ef7',
  transform: content => `// @flow

type ProjectCacheKey = {| userId: string, cloudProjectId: string |};

/**
 * Playmesh projects are durably saved by the App Gateway. Keeping another full
 * project autosave in browser IndexedDB would create a conflicting source of
 * truth, so the official cloud cache seam is deliberately inert.
 */
class ProjectCache {
  static isAvailable(): any {
    return false;
  }

  static async burst(): any {}

  async get(cacheKey: ProjectCacheKey): Promise<string | null> {
    return null;
  }

  async getCreationDate(cacheKey: ProjectCacheKey): Promise<number | null> {
    return null;
  }

  async put(cacheKey: ProjectCacheKey, project: gdProject): Promise<void> {}
}

export default ProjectCache;
`,
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/Analytics/UserUUID.js',
  expectedGitBlobSha: '67d487da17dcc204f6483fcb90b2311862b3259f',
  transform: content => {
    content = replaceExactly(
      content,
      `const localStorageKey = 'gd-user-uuid';\n`,
      '',
      'remove the persisted GDevelop analytics UUID key'
    );
    content = replaceSectionExactly(
      content,
      `export const resetUserUUID = (): string => {`,
      `export const getUserUUID = (): string => {`,
      `export const resetUserUUID = (): string => {
  currentUserUuid = generateUUID();
  return currentUserUuid;
};

`,
      'keep the unused analytics UUID in page memory only'
    );
    content = replaceSectionExactly(
      content,
      `export const getUserUUID = (): string => {`,
      `};\n`,
      `export const getUserUUID = (): string => {
  if (currentUserUuid) return currentUserUuid;
  return resetUserUUID();
`,
      'stop restoring the unused analytics UUID from localStorage'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/Analytics/LocalStats.js',
  expectedGitBlobSha: 'cee36d3f81efef07f8abee7cad1a08520975a7eb',
  transform: content => `// @flow

let programOpeningCount = 0;

export const getProgramOpeningCount = (): number => programOpeningCount;

export const incrementProgramOpeningCount = () => {
  programOpeningCount += 1;
};
`,
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/GDevelopServices/Authentication.js',
  expectedGitBlobSha: '2e675353ab4aecf1a27308985c2da7d3c6ef7b9d',
  transform: content => {
    content = replaceExactly(
      content,
      `import { initializeApp } from 'firebase/app';\n`,
      '',
      'remove automatic Firebase app initialization'
    );
    content = replaceExactly(
      content,
      `  getAuth,\n  onAuthStateChanged,\n`,
      '',
      'remove automatic Firebase auth state initialization'
    );
    content = replaceExactly(
      content,
      `import { GDevelopFirebaseConfig, GDevelopUserApi } from './ApiConfigs';`,
      `import { GDevelopUserApi } from './ApiConfigs';`,
      'remove the unused official Firebase runtime configuration'
    );
    content = replaceExactly(
      content,
      `  // $FlowFixMe[value-as-type]\n  auth: Auth;`,
      `  auth: any;`,
      'type the local authentication facade without the removed Firebase runtime'
    );
    content = replaceSectionExactly(
      content,
      `  constructor() {`,
      `  setLoginProvider = (loginProvider: LoginProvider) => {`,
      `  constructor() {
    // Account UI is disabled in Playmesh. Keep the official type surface for
    // components that expect Authentication, but do not initialize Firebase or
    // any of its browser persistence backends during normal editor startup.
    this.auth = { currentUser: null };
    this._initialAuthCheckPromise = Promise.resolve();
  }

`,
      'replace Firebase startup with an anonymous local authentication facade'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Course/CourseStoreContext.js',
  expectedGitBlobSha: '55c72b8918e7bcec2d6a50f9baa19b86d2e4706b',
  transform: content => {
    content = replaceExactly(
      content,
      `import {
  listListedCourseChapters,
  type CourseChapterListingData,
  listListedCourses,
  type CourseListingData,
} from '../Utils/GDevelopServices/Shop';
import { COURSE_CHAPTERS_FETCH_TIMEOUT } from '../Utils/GlobalFetchTimeouts';`,
      `import type {
  CourseChapterListingData,
  CourseListingData,
} from '../Utils/GDevelopServices/Shop';`,
      'remove the official course Shop API runtime imports'
    );
    content = replaceSectionExactly(
      content,
      `  const loadCourses = React.useCallback(async () => {`,
      `  return (
    <CourseStoreContext.Provider`,
      `  const loadCourses = React.useCallback(async () => {
    setListedCourses([]);
  }, []);

  const loadCourseChapters = React.useCallback(async () => {
    setListedCourseChapters([]);
  }, []);

  React.useEffect(
    () => {
      void loadCourses();
      void loadCourseChapters();
    },
    [loadCourseChapters, loadCourses]
  );

`,
      'replace official course prefetch and retry timers with a local empty state'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AnnouncementsFeed/AnnouncementsFeedContext.js',
  expectedGitBlobSha: '601262a77057a1aa923c70f4e7215caffa3a4193',
  transform: content => {
    content = replaceExactly(
      content,
      `import {
  type Announcement,
  type Promotion,
  listAllAnnouncements,
  listAllPromotions,
} from '../Utils/GDevelopServices/Announcement';
import { ANNOUNCEMENTS_FETCH_TIMEOUT } from '../Utils/GlobalFetchTimeouts';`,
      `import type {
  Announcement,
  Promotion,
} from '../Utils/GDevelopServices/Announcement';`,
      'remove official announcement and promotion API imports'
    );
    content = replaceSectionExactly(
      content,
      `  const fetchAnnouncementsAndPromotions = React.useCallback(async () => {`,
      `  const announcementsFeedState = React.useMemo(`,
      `  const fetchAnnouncementsAndPromotions = React.useCallback(async () => {
    setError(null);
    setAnnouncements([]);
    setPromotions([]);
  }, []);

  React.useEffect(
    () => {
      void fetchAnnouncementsAndPromotions();
    },
    [fetchAnnouncementsAndPromotions]
  );

`,
      'replace official announcement prefetch with a local empty state'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/InAppTutorial/InAppTutorialProvider.js',
  expectedGitBlobSha: 'aa4e0271947113efbd149e764dd8eb2895d754ac',
  transform: content => {
    let next = replaceExactly(
      content,
      `  fetchInAppTutorialShortHeaders,\n`,
      '',
      'remove the disabled online tutorial list fetch import'
    );
    next = replaceExactly(
      next,
      `import { IN_APP_TUTORIALS_FETCH_TIMEOUT } from '../Utils/GlobalFetchTimeouts';\n`,
      '',
      'remove the disabled online tutorial prefetch timer import'
    );
    next = replaceExactly(
      next,
      `  const loadInAppTutorials = React.useCallback(async () => {
    setFetchingError(null);
    try {
      const fetchedInAppTutorialShortHeaders = await fetchInAppTutorialShortHeaders();
      setInAppTutorialShortHeaders(fetchedInAppTutorialShortHeaders);
    } catch (error) {
      console.error('An error occurred when fetching in app tutorials:', error);
      setFetchingError('fetching-error');
    }
  }, []);`,
      `  const loadInAppTutorials = React.useCallback(async () => {
    setFetchingError(null);
    setInAppTutorialShortHeaders([]);
  }, []);`,
      'keep the official online tutorial list disabled while preserving local file playback'
    );
    return replaceExactly(
      next,
      `  // Preload the in-app tutorial short headers when the app loads.
  React.useEffect(
    () => {
      const timeoutId = setTimeout(() => {
        console.info('Pre-fetching in-app tutorials...');
        loadInAppTutorials();
      }, IN_APP_TUTORIALS_FETCH_TIMEOUT);
      return () => clearTimeout(timeoutId);
    },
    [loadInAppTutorials]
  );`,
      `  React.useEffect(
    () => {
      void loadInAppTutorials();
    },
    [loadInAppTutorials]
  );`,
      'initialize the local empty tutorial list without an online prefetch timer'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/AssetStoreContext.js',
  expectedGitBlobSha: '62c0a37ff7e6a96a9c78da5cbc7417b0ee855db9',
  transform: content => {
    content = replaceExactly(
      content,
      `import {
  type AssetShortHeader,
  type PublicAssetPacks,
  type PublicAssetPack,
  type Author,
  type License,
  type Environment,
  listAllPublicAssets,
  listAllAuthors,
  listAllLicenses,
} from '../Utils/GDevelopServices/Asset';
import {
  listListedPrivateAssetPacks,
  type PrivateAssetPackListingData,
} from '../Utils/GDevelopServices/Shop';`,
      `import type {
  AssetShortHeader,
  PublicAssetPacks,
  PublicAssetPack,
  Author,
  License,
  Environment,
} from '../Utils/GDevelopServices/Asset';
import type { PrivateAssetPackListingData } from '../Utils/GDevelopServices/Shop';`,
      'remove official asset and private Shop API runtime imports'
    );
    return replaceSectionExactly(
      content,
      `  const fetchAssetsAndFilters = React.useCallback(`,
      `  // When the public assets or the private assets are loaded,`,
      `  const fetchAssetsAndFilters = React.useCallback(() => {
    setError(null);
    setPublicAssetPacks(null);
    setPublicAssetShortHeaders([]);
    setFilters(null);
    setAuthors([]);
    setLicenses([]);
    setPrivateAssetPackListingDatas([]);
  }, []);

`,
      'replace official asset store loading with a local empty state'
    );
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/AssetStore/ResourceStore/ResourceStoreContext.js',
  expectedGitBlobSha: '01da231d22a875bcd65c00ff4a9169e97acaa343',
  transform: content => {
    content = replaceExactly(
      content,
      `import {
  type Resource,
  type ResourceV2,
  type AudioResourceV2,
  type FontResourceV2,
  type Author,
  type License,
  listAllAuthors,
  listAllLicenses,
  listAllResources,
} from '../../Utils/GDevelopServices/Asset';`,
      `import type {
  Resource,
  ResourceV2,
  AudioResourceV2,
  FontResourceV2,
  Author,
  License,
} from '../../Utils/GDevelopServices/Asset';`,
      'remove official resource store API runtime imports'
    );
    return replaceSectionExactly(
      content,
      `  const fetchResourcesAndFilters = React.useCallback(`,
      `  const audioFiltersState = React.useMemo(`,
      `  const fetchResourcesAndFilters = React.useCallback(() => {
    setError(null);
    setSvgResourcesByUrl({});
    setFontResourcesByUrl({});
    setAudioResourcesByUrl({});
    setFilters(null);
    setAuthors([]);
    setAuthorsByAuthorName({});
    setLicenses([]);
    isLoading.current = false;
  }, []);

`,
      'replace official resource store loading with a local empty state'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Profile/AuthenticatedUserProvider.js',
  expectedGitBlobSha: '3934e89055a9e402d4010032feebb9fd30f52834',
  transform: content => {
    content = replaceExactly(
      content,
      `  listDefaultRecommendations,
`,
      '',
      'remove anonymous default recommendation API import'
    );
    content = replaceExactly(
      content,
      `import { getAchievements } from '../Utils/GDevelopServices/Badge';
`,
      '',
      'remove official achievements API import'
    );
    content = replaceSectionExactly(
      content,
      `    listDefaultRecommendations().then(`,
      `  }

  // $FlowFixMe[value-as-type]`,
      `    this.setState(({ authenticatedUser }) => ({
      authenticatedUser: {
        ...authenticatedUser,
        recommendations: [],
      },
    }));
`,
      'replace anonymous recommendation request with an empty local list'
    );
    return replaceSectionExactly(
      content,
      `  _fetchAchievements = async () => {`,
      `  _notifyUserAboutEmailVerification = () => {`,
      `  _fetchAchievements = async () => {
    if (this.state.authenticatedUser.achievements) return;
    this.setState(({ authenticatedUser }) => ({
      authenticatedUser: {
        ...authenticatedUser,
        achievements: [],
      },
    }));
  };

`,
      'replace official achievements request with an empty local list'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/GDevelopServices/Generation.js',
  expectedGitBlobSha: '507201fddd7cccee11a650215385480db6026d48',
  transform: content =>
    replaceExactly(
      content,
      `export const fetchAiSettings = async ({
  environment,
}: {|
  environment: Environment,
|}): Promise<AiSettings> => {
  // $FlowFixMe[underconstrained-implicit-instantiation]
  const response = await axios.get(
    \`\${GDevelopAiCdn.baseUrl[environment]}/ai-settings-v2.json\`
  );
  return ensureObjectHasProperty({
    data: response.data,
    propertyName: 'aiRequest',
    endpointName: '/ai-settings-v2.json of Generation API',
  });
};`,
      `export const fetchAiSettings = async ({
  environment: _environment,
}: {|
  environment: Environment,
|}): Promise<AiSettings> => ({
  aiRequest: {
    presets: [],
  },
});`,
      'replace official AI settings CDN request with a local empty facade'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/GDevelopServices/Game.js',
  expectedGitBlobSha: '199fdf3ae3092562144328fbcda0e7dbe0823602',
  transform: content =>
    replaceExactly(
      content,
      `export const getGameCategories = async (): Promise<GameCategory[]> => {
  const response = await client.get('/game-category');
  return ensureIsArray({
    data: response.data,
    endpointName: '/game-category of Game API',
  });
};`,
      `export const getGameCategories = async (): Promise<GameCategory[]> =>
  [];`,
      'replace official game categories request with a local empty facade'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/Preferences/PreferencesProvider.js',
  expectedGitBlobSha: '904133d56900298ec400f5677e05420c9d975577',
  transform: content => {
    content = replaceExactly(
      content,
      `import { type GamesDashboardOrderBy } from '../../GameDashboard/GamesList';`,
      `import { type GamesDashboardOrderBy } from '../../GameDashboard/GamesList';
import {
  getPlaymeshInitialGDevelopLanguage,
  notifyPlaymeshGDevelopLanguageChanged,
} from '../../PlaymeshLocalization/PlaymeshLocalizationSession';`,
      'import the Playmesh session language bridge'
    );
    content = replaceExactly(
      content,
      `  const preferences =
    loadPreferencesFromLocalStorage() || getInitialPreferences();
  setLanguageInDOM(preferences.language);`,
      `  const preferences =
    loadPreferencesFromLocalStorage() || getInitialPreferences();
  const playmeshEntryLanguage = getPlaymeshInitialGDevelopLanguage();
  if (playmeshEntryLanguage) preferences.language = playmeshEntryLanguage;
  setLanguageInDOM(preferences.language);`,
      'make the App locale authoritative when entering GDevelop'
    );
    content = replaceExactly(
      content,
      `  componentDidMount() {
    this._periodicUpdateCheckTimeout = setTimeout(`,
      `  componentDidMount() {
    notifyPlaymeshGDevelopLanguageChanged(this.state.values.language);
    this._periodicUpdateCheckTimeout = setTimeout(`,
      'load Playmesh-only messages for the committed GDevelop language'
    );
    content = replaceExactly(
      content,
      `  _setLanguage(language: string) {
    setLanguageInDOM(language);
    this.setState(
      state => ({
        values: {
          ...state.values,
          language,
        },
      }),
      () => this._persistValuesToLocalStorage(this.state)
    );
  }`,
      `  _setLanguage(language: string) {
    setLanguageInDOM(language);
    this.setState(
      state => ({
        values: {
          ...state.values,
          language,
        },
      }),
      () => {
        this._persistValuesToLocalStorage(this.state);
        notifyPlaymeshGDevelopLanguageChanged(language);
      }
    );
  }`,
      'notify the Playmesh session without writing the App locale'
    );
    content = replaceExactly(
      content,
      `    // Do not store recent project in preferences as they will be accessible only from user account.
    if (newRecentFile.storageProviderName === 'Cloud') return;`,
      `    // Cloud and Playmesh project recents are authoritative outside this
    // Origin-scoped preference store. Only ordinary WebIDE recents belong here.
    if (
      newRecentFile.storageProviderName === 'Cloud' ||
      newRecentFile.storageProviderName === 'PlaymeshLocal'
    )
      return;`,
      'keep Playmesh active/recent project state exclusively in the App'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/i18n/GDI18nProvider.js',
  expectedGitBlobSha: 'dc4c2c6386e66804ecb2866a6e93962607ac69ca',
  transform: content => {
    content = replaceExactly(
      content,
      `import { type I18n as I18nType } from '@lingui/core';`,
      `import { type I18n as I18nType } from '@lingui/core';
import { playmeshLocalizationSession } from '../../PlaymeshLocalization/PlaymeshLocalizationSession';`,
      'import the active Playmesh localization session'
    );
    content = replaceExactly(
      content,
      `export default class GDI18nProvider extends React.Component<Props, State> {
  state: State = {`,
      `export default class GDI18nProvider extends React.Component<Props, State> {
  _languageLoadGeneration = 0;

  state: State = {`,
      'track asynchronous official catalog generations'
    );
    content = replaceExactly(
      content,
      `  async _loadLanguage(language: string) {
    const catalogs = await this._loadCatalog(language);
    this.setState(`,
      `  async _loadLanguage(language: string) {
    const generation = ++this._languageLoadGeneration;
    const [catalogs, preparedPlaymeshLanguage] = await Promise.all([
      this._loadCatalog(language),
      playmeshLocalizationSession.isActive()
        ? playmeshLocalizationSession.prepareGDevelopLanguage(language)
        : Promise.resolve(null),
    ]);
    if (generation !== this._languageLoadGeneration) return;
    if (preparedPlaymeshLanguage) {
      playmeshLocalizationSession.commitPreparedGDevelopLanguage(
        preparedPlaymeshLanguage
      );
    }
    this.setState(`,
      'atomically commit the latest official and Playmesh language catalogs'
    );
    content = replaceExactly(
      content,
      `    if (preparedPlaymeshLanguage) {
      playmeshLocalizationSession.commitPreparedGDevelopLanguage(
        preparedPlaymeshLanguage
      );
    }
    this.setState(`,
      `    if (preparedPlaymeshLanguage) {
      playmeshLocalizationSession.commitPreparedGDevelopLanguage(
        preparedPlaymeshLanguage
      );
    }

    // Native built-in object and behavior metadata is translated when libGD
    // registers the extensions, unlike React and JavaScript extension labels
    // which translate while rendering/loading. Install the new translation
    // function and re-register native metadata before publishing this locale
    // to the child tree. Otherwise an asynchronous entry locale (for example
    // en -> zh-CN) leaves Sprite, Text and the built-in behaviors in English.
    const nextI18n = setupI18n({
      language: language,
      catalogs,
    });
    gd.getTranslation = getTranslationFunction(nextI18n);
    gd.MeasurementUnit.applyTranslation();
    gd.JsPlatform.get().reloadBuiltinExtensions();

    this.setState(`,
      'translate native built-in extension metadata before publishing the locale'
    );
    content = replaceExactly(
      content,
      `        i18n: setupI18n({
          language: language,
          catalogs,
        }),`,
      `        i18n: nextI18n,`,
      'reuse the i18n instance already installed into libGD'
    );
    content = replaceExactly(
      content,
      `      () => {
        const { i18n } = this.state;
        gd.getTranslation = getTranslationFunction(i18n);
        console.info(\`Loaded "\${language}" language\`);
      }`,
      `      () => {
        console.info(\`Loaded "\${language}" language\`);
      }`,
      'avoid installing the libGD translation only after child components mount'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/scripts/service-worker-template/service-worker-template.js',
  expectedGitBlobSha: 'e1fd7eb24720691692e97476c82f3dda8dd3517d',
  transform: content => {
    content = replaceExactly(
      content,
      `  // Check if this is a request for a browser SW preview file
  if (url.pathname.startsWith('/browser_sw_preview/')) {
    const relativePath = url.pathname.replace('/browser_sw_preview', '');`,
      `  // Derive the preview root from this registration. Playmesh hosts each
  // WebIDE below /dev/{token}/gdevelop/, so origin-root matching is invalid.
  const registrationPath = new URL(self.registration.scope).pathname.replace(
    /\\/?$/,
    '/'
  );
  const previewPath = registrationPath + 'browser_sw_preview/';
  if (url.pathname.startsWith(previewPath)) {
    const relativePath = url.pathname.slice(previewPath.length - 1);`,
      'scope the local preview fetch handler to the current WebIDE directory'
    );
    const marker =
      '// ============================================================================\n' +
      '// Standard Workbox Configuration (for "semi-offline"/caching of GDevelop static files and resources)\n' +
      '// ============================================================================';
    const markerIndex = content.indexOf(marker);
    if (markerIndex === -1 || content.indexOf(marker, markerIndex + 1) !== -1) {
      throw new Error('Unable to isolate the official Workbox cache section');
    }
    return (
      content.slice(0, markerIndex) +
      '// Playmesh deliberately does not install a navigation or precache route.\n' +
      '// The dynamic GDevelop index must always reach the local Gateway so a fresh\n' +
      '// entry locale bootstrap can be injected. The IndexedDB preview handler\n' +
      '// above remains available without loading any third-party CDN script.\n'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/scripts/make-service-worker.js',
  expectedGitBlobSha: '11021c16d7291e85b2b1a0d4beb44eb24d09dec5',
  transform: content => {
    content = replaceExactly(
      content,
      `const workboxBuild = require('workbox-build');\n`,
      '',
      'remove the unused Workbox build dependency'
    );
    const start = content.indexOf('const buildSW = () => {');
    const end = content.indexOf('\n\ncleanBuildFiles().then(() => buildSW());');
    if (start === -1 || end === -1 || end <= start) {
      throw new Error(
        'Unable to isolate the official Workbox service worker build'
      );
    }
    return (
      content.slice(0, start) +
      `const buildSW = () => {\n  fs.copyFileSync(\n    'service-worker-template/service-worker-template.js',\n    '../public/service-worker.js'\n  );\n  console.log('Service worker built without navigation or precache routes.');\n  return Promise.resolve();\n};` +
      content.slice(end)
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/Toolbar/PreviewAndShareButtons.js',
  expectedGitBlobSha: '6c61b28e5c217895db23efdec125b690c4b1c853',
  transform: content =>
    replaceExactly(
      content,
      `          label={<Trans>Share</Trans>}`,
      `          label={<Trans>Publish</Trans>}`,
      'rename the editor toolbar action from Share to Publish'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/NewObjectDialog.js',
  expectedGitBlobSha: 'f0529ff9fa52073cbf79b0e2df84b7e16800b409',
  transform: content => {
    content = replaceExactly(
      content,
      `  const [currentTab, setCurrentTab] = React.useState(
    getNewObjectDialogDefaultTab()
  );`,
      `  const [currentTab, setCurrentTab] = React.useState('new-object');`,
      'always open the local object type list'
    );
    content = replaceExactly(
      content,
      `  const onObjectTypeSelected = React.useCallback(
    (enumeratedObjectMetadata: ObjectShortHeader) => {
      if (enumeratedObjectMetadata.assetStoreTag) {
        // When the object is from an asset store, display the objects from the pack
        // so that the user can either pick a similar object or skip to create a new one.
        setSelectedCustomObjectEnumeratedMetadata(enumeratedObjectMetadata);
      } else if (enumeratedObjectMetadata.requiredExtensions) {
        onInstallEmptyCustomObject(enumeratedObjectMetadata);
      } else {
        onCreateNewObject(enumeratedObjectMetadata.name);
      }
    },
    [onCreateNewObject, onInstallEmptyCustomObject]
  );`,
      `  const onObjectTypeSelected = React.useCallback(
    (enumeratedObjectMetadata: ObjectShortHeader) => {
      if (
        enumeratedObjectMetadata.requiredExtensions &&
        enumeratedObjectMetadata.requiredExtensions.length
      ) {
        onInstallEmptyCustomObject(enumeratedObjectMetadata);
      } else {
        onCreateNewObject(enumeratedObjectMetadata.name);
      }
    },
    [onCreateNewObject, onInstallEmptyCustomObject]
  );`,
      'create installed object types directly without opening an asset pack'
    );
    content = replaceExactly(
      content,
      `            fixedContent={
              <Tabs
                value={currentTab}
                onChange={setCurrentTab}
                options={[
                  {
                    label: <Trans>Asset Store</Trans>,
                    value: 'asset-store',
                    id: 'asset-store-tab',
                  },
                  {
                    label: <Trans>New object from scratch</Trans>,
                    value: 'new-object',
                    id: 'new-object-from-scratch-tab',
                  },
                ]}
                // Enforce scroll on mobile, because the tabs have long names.
                variant={isMobile ? 'scrollable' : undefined}
              />
            }`,
      `            fixedContent={null}`,
      'remove the asset store tab bar from new object creation'
    );
    content = replaceExactly(
      content,
      `            {currentTab === 'asset-store' && (
              <AssetStore ref={assetStore} onlyShowAssets />
            )}
            {currentTab === 'new-object' &&
              (selectedCustomObjectEnumeratedMetadata &&
              selectedCustomObjectEnumeratedMetadata.assetStoreTag ? (
                <CustomObjectPackResults
                  packTag={selectedCustomObjectEnumeratedMetadata.assetStoreTag}
                  onAssetSelect={async assetShortHeader => {
                    const result = await onInstallAsset(assetShortHeader);
                    if (result) {
                      handleClose();
                    }
                  }}
                  isAssetBeingInstalled={isAssetBeingInstalled}
                  onBack={() => setSelectedCustomObjectEnumeratedMetadata(null)}
                />
              ) : (
                <NewObjectFromScratch
                  project={project}
                  eventsFunctionsExtension={eventsFunctionsExtension}
                  eventsBasedObject={eventsBasedObject}
                  onObjectTypeSelected={onObjectTypeSelected}
                  i18n={i18n}
                />
              ))}`,
      `            <NewObjectFromScratch
              project={project}
              eventsFunctionsExtension={eventsFunctionsExtension}
              eventsBasedObject={eventsBasedObject}
              onObjectTypeSelected={onObjectTypeSelected}
              i18n={i18n}
            />`,
      'render only the local installed object type chooser'
    );
    content = replaceExactly(
      content,
      `import { Tabs } from '../UI/Tabs';\n`,
      '',
      'remove the unused asset store tab import'
    );
    content = replaceExactly(
      content,
      `import { AssetStore, type AssetStoreInterface } from '.';`,
      `import { type AssetStoreInterface } from '.';`,
      'retain only the asset store close-interface type'
    );
    content = replaceExactly(
      content,
      `import { useResponsiveWindowSize } from '../UI/Responsive/ResponsiveWindowMeasurer';\n`,
      '',
      'remove the unused asset store responsive-tab hook'
    );
    content = replaceExactly(
      content,
      `import NewObjectFromScratch, {
  CustomObjectPackResults,
} from './NewObjectFromScratch';`,
      `import NewObjectFromScratch from './NewObjectFromScratch';`,
      'remove the unused asset pack results component import'
    );
    content = replaceExactly(
      content,
      `  const { isMobile } = useResponsiveWindowSize();\n`,
      '',
      'remove the unused mobile asset store tab state'
    );
    content = replaceExactly(
      content,
      `  const {
    setNewObjectDialogDefaultTab,
    getNewObjectDialogDefaultTab,
  } = React.useContext(PreferencesContext);`,
      `  const { setNewObjectDialogDefaultTab } = React.useContext(
    PreferencesContext
  );`,
      'remove the unused online-store default tab getter'
    );
    content = replaceExactly(
      content,
      `  const [currentTab, setCurrentTab] = React.useState('new-object');`,
      `  const [currentTab] = React.useState<'asset-store' | 'new-object'>(
    'new-object'
  );`,
      'make the local object tab immutable'
    );
    content = replaceExactly(
      content,
      `  const [
    selectedCustomObjectEnumeratedMetadata,
    setSelectedCustomObjectEnumeratedMetadata,
  ] = React.useState<?ObjectShortHeader>(null);`,
      `  const [selectedCustomObjectEnumeratedMetadata] = React.useState<?ObjectShortHeader>(
    null
  );`,
      'remove the unreachable asset pack selection setter'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/NewObjectFromScratch.js',
  expectedGitBlobSha: 'f61eb4c91e4532e59c52b99e6d639da4d3af154a',
  transform: content =>
    replaceExactly(
      content,
      `            previewIconUrl: object.iconFilename,`,
      `            previewIconUrl: new URL(
              object.iconFilename,
              document.baseURI || window.location.href
            ).href,`,
      'resolve installed object icons from the packaged Web IDE root'
    ),
});

for (const registryPatch of [
  {
    relativePath: 'newIDE/app/src/AssetStore/ObjectStoreContext.js',
    expectedGitBlobSha: '6cb8619c0d9de0f98fc360c4250d98d789477c5c',
    from: `const objectsRegistry: ObjectsRegistry = await getObjectsRegistry();`,
    to: `const objectsRegistry: ObjectsRegistry = {
            headers: [],
            views: { default: { firstIds: [], secondIds: [] } },
          };`,
    description:
      'disable the online object registry while keeping installed objects',
  },
]) {
  await patchFile({
    relativePath: registryPatch.relativePath,
    expectedGitBlobSha: registryPatch.expectedGitBlobSha,
    transform: content => {
      content = replaceExactly(
        content,
        registryPatch.from,
        registryPatch.to,
        registryPatch.description
      );
      content = replaceExactly(
        content,
        `  getObjectsRegistry,\n`,
        '',
        'remove the unused online object registry import'
      );
      content = replaceExactly(
        content,
        `          console.info(
            \`Loaded \${
              objectShortHeaders ? objectShortHeaders.length : 0
            } objects from the extension store.\`
          );
`,
        '',
        'silence the expected empty Playmesh object store result'
      );
      return replaceExactly(
        content,
        `        console.info('Pre-fetching objects from extension store...');
`,
        '',
        'silence the disabled Playmesh object store prefetch info'
      );
    },
  });
}

await patchFile({
  relativePath: 'newIDE/app/src/UI/Search/UseSearchItem.js',
  expectedGitBlobSha: 'de32939166ba47679e953a7c67b74bffa2cd6f07',
  transform: content => {
    content = replaceExactly(
      content,
      `  const startTime = performance.now();
  // TODO do only one call to filter for efficiency.`,
      `  // TODO do only one call to filter for efficiency.`,
      'remove the unused search item filtering timer'
    );
    content = replaceExactly(
      content,
      `  const totalTime = performance.now() - startTime;
  console.info(
    \`Filtered items by category/filters in \${totalTime.toFixed(3)}ms.\`
  );
  return sortedSearchItems;`,
      `  return sortedSearchItems;`,
      'silence search item filtering timing info while preserving errors'
    );
    content = replaceExactly(
      content,
      `      if (!searchItemsById) {
        // Nothing to index - yet.
        return;
      }

      const startTime = performance.now();
`,
      `      if (!searchItemsById) {
        // Nothing to index - yet.
        return;
      }
`,
      'remove the unused search indexing timer'
    );
    content = replaceExactly(
      content,
      `        const totalTime = performance.now() - startTime;
        console.info(
          \`Indexed \${allIds.length} items in \${totalTime.toFixed(3)}ms.\`
        );
`,
      '',
      'silence expected object/search indexing timing info while preserving errors'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/UI/Search/UseSearchStructuredItem.js',
  expectedGitBlobSha: '61575b45dfc5437af35ec09c17cae71184965684',
  transform: content => {
    content = replaceExactly(
      content,
      `  const startTime = performance.now();
  const filteredSearchResults = searchResults`,
      `  const filteredSearchResults = searchResults`,
      'remove the unused structured search filtering timer'
    );
    content = replaceExactly(
      content,
      `  const totalTime = performance.now() - startTime;
  console.info(
    \`Filtered items by category/filters/tier in \${totalTime.toFixed(3)}ms.\`
  );
  return filteredSearchResults;`,
      `  return filteredSearchResults;`,
      'silence structured search filtering timing info'
    );
    content = replaceExactly(
      content,
      `      if (!searchItemsById) {
        // Nothing to index - yet.
        return;
      }

      const startTime = performance.now();
`,
      `      if (!searchItemsById) {
        // Nothing to index - yet.
        return;
      }
`,
      'remove the unused structured search indexing timer'
    );
    content = replaceExactly(
      content,
      `        const totalTime = performance.now() - startTime;
        console.info(
          \`Indexed \${
            Object.keys(searchItemsById).length
          } items in \${totalTime.toFixed(3)}ms.\`
        );
`,
      '',
      'silence expected structured search indexing timing info while preserving errors'
    );
    content = replaceExactly(
      content,
      `        const startTime = performance.now();
        const results = searchApi.search(`,
      `        const results = searchApi.search(`,
      'remove the unused structured search query timer'
    );
    return replaceExactly(
      content,
      `        const totalTime = performance.now() - startTime;
        console.info(
          \`Found \${results.length} items in \${totalTime.toFixed(3)}ms.\`
        );
        if (discardSearch) {`,
      `        if (discardSearch) {`,
      'silence structured search result timing while preserving readiness and discard diagnostics'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/GDevelopServices/Extension.js',
  expectedGitBlobSha: '51598f7e98af9a2466e8cfa24f63b001f985ac74',
  transform: content => {
    content = replaceExactly(
      content,
      `import { ensureIsArray } from '../DataValidator';`,
      `import { ensureIsArray } from '../DataValidator';
import {
  getPlaymeshBehaviorsRegistry,
  getPlaymeshExtension,
  getPlaymeshExtensionHeader,
  getPlaymeshExtensionsRegistry,
} from '../../PlaymeshCatalog/PlaymeshCatalogSource';`,
      'import the Playmesh version-locked extension catalog'
    );
    content = replaceExactly(
      content,
      `export const getExtensionsRegistry = async (): Promise<ExtensionsRegistry> => {
  const response = await client.get(\`/extension\`, {
    params: {
      // Could be changed according to the editor environment, but keep
      // reading from the "live" data for now.
      environment: 'live',
    },
  });
  const { databaseUrl } = response.data;

  const extensionsRegistry: ExtensionsRegistry = await retryIfFailed(
    { times: 2 },
    async () => (await cdnClient.get(databaseUrl)).data
  );

  if (!extensionsRegistry) {
    throw new Error('Unexpected response from the extensions endpoint.');
  }
  if (!extensionsRegistry.headers) {
    extensionsRegistry.headers = extensionsRegistry.extensionShortHeaders;
  }
  if (!extensionsRegistry.views.default.firstIds) {
    extensionsRegistry.views.default.firstIds =
      extensionsRegistry.views.default.firstExtensionIds;
  }
  for (const header of extensionsRegistry.headers) {
    if ((header.tier: string) === 'community') {
      header.tier = 'experimental';
    }
  }
  return {
    ...extensionsRegistry,
    // TODO: move this to backend endpoint
    // $FlowFixMe[incompatible-type]
    headers: extensionsRegistry.headers.map(transformTagsAsStringToTagsAsArray),
  };
};`,
      `export const getExtensionsRegistry = (): Promise<ExtensionsRegistry> =>
  getPlaymeshExtensionsRegistry();`,
      'delegate extension registry loading to the local Playmesh catalog'
    );
    content = replaceExactly(
      content,
      `export const getBehaviorsRegistry = async (): Promise<BehaviorsRegistry> => {
  const response = await client.get(\`/behavior\`, {
    params: {
      // Could be changed according to the editor environment, but keep
      // reading from the "live" data for now.
      environment: 'live',
    },
  });
  const { databaseUrl } = response.data;

  const behaviorsRegistry: BehaviorsRegistry = await retryIfFailed(
    { times: 2 },
    async () => (await cdnClient.get(databaseUrl)).data
  );

  if (!behaviorsRegistry) {
    throw new Error('Unexpected response from the behaviors endpoint.');
  }
  return {
    ...behaviorsRegistry,
    headers: behaviorsRegistry.headers.map(adaptBehaviorHeader),
  };
};`,
      `export const getBehaviorsRegistry = (): Promise<BehaviorsRegistry> =>
  getPlaymeshBehaviorsRegistry();`,
      'delegate behavior registry loading to the local Playmesh catalog'
    );
    content = replaceExactly(
      content,
      `export const getExtensionHeader = (
  extensionShortHeader:
    | ExtensionShortHeader
    | BehaviorShortHeader
    | ObjectShortHeader
): Promise<ExtensionHeader> => {
  return cdnClient.get(extensionShortHeader.headerUrl).then(response => {
    const data: ExtensionHeaderWithTagsAsString = response.data;
    const transformedData: ExtensionHeader = transformTagsAsStringToTagsAsArray(
      // $FlowFixMe[incompatible-type]
      data
    );
    if ((data.tier: string) === 'community') {
      data.tier = 'experimental';
    }
    return transformedData;
  });
};`,
      `export const getExtensionHeader = (
  extensionShortHeader:
    | ExtensionShortHeader
    | BehaviorShortHeader
    | ObjectShortHeader
): Promise<ExtensionHeader> =>
  getPlaymeshExtensionHeader(extensionShortHeader);`,
      'load extension details from the verified local catalog index'
    );
    content = replaceExactly(
      content,
      `export const getExtension = (
  extensionHeader: ExtensionShortHeader | BehaviorShortHeader
): Promise<SerializedExtension> => {
  return cdnClient.get(extensionHeader.url).then(response => {
    const data: SerializedExtensionWithTagsAsString = response.data;
    // $FlowFixMe[incompatible-type]
    const transformedData: SerializedExtension = transformTagsAsStringToTagsAsArray(
      // $FlowFixMe[incompatible-type]
      data
    );
    return transformedData;
  });
};`,
      `export const getExtension = (
  extensionHeader: ExtensionShortHeader | BehaviorShortHeader
): Promise<SerializedExtension> => getPlaymeshExtension(extensionHeader);`,
      'download extension bodies from the fixed official commit with verification'
    );
    content = replaceExactly(
      content,
      `/**
 * The ExtensionHeader returned by the API, with tags being a string
 * (which is kept in the API for compatibility with older GDevelop versions).
 */
type ExtensionHeaderWithTagsAsString = {
  ...ExtensionHeader,
  tags: string,
};

/**
 * The SerializedExtension returned by the API, with tags being a string
 * (which is kept in the API for compatibility with older GDevelop versions).
 */
type SerializedExtensionWithTagsAsString = {
  ...SerializedExtension,
  tags: string,
};

`,
      '',
      'remove obsolete online extension response types'
    );
    content = replaceExactly(
      content,
      `const adaptBehaviorHeader = (
  header: BehaviorShortHeader
): BehaviorShortHeader => {
  header.type = gd.PlatformExtension.getBehaviorFullType(
    header.extensionNamespace || header.extensionName,
    header.name
  );
  // $FlowFixMe[incompatible-type]
  header = transformTagsAsStringToTagsAsArray(header);
  if ((header.tier: string) === 'community') {
    header.tier = 'experimental';
  }
  return header;
};

`,
      '',
      'remove the unused online behavior registry adapter'
    );
    content = replaceExactly(
      content,
      `  /** This attribute is computed.
   * @see adaptBehaviorHeader
   */`,
      `  /** This attribute is computed by the catalog registry adapter. */`,
      'remove the stale behavior adapter documentation reference'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/AssetStore/ExtensionStore/ExtensionStoreContext.js',
  expectedGitBlobSha: '23a9c696b8b4d53f248e0e178992887f90a635eb',
  transform: content => {
    content = replaceExactly(
      content,
      `import { EXTENSIONS_FETCH_TIMEOUT } from '../../Utils/GlobalFetchTimeouts';\n`,
      '',
      'remove extension catalog background prefetch timeout'
    );
    content = replaceExactly(
      content,
      `      // Don't attempt to load again resources and filters if they
      // are loading or were loaded already in the current language.
      if (
        (Object.keys(translatedExtensionShortHeadersByName).length &&
          loadedLanguage === language) ||
        isLoading.current
      )
        return;
`,
      `      // Don't attempt to load again resources and filters if they
      // are loading or were loaded already in the current language.
      if (loadedLanguage === language || isLoading.current) return;
`,
      'treat an empty extension catalog as a completed load'
    );
    content = replaceExactly(
      content,
      `  React.useEffect(
    () => {
      // Don't attempt to load again extensions and filters if they
      // were loaded already.
      if (
        (Object.keys(translatedExtensionShortHeadersByName).length &&
          loadedLanguage === language) ||
        isLoading.current
      )
        return;

      const timeoutId = setTimeout(() => {
        console.info('Pre-fetching extensions from extension store...');
        fetchExtensionsAndFilters();
      }, EXTENSIONS_FETCH_TIMEOUT);
      return () => clearTimeout(timeoutId);
    },
    [
      fetchExtensionsAndFilters,
      translatedExtensionShortHeadersByName,
      isLoading,
      language,
      loadedLanguage,
    ]
  );

`,
      '',
      'load extension catalog only when its dialog explicitly requests it'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/AssetStore/BehaviorStore/BehaviorStoreContext.js',
  expectedGitBlobSha: '6cb1d8211fecf537d827256d5d7ee6d5982e5c54',
  transform: content => {
    content = replaceExactly(
      content,
      `import { BEHAVIORS_FETCH_TIMEOUT } from '../../Utils/GlobalFetchTimeouts';\n`,
      '',
      'remove behavior catalog background prefetch timeout'
    );
    content = replaceExactly(
      content,
      `      // Don't attempt to load again resources and filters if they
      // were loaded already.
      if (
        (Object.keys(translatedBehaviorShortHeadersByType).length &&
          loadedLanguage === language) ||
        isLoading.current
      )
        return;
`,
      `      // Don't attempt to load again resources and filters if they
      // were loaded already.
      if (loadedLanguage === language || isLoading.current) return;
`,
      'treat an empty behavior catalog as a completed load'
    );
    return replaceExactly(
      content,
      `  React.useEffect(
    () => {
      // Don't attempt to load again extensions and filters if they
      // were loaded already.
      if (
        (Object.keys(translatedBehaviorShortHeadersByType).length &&
          loadedLanguage === language) ||
        isLoading.current
      )
        return;

      const timeoutId = setTimeout(() => {
        console.info('Pre-fetching behaviors from extension store...');
        fetchBehaviors();
      }, BEHAVIORS_FETCH_TIMEOUT);
      return () => clearTimeout(timeoutId);
    },
    [
      fetchBehaviors,
      translatedBehaviorShortHeadersByType,
      isLoading,
      language,
      loadedLanguage,
    ]
  );

`,
      '',
      'load behavior catalog only when its dialog explicitly requests it'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/Bundles/BundleStoreContext.js',
  expectedGitBlobSha: '6cb8704dde01ec8bafc2d0fd6daa558371658f29',
  transform: content => {
    let next = replaceExactly(
      content,
      `import {
  listListedBundles,
  type BundleListingData,
} from '../../Utils/GDevelopServices/Shop';`,
      `import { type BundleListingData } from '../../Utils/GDevelopServices/Shop';`,
      'remove the disabled official bundle store request import'
    );
    next = replaceExactly(
      next,
      `          const fetchedBundleListingDatas = await listListedBundles();`,
      `          const fetchedBundleListingDatas: Array<BundleListingData> = [];`,
      'complete the disabled official bundle store with an empty local result'
    );
    return next;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/AssetStore/PrivateGameTemplates/PrivateGameTemplateStoreContext.js',
  expectedGitBlobSha: 'ef86be27d72ba9936ea86200ae5aa6320e170599',
  transform: content => {
    let next = replaceExactly(
      content,
      `import {
  listListedPrivateGameTemplates,
  type PrivateGameTemplateListingData,
} from '../../Utils/GDevelopServices/Shop';`,
      `import { type PrivateGameTemplateListingData } from '../../Utils/GDevelopServices/Shop';`,
      'remove the disabled official private template request import'
    );
    next = replaceExactly(
      next,
      `          const fetchedPrivateGameTemplateListingDatas = await listListedPrivateGameTemplates();`,
      `          const fetchedPrivateGameTemplateListingDatas: Array<PrivateGameTemplateListingData> = [];`,
      'complete the disabled official private template store with an empty local result'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/ExampleStore/ExampleStoreContext.js',
  expectedGitBlobSha: 'e0c3885ab523fe44efe3bf03e1856f20dcf8c6d7',
  transform: content => {
    content = replaceExactly(
      content,
      `import { EXAMPLES_FETCH_TIMEOUT } from '../../Utils/GlobalFetchTimeouts';\n`,
      '',
      'remove example catalog background prefetch timeout'
    );
    return replaceExactly(
      content,
      `  React.useEffect(
    () => {
      // Don't attempt to load again examples and filters if they
      // were loaded already.
      if (exampleShortHeadersById || isLoading.current) return;

      const timeoutId = setTimeout(() => {
        console.info('Pre-fetching examples from the example store...');
        fetchExamplesAndFilters();
      }, EXAMPLES_FETCH_TIMEOUT);
      return () => clearTimeout(timeoutId);
    },
    [fetchExamplesAndFilters, exampleShortHeadersById, isLoading]
  );

`,
      '',
      'keep the example catalog out of the editor startup path'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/Providers.js',
  expectedGitBlobSha: '0ebee82b3fa66b99de06bf9190c327c58044cc6b',
  transform: content => {
    content = replaceExactly(
      content,
      `import { CreditsPackageStoreStateProvider } from '../AssetStore/CreditsPackages/CreditsPackageStoreContext';
import { ProductLicenseStoreStateProvider } from '../AssetStore/ProductLicense/ProductLicenseStoreContext';
import { MarketingPlansStoreStateProvider } from '../MarketingPlans/MarketingPlansStoreContext';`,
      `import {
  PlaymeshCreditsPackageStoreStateProvider as CreditsPackageStoreStateProvider,
  PlaymeshProductLicenseStoreStateProvider as ProductLicenseStoreStateProvider,
  PlaymeshMarketingPlansStoreStateProvider as MarketingPlansStoreStateProvider,
} from './PlaymeshDisabledCommercialProviders';`,
      'disable unsupported commerce requests at the root Provider boundary'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/UseNewProjectDialog.js',
  expectedGitBlobSha: '8c9273b1fd3b4e41da1f62ef6c162a0df4280553',
  transform: content => {
    content = replaceExactly(
      content,
      `import { type FileMetadata, type StorageProvider } from '../ProjectsStorage';`,
      `import {
  type FileMetadata,
  type FileMetadataAndStorageProviderName,
  type StorageProvider,
} from '../ProjectsStorage';`,
      'type the Playmesh example project opener passed through the dialog hook'
    );
    content = replaceExactly(
      content,
      `  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
|};`,
      `  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
  onOpenPlaymeshProject: (
    file: FileMetadataAndStorageProviderName
  ) => Promise<void>,
|};`,
      'declare the explicit Playmesh example project opener on the dialog hook'
    );
    content = replaceExactly(
      content,
      `  onOpenLayout,
  onWillInstallExtension,
  onExtensionInstalled,
}: Props): _UseNewProjectDialogReturnType => {`,
      `  onOpenLayout,
  onWillInstallExtension,
  onExtensionInstalled,
  onOpenPlaymeshProject,
}: Props): _UseNewProjectDialogReturnType => {`,
      'read the Playmesh example project opener in the dialog hook'
    );
    return replaceExactly(
      content,
      `            onWillInstallExtension={onWillInstallExtension}
            onExtensionInstalled={onExtensionInstalled}
          />`,
      `            onWillInstallExtension={onWillInstallExtension}
            onExtensionInstalled={onExtensionInstalled}
            onOpenPlaymeshProject={onOpenPlaymeshProject}
          />`,
      'forward the Playmesh example project opener to project creation'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ProjectCreation/NewProjectSetupDialog.js',
  expectedGitBlobSha: 'e2675eed07c8c303864a48e9f7f43568e980e5df',
  transform: content => {
    content = replaceExactly(
      content,
      `import { isNativeMobileApp } from '../Utils/Platform';\n`,
      '',
      'remove the unused native mobile platform import from project creation'
    );
    content = replaceExactly(
      content,
      `const electron = optionalRequire('electron');\n`,
      '',
      'remove the unused Electron availability flag from project creation'
    );
    content = replaceExactly(
      content,
      `  type SaveAsLocation,
  type FileMetadata,
} from '../ProjectsStorage';`,
      `  type SaveAsLocation,
  type FileMetadata,
  type FileMetadataAndStorageProviderName,
} from '../ProjectsStorage';`,
      'type the Playmesh example project opener in project creation'
    );
    content = replaceExactly(
      content,
      `import { AiRequestContext } from '../AiGeneration/AiRequestContext';`,
      `import { AiRequestContext } from '../AiGeneration/AiRequestContext';
import PlaymeshNewProjectCatalog from './PlaymeshNewProjectCatalog';`,
      'embed the App-backed official example catalog in project creation'
    );
    content = replaceExactly(
      content,
      `  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
|};`,
      `  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
  onOpenPlaymeshProject: (
    file: FileMetadataAndStorageProviderName
  ) => Promise<void>,
|};`,
      'declare the Playmesh example project opener in project creation'
    );
    content = replaceExactly(
      content,
      `  onOpenLayout,
  onWillInstallExtension,
  onExtensionInstalled,
}: Props): React.Node => {`,
      `  onOpenLayout,
  onWillInstallExtension,
  onExtensionInstalled,
  onOpenPlaymeshProject,
}: Props): React.Node => {`,
      'read the Playmesh example project opener in project creation'
    );
    content = replaceExactly(
      content,
      `      const localFileStorageProvider = storageProviders.find(
        ({ internalName }) => internalName === 'LocalFile'
      );`,
      `      const localFileStorageProvider = storageProviders.find(
        ({ internalName }) =>
          internalName === 'PlaymeshLocal' || internalName === 'LocalFile'
      );`,
      'treat Playmesh local storage as the local project provider'
    );
    content = replaceExactly(
      content,
      `  const { aiRequestStorage } = React.useContext(AiRequestContext);
  const { isSendingAiRequest } = aiRequestStorage;
  const isLoading = isProjectOpening || isSendingAiRequest('');`,
      `  const { aiRequestStorage } = React.useContext(AiRequestContext);
  const { isSendingAiRequest } = aiRequestStorage;
  const [
    isImportingPlaymeshExample,
    setIsImportingPlaymeshExample,
  ] = React.useState<boolean>(false);
  const isLoading =
    isProjectOpening ||
    isSendingAiRequest('') ||
    isImportingPlaymeshExample;`,
      'lock project creation while the App-backed example import is running'
    );
    content = replaceSectionExactly(
      content,
      `            {isOnHomePage && (`,
      `            {!isOnHomePage &&`,
      `            {isOnHomePage && (
              <ColumnStackLayout noMargin>
                <EmptyAndStartingPointProjects
                  onSelectExampleShortHeader={exampleShortHeader => {
                    onSelectExampleShortHeader(exampleShortHeader);
                  }}
                  onSelectEmptyProject={() => {
                    setEmptyProjectSelected(true);
                  }}
                  disabled={isLoading}
                  onSeeAll={() => {
                    setStartersSelected(true);
                  }}
                  title={
                    isAskAiStandAloneFormHidden ? (
                      <Trans>Start from a template</Trans>
                    ) : (
                      <Trans>Continue with Human Intelligence</Trans>
                    )
                  }
                />
                <PlaymeshNewProjectCatalog
                  i18n={i18n}
                  disabled={isLoading}
                  onOpenProject={onOpenPlaymeshProject}
                  onImported={onClose}
                  onImportingChange={setIsImportingPlaymeshExample}
                />
              </ColumnStackLayout>
            )}
`,
      'replace online templates with the resilient App-backed official catalog'
    );
    content = replaceExactly(
      content,
      `  const shouldAllowCreatingProjectWithoutSaving =
    !electron && !selectedPrivateGameTemplateListingData;`,
      `  const shouldAllowCreatingProjectWithoutSaving = false;`,
      'require new projects to use persistent local storage'
    );
    content = replaceExactly(
      content,
      `                  {!electron && !isNativeMobileApp() && (
                    <SelectOption
                      value={'FakeLocalFile'}
                      label={t\`Save on your computer: download GDevelop desktop app\`}
                      disabled
                    />
                  )}
                  {shouldAllowCreatingProjectWithoutSaving && (
                    <SelectOption
                      value={emptyStorageProvider.internalName}
                      label={t\`Don't save this project now\`}
                    />
                  )}`,
      '',
      'remove desktop download and unsaved project choices'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/stories/componentStories/ProjectCreation/NewProjectSetupDialog.stories.js',
  expectedGitBlobSha: '453efe099e042060ed6f9a6c5fe590113a7db1b4',
  transform: content => {
    const needle = `      <NewProjectSetupDialog\n`;
    const occurrences = content.split(needle).length - 1;
    if (occurrences !== 8) {
      throw new Error(
        `Expected 8 NewProjectSetupDialog story fixtures, found ${occurrences}`
      );
    }
    return content.replaceAll(
      needle,
      `      <NewProjectSetupDialog\n        onOpenPlaymeshProject={async () => {}}\n`
    );
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/ProjectsStorage/OpenFromStorageProviderDialog.js',
  expectedGitBlobSha: 'd89794d6e2c8c080a191b508753483c215fa0187',
  transform: content => {
    content = replaceExactly(
      content,
      `import { Trans, t } from '@lingui/macro';`,
      `import { Trans } from '@lingui/macro';`,
      'remove the unused desktop option translation import'
    );
    content = replaceExactly(
      content,
      `import Computer from '../UI/CustomSvgIcons/Computer';
import { isNativeMobileApp } from '../Utils/Platform';
import optionalRequire from '../Utils/OptionalRequire';
const electron = optionalRequire('electron');
`,
      '',
      'remove desktop-only open project imports'
    );
    content = replaceExactly(
      content,
      `const fakeLocalFileStorageProvider: StorageProvider = {
  internalName: 'LocalFile',
  name: t\`Open from computer with GDevelop desktop app\`,
  disabled: true,
  renderIcon: props => <Computer fontSize={props.size} />,
  createOperations: () => ({}),
};

`,
      '',
      'remove fake desktop storage provider'
    );
    content = replaceExactly(
      content,
      `            {!electron && !isNativeMobileApp() && (
              <StorageProviderListItem
                onChooseProvider={onChooseProvider}
                storageProvider={fakeLocalFileStorageProvider}
              />
            )}`,
      '',
      'remove fake desktop open option'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/ProjectsStorage/DownloadFileStorageProvider/DownloadFileSaveAsDialog.js',
  expectedGitBlobSha: 'ed12f40520acb711c1243a8ce0663c22f1698a1e',
  transform: content => {
    content = replaceExactly(
      content,
      `            } else {
              // Public URL resource: nothing to do.
              return null;
            }`,
      `            } else if (resourceFile.startsWith('blob:')) {
              // Playmesh local projects keep device resources as blob URLs while
              // editing. Include these in the official portable project archive.
              return {
                resource,
                url: resourceFile,
                filename: resource.getName(),
              };
            } else {
              // Public URL resource: nothing to do.
              return null;
            }`,
      'include Playmesh local blobs in downloaded official project archives'
    );
    content = replaceExactly(
      content,
      `import { serializeToJSObject } from '../../Utils/Serializer';\n`,
      `import { createPlaymeshDownloadProjectArchive } from './PlaymeshDownloadProjectArchive';\n`,
      'route portable project creation through the shared initialized archive boundary'
    );
    content = replaceExactly(
      content,
      `import {
  archiveFiles,
  type BlobFileDescriptor,
  type TextFileDescriptor,
} from '../../Utils/BrowserArchiver';`,
      `import { type BlobFileDescriptor } from '../../Utils/BrowserArchiver';`,
      'keep archiving implementation owned by the shared download boundary'
    );
    content = replaceExactly(
      content,
      `        const newProject = gd.ProjectHelper.createNewGDJSProject();
        try {
          // Make a copy of the project, as it will be updated.
          const serializedProject = new gd.SerializerElement();
          project.serializeTo(serializedProject);
          newProject.unserializeFrom(serializedProject);
          serializedProject.delete();

          // Download resources to blobs, and update the project resources.
          const blobFiles: Array<BlobFileDescriptor> = [];
          const textFiles: Array<TextFileDescriptor> = [];
          await ensureProcessIsDone({
            project: newProject,
            onAddBlobFile: (blobFileDescriptor: BlobFileDescriptor) => {
              blobFiles.push(blobFileDescriptor);
            },
          });

          // Serialize the project.
          textFiles.push({
            text: JSON.stringify(serializeToJSObject(newProject)),
            filePath: PROJECT_JSON_FILENAME,
          });

          // Archive the whole project.
          const zippedProjectBlob = await archiveFiles({
            textFiles,
            blobFiles,
            basePath: '/',
            onProgress: (count: number, total: number) => {},
          });
          setZippedProjectBlob(zippedProjectBlob);
        } catch (rawError) {`,
      `        try {
          const zippedProjectBlob = await createPlaymeshDownloadProjectArchive({
            project,
            gdImplementation: gd,
            downloadResources: ({ project: projectCopy, onAddBlobFile }) =>
              ensureProcessIsDone({
                project: projectCopy,
                onAddBlobFile,
              }),
          });
          setZippedProjectBlob(zippedProjectBlob);
        } catch (rawError) {`,
      'initialize, clone, download and archive through one testable boundary'
    );
    content = replaceExactly(
      content,
      `        } finally {
          newProject.delete();
        }
`,
      `        }
`,
      'let the shared archive boundary own temporary project cleanup'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/GameEngineFinder/BrowserS3GDJSFinder.js',
  expectedGitBlobSha: 'b1650bc98933e7eb9847164d17d5bb82f07c1366',
  transform: content => {
    content = replaceExactly(
      content,
      `import Window from '../Utils/Window';
import { getIDEVersionWithHash } from '../Version';
`,
      '',
      'remove online Runtime version imports'
    );
    return replaceExactly(
      content,
      `  // Get GDJS for this version. If you updated the version,
  // run \`newIDE/web-app/scripts/deploy-GDJS-Runtime\` script.
  let gdjsRoot = \`https://resources.gdevelop-app.com/GDJS-\${getIDEVersionWithHash()}\`;

  if (Window.isDev()) {
    gdjsRoot =
      window.location.hostname === 'localhost'
        ? // Served by \`watch-serve-GDJS-runtime.js\` when running the IDE locally.
          \`http://localhost:5002\`
        : // On a deployed development build (e.g. editor-dev), use the runtime
          // bundled with the build (see \`copy-GDJS-Runtime-to-build.js\`).
          // Fetching localhost from a public origin would trigger the browser
          // "Local Network Access" permission prompt and fail for anyone
          // not running a local server.
          \`\${window.location.origin}/GDJS\`;
  }`,
      `  // Playmesh packages the exact GDJS Runtime built from this pinned source.
  // Keep this relative to document.baseURI so the Web IDE also works in a subdirectory.
  const documentBaseUri: string =
    document.baseURI || window.location.href;
  const gdjsRoot = new URL('./GDJS', documentBaseUri).href.replace(/\\/$/, '');`,
      'load GDJS Runtime from the local Web IDE package'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/BlobDownloader.js',
  expectedGitBlobSha: '40779c73fd8a1b6a11bc60f8ada3d2cf325bb3ae',
  transform: content =>
    replaceExactly(
      content,
      `        const urlWithParameters = addSearchParameterToUrl(
          url,
          'gdUsage',
          'export'
        );`,
      `        // The gdUsage cache-busting parameter exists for cross-origin
        // S3/CDN CORS behavior. Playmesh serves its packaged GDJS Runtime and
        // project resources from the same local Gateway origin, where the
        // parameter is unnecessary and can interfere with native WebViews.
        let isSameOrigin = false;
        try {
          isSameOrigin =
            new URL(url, window.location.href).origin === window.location.origin;
        } catch (error) {
          // Preserve the official behavior for unusual external URL schemes.
        }
        const urlWithParameters = isSameOrigin
          ? url
          : addSearchParameterToUrl(url, 'gdUsage', 'export');`,
      'avoid the cross-origin export query workaround for local Gateway files'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/BlobDownloadUrlHolder.js',
  expectedGitBlobSha: '8646b5ed0c2396267c6ac95614fdbc1a8769c770',
  transform: content =>
    replaceExactly(
      content,
      `export const openBlobDownloadUrl = (url: string, filename: string) => {
  const { body } = document;`,
      `export const openBlobDownloadUrl = (url: string, filename: string) => {
  // App WebViews cannot reliably hand blob: anchors to the host download
  // manager. The Playmesh host injects this hook and streams the generated
  // Blob through its authenticated local Gateway to a native save surface.
  // A regular browser never has the hook and keeps the official anchor path.
  const nativeBlobSaver = (window: any).__playmeshSaveBlobDownload;
  if (typeof nativeBlobSaver === 'function') {
    nativeBlobSaver({ url, filename });
    return;
  }

  // WebView2 suppresses its native download prompt in the Playmesh host. If
  // an older host opens this newer WebIDE without injecting the save hook,
  // fail visibly instead of handing the Blob to a silent anchor download.
  // Ordinary browsers do not expose chrome.webview and keep the official
  // fallback below.
  const chromeWebView = (window: any).chrome && (window: any).chrome.webview;
  if (chromeWebView && typeof chromeWebView.postMessage === 'function') {
    const isChinese = (window.navigator.language || '')
      .toLowerCase()
      .startsWith('zh');
    const message = isChinese
      ? 'Playmesh 系统文件保存服务未连接，请更新并重启 App 后重试。'
      : 'Native file saving is unavailable. Update and restart Playmesh, then try again.';
    console.error('[PlaymeshNativeFileSave] native_file_save_bridge_missing');
    window.alert(message);
    return;
  }

  const { body } = document;`,
      'handoff generated Blob downloads to the native Playmesh WebView host'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/BrowserArchiver.js',
  expectedGitBlobSha: '5842055026aa5c1a12ebd54e21713aa03afec218',
  transform: content =>
    replaceExactly(
      content,
      `    urlContainers: urlFiles.filter(({ url }) => url.indexOf('.h') === -1), // Should be useless now, still keep it by safety.`,
      `    urlContainers: urlFiles.filter(({ url, filePath }) => {
      // Source maps are optional debugger metadata. Playmesh intentionally
      // removes them from the installed WebIDE package, so they must not be
      // treated as required preview/publish runtime files.
      const urlPath = url.split(/[?#]/, 1)[0];
      return (
        url.indexOf('.h') === -1 &&
        !filePath.endsWith('.map') &&
        !urlPath.endsWith('.map')
      );
    }),`,
      'exclude optional source maps from browser preview and export downloads'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/ResourcesList/BrowserResourceSources.js',
  expectedGitBlobSha: '16a9cee0e12e099a7a94d65401ea59dc95f82829',
  transform: content => {
    content = replaceExactly(
      content,
      `import { FileToCloudProjectResourceUploader } from './FileToCloudProjectResourceUploader';`,
      `import FileToPlaymeshLocalResourceUploader from './FileToPlaymeshLocalResourceUploader';`,
      'replace the GDevelop Cloud resource uploader with the Playmesh local picker'
    );
    return replaceExactly(
      content,
      `      renderComponent: (props: ResourceSourceComponentProps) => (
        <FileToCloudProjectResourceUploader
          createNewResource={createNewResource}
          onChooseResources={(resources: Array<gdResource>) =>
            props.onChooseResources({
              selectedResources: resources,
              selectedSourceName: sourceName,
            })
          }
          options={props.options}
          fileMetadata={props.fileMetadata}
          getStorageProvider={props.getStorageProvider}
          key={\`url-chooser-\${kind}\`}
          automaticallyOpenInput={!!props.automaticallyOpenIfPossible}
        />
      ),`,
      `      renderComponent: (props: ResourceSourceComponentProps) => (
        <FileToPlaymeshLocalResourceUploader
          createNewResource={createNewResource}
          onChooseResources={(resources: Array<gdResource>) =>
            props.onChooseResources({
              selectedResources: resources,
              selectedSourceName: sourceName,
            })
          }
          options={props.options}
          automaticallyOpenInput={!!props.automaticallyOpenIfPossible}
        />
      ),`,
      'use the local device resource picker for every browser project source'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ResourcesEditor/index.js',
  expectedGitBlobSha: '35d37156928745a2f9dfedb2b4732dbe7362da94',
  transform: content => {
    content = replaceExactly(
      content,
      `import { getResourceFilePathStatus } from '../ResourcesList/ResourceUtils';`,
      `import {
  applyResourceDefaults,
  getResourceFilePathStatus,
} from '../ResourcesList/ResourceUtils';`,
      'reuse the official resource defaults when importing from the resources editor'
    );
    content = replaceExactly(
      content,
      `  onResourceExternallyChanged = (resourceInfo: {| identifier: string |}) => {
    if (this._propertiesEditor) {
      this._propertiesEditor.forceUpdate();
    }
    this.refreshResourcesList();
  };

  render(): any {`,
      `  onResourceExternallyChanged = (resourceInfo: {| identifier: string |}) => {
    if (this._propertiesEditor) {
      this._propertiesEditor.forceUpdate();
    }
    this.refreshResourcesList();
  };

  uploadResources = async (resourceKind: ResourceKind): Promise<void> => {
    const { project, resourceManagementProps } = this.props;
    try {
      const {
        selectedResources,
        selectedSourceName,
      } = await resourceManagementProps.onChooseResource({
        initialSourceName: 'upload-' + resourceKind,
        multiSelection: true,
        resourceKind,
      });
      if (!selectedResources.length) return;

      const selectedSource = resourceManagementProps.resourceSources.find(
        source => source.name === selectedSourceName
      );
      if (!selectedSource || !selectedSource.shouldCreateResource) {
        selectedResources.forEach(resource => resource.delete());
        return;
      }

      let hasCreatedAnyResource = false;
      try {
        selectedResources.forEach(resource => {
          applyResourceDefaults(project, resource);
          hasCreatedAnyResource =
            project.getResourcesManager().addResource(resource) ||
            hasCreatedAnyResource;
        });
      } finally {
        // addResource copies the resource. The official caller owns deletion.
        selectedResources.forEach(resource => resource.delete());
      }

      if (!hasCreatedAnyResource) return;
      await resourceManagementProps.onFetchNewlyAddedResources();
      resourceManagementProps.onNewResourcesAdded();
      this.refreshResourcesList();
    } catch (error) {
      // Resource sources surface actionable errors in their own UI.
      console.error('Unable to upload resources from the resources editor', error);
    }
  };

  render(): any {`,
      'add a resources-editor caller for the official multi-selection import seam'
    );
    return replaceExactly(
      content,
      `            onRemoveAllResourcesWithInvalidPath={
              this._removeAllResourcesWithInvalidPath
            }
            getResourceActionsSpecificToStorageProvider={`,
      `            onRemoveAllResourcesWithInvalidPath={
              this._removeAllResourcesWithInvalidPath
            }
            onUploadResources={this.uploadResources}
            getResourceActionsSpecificToStorageProvider={`,
      'pass the official upload caller to the resources search toolbar'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ObjectsRendering/PixiResourcesLoader.js',
  expectedGitBlobSha: '6b2a9cbe2e7fd746c287e3f26f05f759638b75bd',
  transform: content => {
    content = replaceExactly(
      content,
      `import { type ResourceKind } from '../ResourcesList/ResourceSource';`,
      `import { type ResourceKind } from '../ResourcesList/ResourceSource';
import { getPlaymeshPixiTextureAsset } from '../PlaymeshResources/PlaymeshPixiTextureAsset';`,
      'provide Pixi with an explicit parser for extensionless local Blob image URLs'
    );
    return replaceExactly(
      content,
      `          const loadedTexture = await PIXI.Assets.load(url);`,
      `          const loadedTexture = await PIXI.Assets.load(
            getPlaymeshPixiTextureAsset(url)
          );`,
      'load local Blob images through the built-in Pixi texture parser'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ResourcesList/index.js',
  expectedGitBlobSha: '80d2e9f618e25f1759fdc5c0d8af9e98c796d3d8',
  transform: content => {
    content = replaceExactly(
      content,
      `import { t } from '@lingui/macro';`,
      `import { t, Trans } from '@lingui/macro';`,
      'translate the resources upload action with the active GDevelop locale'
    );
    content = replaceExactly(
      content,
      `import SortableVirtualizedItemList from '../UI/SortableVirtualizedItemList';`,
      `import SortableVirtualizedItemList from '../UI/SortableVirtualizedItemList';
import ElementWithMenu from '../UI/Menu/ElementWithMenu';
import RaisedButton from '../UI/RaisedButton';
import Upload from '../UI/CustomSvgIcons/Upload';`,
      'reuse the official menu, button, and upload icon in the resources search row'
    );
    content = replaceExactly(
      content,
      `  onRemoveAllResourcesWithInvalidPath: () => void,
  getResourceActionsSpecificToStorageProvider?: ?ResourcesActionsMenuBuilder,`,
      `  onRemoveAllResourcesWithInvalidPath: () => void,
  onUploadResources: ResourceKind => Promise<void>,
  getResourceActionsSpecificToStorageProvider?: ?ResourcesActionsMenuBuilder,`,
      'declare the official resource-kind upload callback'
    );
    content = replaceExactly(
      content,
      `        onRenameResource,
        fileMetadata,
        onRemoveUnusedResources,
        getResourceActionsSpecificToStorageProvider,`,
      `        onRenameResource,
        fileMetadata,
        onRemoveUnusedResources,
        onUploadResources,
        getResourceActionsSpecificToStorageProvider,`,
      'receive the resources editor upload callback'
    );
    content = replaceExactly(
      content,
      `      const [infoBarContent, setInfoBarContent] = React.useState(null);
      const sortableListRef = React.useRef(null);`,
      `      const [infoBarContent, setInfoBarContent] = React.useState(null);
      const [isUploadingResources, setIsUploadingResources] = React.useState(
        false
      );
      const sortableListRef = React.useRef(null);`,
      'prevent overlapping resource picker operations'
    );
    content = replaceExactly(
      content,
      `      // Force List component to be mounted again if project
      // has been changed. Avoid accessing to invalid objects that could
      // crash the app.
      const listKey = project.ptr;`,
      `      const readUploadResourceKind = (
        value: string
      ): ?ResourceKind => {
        switch (value) {
          case 'audio':
          case 'image':
          case 'font':
          case 'video':
          case 'json':
          case 'tilemap':
          case 'tileset':
          case 'bitmapFont':
          case 'model3D':
          case 'atlas':
          case 'spine':
          case 'javascript':
            return value;
          default:
            return null;
        }
      };

      const uploadResources = React.useCallback(
        async (resourceKind: ResourceKind): Promise<void> => {
          if (isUploadingResources) return;
          setIsUploadingResources(true);
          try {
            await onUploadResources(resourceKind);
          } finally {
            setIsUploadingResources(false);
          }
        },
        [isUploadingResources, onUploadResources]
      );

      // Force List component to be mounted again if project
      // has been changed. Avoid accessing to invalid objects that could
      // crash the app.
      const listKey = project.ptr;`,
      'run one official multi-file picker operation at a time'
    );
    return replaceExactly(
      content,
      `            <Column expand>
              <SearchBar
                value={searchText}
                onRequestSearch={() => {}}
                onChange={text => setSearchText(text)}
                placeholder={t\`Search resources\`}
              />
            </Column>
          </Line>`,
      `            <Column expand>
              <SearchBar
                value={searchText}
                onRequestSearch={() => {}}
                onChange={text => setSearchText(text)}
                placeholder={t\`Search resources\`}
              />
            </Column>
            <ElementWithMenu
              element={
                <RaisedButton
                  primary
                  icon={<Upload />}
                  label={<Trans>Upload resources</Trans>}
                  disabled={isUploadingResources}
                  onClick={null}
                />
              }
              buildMenuTemplate={(i18n: I18nType) =>
                allResourceKindsAndMetadata.map(({ kind, displayName }) => ({
                  label: i18n._(displayName),
                  click: () => {
                    const resourceKind = readUploadResourceKind(kind);
                    if (resourceKind) uploadResources(resourceKind);
                  },
                }))
              }
            />
          </Line>`,
      'add an official resource-kind menu beside the resources search field'
    );
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/stories/componentStories/ResourcesList/ResourcesList.stories.js',
  expectedGitBlobSha: '19a9e4c43bf95546f17ce6e6bd53ecdde76faaf9',
  transform: content =>
    replaceExactly(
      content,
      `            onRemoveAllResourcesWithInvalidPath={action(
              'onRemoveAllResourcesWithInvalidPath'
            )}
            fileMetadata={null}`,
      `            onRemoveAllResourcesWithInvalidPath={action(
              'onRemoveAllResourcesWithInvalidPath'
            )}
            onUploadResources={async () => {}}
            fileMetadata={null}`,
      'provide the official resource upload callback in the ResourcesList story'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/ProjectCreation/CreateProject.js',
  expectedGitBlobSha: 'ffe728f7de38e48c25658f3eb6e616d4e7db5b3a',
  transform: content =>
    replaceExactly(
      content,
      `  const project: gdProject = gd.ProjectHelper.createNewGDJSProject();

  const exampleSlug = 'empty-project';`,
      `  const project: gdProject = gd.ProjectHelper.createNewGDJSProject();
  // Playmesh empty projects keep the official loading logo but do not add
  // an in-game watermark. Imported examples retain their authored setting.
  project.getWatermark().showGDevelopWatermark(false);

  const exampleSlug = 'empty-project';`,
      'disable the in-game watermark only for newly created empty Playmesh projects'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/UseCreateProject.js',
  expectedGitBlobSha: '001e774e471da10a0eb8f285513b8995b1c009c2',
  transform: content =>
    replaceExactly(
      content,
      `  const createEmptyProject = React.useCallback(
    async (newProjectSetup: NewProjectSetup): Promise<CreateProjectResult> => {
      beforeCreatingProject();
      const newProjectSource = createNewEmptyProject({
        creationSource: newProjectSetup.creationSource,
      });
      return await createProject(newProjectSource, newProjectSetup);
    },
    [beforeCreatingProject, createProject]
  );`,
      `  const createEmptyProject = React.useCallback(
    async (newProjectSetup: NewProjectSetup): Promise<CreateProjectResult> => {
      beforeCreatingProject();
      let creationDelegated = false;
      try {
        const newProjectSource = createNewEmptyProject({
          creationSource: newProjectSetup.creationSource,
        });
        creationDelegated = true;
        return await createProject(newProjectSource, newProjectSetup);
      } finally {
        // createProject owns this callback after delegation. If construction of
        // the in-memory empty project throws synchronously, release the create
        // loading state here instead of leaving the dialog permanently busy.
        if (!creationDelegated) onSuccessOrError();
      }
    },
    [beforeCreatingProject, createProject, onSuccessOrError]
  );`,
      'release empty-project loading when source construction fails before createProject'
    ),
});

await patchFile({
  relativePath:
    'newIDE/app/src/ProjectsStorage/ResourceMover/BrowserResourceMover.js',
  expectedGitBlobSha: 'bf96aa19d34bad4861a28b81619b2689a42157d5',
  transform: content => {
    content = replaceExactly(
      content,
      `import DownloadFileStorageProvider from '../DownloadFileStorageProvider';`,
      `import DownloadFileStorageProvider from '../DownloadFileStorageProvider';
import PlaymeshLocalStorageProvider from '../PlaymeshLocalStorageProvider';`,
      'import Playmesh local storage for resource moves'
    );
    content = replaceExactly(
      content,
      `const moveNothing = async () => {
  return {
    erroredResources: [],
  };
};`,
      `const moveNothing = async (
  _options: MoveAllProjectResourcesOptions
): Promise<MoveAllProjectResourcesResult> => ({
  erroredResources: [],
});`,
      'type the no-op Playmesh resource mover against the complete mover contract'
    );
    return replaceExactly(
      content,
      `const movers: {
  [string]: MoveAllProjectResourcesFunction,
} = {`,
      `const movers: {
  [string]: MoveAllProjectResourcesFunction,
} = {
  [\`\${PlaymeshLocalStorageProvider.internalName}=>\${
    PlaymeshLocalStorageProvider.internalName
  }\`]: moveNothing,
  [\`\${UrlStorageProvider.internalName}=>\${
    PlaymeshLocalStorageProvider.internalName
  }\`]: moveNothing,
  [\`\${PlaymeshLocalStorageProvider.internalName}=>\${
    DownloadFileStorageProvider.internalName
  }\`]: moveNothing,`,
      'register Playmesh local resource move paths'
    );
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/ProjectsStorage/ResourceFetcher/BrowserResourceFetcher.js',
  expectedGitBlobSha: 'd58dd58489a06afbe844dc74391219ca8fb9087b',
  transform: content => {
    content = replaceExactly(
      content,
      `import UrlStorageProvider from '../UrlStorageProvider';`,
      `import UrlStorageProvider from '../UrlStorageProvider';
import PlaymeshLocalStorageProvider from '../PlaymeshLocalStorageProvider';`,
      'import Playmesh local storage for resource fetching'
    );
    content = replaceExactly(
      content,
      `const fetchers: {
  [string]: FetchAllProjectResourcesFunction,
} = {`,
      `const fetchNothing = async (
  _options: FetchAllProjectResourcesOptions
): Promise<FetchAllProjectResourcesResult> => ({
  erroredResources: [],
});

const fetchers: {
  [string]: FetchAllProjectResourcesFunction,
} = {
  [PlaymeshLocalStorageProvider.internalName]: fetchNothing,`,
      'register Playmesh local resource fetcher'
    );
    return content;
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/MainFrame/EditorContainers/HomePage/HomePageMenu.js',
  expectedGitBlobSha: '4114ec02800badb323cad8506ed7ea2ce23ccc1b',
  transform: content => {
    content = replaceExactly(
      content,
      `import GDevelopGLogo from '../../../UI/CustomSvgIcons/GDevelopGLogo';`,
      `import InfoOutlinedIcon from '@material-ui/icons/InfoOutlined';`,
      'use a neutral information icon for the Playmesh editor notice'
    );
    content = replaceExactly(
      content,
      `type Props = {|
  setActiveTab: HomeTab => void,
  activeTab: HomeTab,
  onOpenPreferences: () => void,
  onOpenAbout: () => void,
|};`,
      `type Props = {|
  setActiveTab: HomeTab => void,
  activeTab: HomeTab,
  onOpenPreferences: () => void,
  onOpenAbout: () => void,
  aboutLabel?: React.Node,
|};`,
      'accept the localized Playmesh editor notice label'
    );
    content = replaceExactly(
      content,
      `export const HomePageMenu = ({
  setActiveTab,
  activeTab,
  onOpenPreferences,
  onOpenAbout,
}: Props): React.MixedElement => {`,
      `export const HomePageMenu = ({
  setActiveTab,
  activeTab,
  onOpenPreferences,
  onOpenAbout,
  aboutLabel,
}: Props): React.MixedElement => {`,
      'read the localized Playmesh editor notice label'
    );
    content = replaceExactly(
      content,
      `    {
      label: <Trans>About GDevelop</Trans>,
      id: 'about-gdevelop',
      onClick: onOpenAbout,
      getIcon: ({ color, fontSize }) => (
        <GDevelopGLogo fontSize={fontSize} color={color} />
      ),
    },`,
      `    {
      label: aboutLabel || <Trans>About this editor</Trans>,
      id: 'about-playmesh-editor',
      onClick: onOpenAbout,
      getIcon: ({ color, fontSize }) => (
        <InfoOutlinedIcon fontSize={fontSize} htmlColor={color} />
      ),
    },`,
      'replace the GDevelop about entry with the Playmesh editor notice entry'
    );
    content = replaceExactly(
      content,
      `      <HomePageMenuBar
        activeTab={activeTab}
        onOpenAbout={onOpenAbout}
        onOpenHomePageMenuDrawer={() => setIsHomePageMenuDrawerOpen(true)}`,
      `      <HomePageMenuBar
        activeTab={activeTab}
        aboutLabel={aboutLabel}
        onOpenAbout={onOpenAbout}
        onOpenHomePageMenuDrawer={() => setIsHomePageMenuDrawerOpen(true)}`,
      'forward the localized Playmesh editor notice label to the compact menu'
    );
    content = replaceExactly(
      content,
      `import {
  shouldHideClassroomTab,
  type Limits,
} from '../../../Utils/GDevelopServices/Usage';`,
      `import { type Limits } from '../../../Utils/GDevelopServices/Usage';`,
      'remove the unused classroom policy import'
    );
    content = replaceExactly(
      content,
      `import { isNativeMobileApp } from '../../../Utils/Platform';\n`,
      '',
      'remove the unused native mobile platform import'
    );
    content = replaceExactly(
      content,
      `  const displayPlayTab =
    !limits ||
    !(
      limits.capabilities.classrooms &&
      limits.capabilities.classrooms.hidePlayTab
    );`,
      '',
      'disable the GDevelop games platform tab'
    );
    content = replaceExactly(
      content,
      `  const displayShopTab =
    !limits ||
    !(
      limits.capabilities.classrooms &&
      limits.capabilities.classrooms.hidePremiumProducts
    );`,
      '',
      'disable the GDevelop shop tab'
    );
    content = replaceExactly(
      content,
      `  const displayTeachTab =
    !shouldHideClassroomTab(limits) && !isNativeMobileApp();`,
      '',
      'disable the GDevelop classroom tab'
    );
    return replaceExactly(
      content,
      `  const tabs: HomeTab[] = [
    'learn',
    'create',
    displayPlayTab ? 'play' : null,
    displayShopTab ? 'shop' : null,
    displayTeachTab ? 'team-view' : null,
  ].filter(Boolean);`,
      `  const tabs: HomeTab[] = ['create'];`,
      'keep only the local Create tab on the Playmesh home page'
    );
  },
});

await patchFile({
  relativePath:
    'newIDE/app/src/MainFrame/EditorContainers/HomePage/HomePageMenuBar.js',
  expectedGitBlobSha: '57d14d0f4ffb545b9d46922ac854464c337d9973',
  transform: content => {
    let patched = replaceExactly(
      content,
      `import GDevelopGLogo from '../../../UI/CustomSvgIcons/GDevelopGLogo';`,
      `import InfoOutlinedIcon from '@material-ui/icons/InfoOutlined';`,
      'use a neutral information icon for the Playmesh editor notice'
    );
    patched = replaceExactly(
      patched,
      `type Props = {|
  setActiveTab: HomeTab => void,
  activeTab: HomeTab,
  onOpenPreferences: () => void,
  onOpenAbout: () => void,
  onOpenHomePageMenuDrawer: () => void,
|};`,
      `type Props = {|
  setActiveTab: HomeTab => void,
  activeTab: HomeTab,
  onOpenPreferences: () => void,
  onOpenAbout: () => void,
  aboutLabel: React.Node,
  onOpenHomePageMenuDrawer: () => void,
|};`,
      'accept the localized Playmesh editor notice label'
    );
    patched = replaceExactly(
      patched,
      `const HomePageMenuBar = ({
  setActiveTab,
  activeTab,
  onOpenPreferences,
  onOpenAbout,
  onOpenHomePageMenuDrawer,
}: Props): React.Node => {`,
      `const HomePageMenuBar = ({
  setActiveTab,
  activeTab,
  onOpenPreferences,
  onOpenAbout,
  aboutLabel,
  onOpenHomePageMenuDrawer,
}: Props): React.Node => {`,
      'read the localized Playmesh editor notice label'
    );
    patched = replaceExactly(
      patched,
      `    {
      label: <Trans>About GDevelop</Trans>,
      id: 'about-gdevelop',
      onClick: onOpenAbout,
      getIcon: ({ color, fontSize }) => (
        <GDevelopGLogo fontSize={fontSize} color={color} />
      ),
    },`,
      `    {
      label: aboutLabel,
      id: 'about-playmesh-editor',
      onClick: onOpenAbout,
      getIcon: ({ color, fontSize }) => (
        <InfoOutlinedIcon fontSize={fontSize} htmlColor={color} />
      ),
    },`,
      'replace the desktop GDevelop about entry with the Playmesh editor notice entry'
    );
    return replaceExactly(
      patched,
      `            })}
          </ToolbarGroup>`,
      `            })}
            <div
              style={{
                ...styles.buttonContainer,
                borderTop: '3px solid transparent',
                color: gdevelopTheme.text.color.secondary,
              }}
            >
              <button
                type="button"
                style={{
                  ...styles.mobileButton,
                  border: 0,
                  background: 'transparent',
                  color: 'inherit',
                }}
                onClick={onOpenAbout}
                id="about-playmesh-editor"
              >
                <Column noMargin>
                  <span style={styles.icon}>
                    <InfoOutlinedIcon fontSize="inherit" />
                  </span>
                  <Text size="body-small" color="inherit" noMargin>
                    {aboutLabel}
                  </Text>
                </Column>
              </button>
            </div>
          </ToolbarGroup>`,
      'keep the Playmesh editor notice reachable from the mobile bottom bar'
    );
  },
});

await patchFile({
  relativePath: 'GDJS/Runtime/events-tools/storagetools.ts',
  expectedGitBlobSha: 'd61394d79c78e787f488ae63e4185ffff5c9dee3',
  transform: content => {
    content = replaceExactly(
      content,
      `      if (!localStorage) {
        logger.error(
          "Storage actions won't work as no localStorage was found."
        );
      }

      /** The stored objects that are loaded in memory */`,
      `      if (!localStorage) {
        logger.error(
          "Storage actions won't work as no localStorage was found."
        );
      }

      const playmeshGDevelopRootKey = '$playmesh.gdevelop.root.v1';
      const getPlaymeshStorageBucket = (name: string): any | null => {
        if (typeof window === 'undefined') return null;
        const playmesh = (window as any).playmesh;
        if (typeof playmesh === 'undefined') return null;
        const storage = playmesh && playmesh.main && playmesh.main.storage;
        if (!storage || typeof storage.getBucket !== 'function') {
          throw new Error(
            '不兼容的 PlayMesh Game SDK：GDevelop 需要 4.1.0 的同步存储能力。'
          );
        }
        const bucket = storage.getBucket(name);
        if (
          !bucket ||
          typeof bucket.getDataSync !== 'function' ||
          typeof bucket.setDataSync !== 'function'
        ) {
          throw new Error(
            '不兼容的 PlayMesh Game SDK：GDevelop 同步存储不可用。'
          );
        }
        return bucket;
      };

      /** The stored objects that are loaded in memory */`,
      'add a lazy fail-closed Playmesh synchronous Bucket capability resolver'
    );
    content = replaceExactly(
      content,
      `        let serializedString: string | null = null;
        try {
          if (localStorage) {
            serializedString = localStorage.getItem('GDJS_' + name);
          }
        } catch (error) {
          logger.error(
            'Unable to load data from localStorage for "' + name + '": ' + error
          );
        }`,
      `        let serializedString: string | null = null;
        const playmeshBucket = getPlaymeshStorageBucket(name);
        if (playmeshBucket) {
          const rootObject = playmeshBucket.getDataSync(
            playmeshGDevelopRootKey
          );
          serializedString =
            rootObject === null ? null : JSON.stringify(rootObject);
        } else {
          try {
            if (localStorage) {
              serializedString = localStorage.getItem('GDJS_' + name);
            }
          } catch (error) {
            logger.error(
              'Unable to load data from localStorage for "' + name + '": ' + error
            );
          }
        }`,
      'read the exact GDevelop root through the Playmesh sync Bucket when present'
    );
    return replaceExactly(
      content,
      `        try {
          if (localStorage) {
            localStorage.setItem('GDJS_' + name, serializedString);
          }
        } catch (error) {
          logger.error(
            'Unable to save data to localStorage for "' + name + '": ' + error
          );
        }`,
      `        const playmeshBucket = getPlaymeshStorageBucket(name);
        if (playmeshBucket) {
          playmeshBucket.setDataSync(playmeshGDevelopRootKey, jsObject);
        } else {
          try {
            if (localStorage) {
              localStorage.setItem('GDJS_' + name, serializedString);
            }
          } catch (error) {
            logger.error(
              'Unable to save data to localStorage for "' + name + '": ' + error
            );
          }
        }`,
      'write the exact GDevelop root through the Playmesh sync Bucket when present'
    );
  },
});

await patchFile({
  relativePath: 'Extensions/Multiplayer/peerJsHelper.ts',
  expectedGitBlobSha: 'dfd4a73aa4b272e6eccea2aa3f288b5778ca76b5',
  transform: content => {
    let patched = replaceExactly(
      content,
      `    type PeerJSInitOptions = {
      onPeerUnavailable?: () => void;
    };

    /** @category Multiplayer */`,
      `    type PeerJSInitOptions = {
      onPeerUnavailable?: () => void;
    };

    const getPlaymeshMultiplayerBackend = (): any | null => {
      const runtimeGlobal = globalThis as any;
      const registry = runtimeGlobal[
        Symbol.for('playmesh.runtime.backends.v1')
      ];
      if (!registry) {
        if (runtimeGlobal.playmesh) {
          throw new Error(
            'Incompatible Playmesh runtime: GDevelop Multiplayer backend v1 is unavailable.'
          );
        }
        return null;
      }
      if (typeof registry.negotiate !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: invalid backend registry.'
        );
      }
      const backend = registry.negotiate({
        engine: 'gdevelop',
        engineVersion: '5.6.276',
        feature: 'multiplayer',
        minVersion: 1,
        maxVersion: 1,
      });
      if (!backend || typeof backend.createOfficialPeer !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: GDevelop Multiplayer peer backend v1 is unavailable.'
        );
      }
      return backend;
    };

    /** @category Multiplayer */`,
      'add a private allowlisted Playmesh peer backend resolver'
    );
    patched = replaceExactly(
      patched,
      `      peer = new Peer(peerConfig);`,
      `      const playmeshBackend = getPlaymeshMultiplayerBackend();
      peer = playmeshBackend
        ? playmeshBackend.createOfficialPeer()
        : new Peer(peerConfig);`,
      'replace the unique Peer construction seam with the private facade'
    );
    return patched;
  },
});

await patchFile({
  relativePath: 'Extensions/Multiplayer/multiplayertools.ts',
  expectedGitBlobSha: 'ffd474906ff9b3c8d01ba46b499347656f31558f',
  transform: content => {
    let patched = replaceExactly(
      content,
      `  const getTimeNow =
    window.performance && typeof window.performance.now === 'function'
      ? window.performance.now.bind(window.performance)
      : Date.now;

  const fetchAsPlayer = async ({`,
      `  const getTimeNow =
    window.performance && typeof window.performance.now === 'function'
      ? window.performance.now.bind(window.performance)
      : Date.now;

  const getPlaymeshLobbyBackend = (): any | null => {
    const runtimeGlobal = globalThis as any;
    const registry = runtimeGlobal[
      Symbol.for('playmesh.runtime.backends.v1')
    ];
    if (!registry) {
      if (runtimeGlobal.playmesh) {
        throw new Error(
          'Incompatible Playmesh runtime: GDevelop Multiplayer backend v1 is unavailable.'
        );
      }
      return null;
    }
    if (typeof registry.negotiate !== 'function') {
      throw new Error('Incompatible Playmesh runtime: invalid backend registry.');
    }
    const backend = registry.negotiate({
      engine: 'gdevelop',
      engineVersion: '5.6.276',
      feature: 'multiplayer',
      minVersion: 1,
      maxVersion: 1,
    });
    if (
      !backend ||
      typeof backend.request !== 'function' ||
      typeof backend.createOfficialLobbyControlFacade !== 'function' ||
      typeof backend.configureOfficialLobbyFrame !== 'function' ||
      typeof backend.consumeOfficialLobbyFrameMessage !== 'function' ||
      typeof backend.handleOfficialLobbyFrameMessage !== 'function' ||
      typeof backend.postOfficialLobbyFrameMessage !== 'function' ||
      typeof backend.notifyOfficialLobbyFrameClosed !== 'function'
    ) {
      throw new Error(
        'Incompatible Playmesh runtime: incomplete GDevelop Multiplayer backend v1.'
      );
    }
    return backend;
  };

  const parsePlaymeshRequestBody = (body?: string): any => {
    if (body === undefined) return {};
    const parsed = JSON.parse(body);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('Invalid GDevelop Multiplayer request body.');
    }
    return parsed;
  };

  const requestPlaymeshLobbyBackend = async ({
    relativeUrl,
    method,
    body,
  }: {
    relativeUrl: string;
    method: 'GET' | 'POST';
    body?: string;
  }): Promise<any | null> => {
    const backend = getPlaymeshLobbyBackend();
    if (!backend) return null;
    const url = new URL(relativeUrl, 'https://playmesh.invalid');
    const pathSegments = url.pathname.split('/').filter(Boolean);
    if (
      pathSegments.length < 5 ||
      pathSegments[0] !== 'play' ||
      pathSegments[1] !== 'game' ||
      pathSegments[3] !== 'public-lobby'
    ) {
      throw new Error('Unsupported GDevelop Multiplayer lobby operation.');
    }
    const gameId = decodeURIComponent(pathSegments[2]);
    const requestBody = parsePlaymeshRequestBody(body);
    let operation;
    let payload;
    if (
      method === 'POST' &&
      pathSegments.length === 6 &&
      pathSegments[4] === 'action' &&
      pathSegments[5] === 'quick-join'
    ) {
      operation = 'quickJoin';
      payload = Object.assign({}, requestBody, { gameId });
    } else if (method === 'GET' && pathSegments.length === 5) {
      operation = 'getLobbyById';
      payload = { gameId, lobbyId: decodeURIComponent(pathSegments[4]) };
    } else if (
      method === 'POST' &&
      pathSegments.length === 7 &&
      pathSegments[5] === 'action' &&
      pathSegments[6] === 'heartbeat'
    ) {
      operation = 'heartbeat';
      payload = Object.assign(
        {},
        requestBody,
        { gameId, lobbyId: decodeURIComponent(pathSegments[4]) }
      );
    } else if (
      method === 'POST' &&
      pathSegments.length === 7 &&
      pathSegments[5] === 'action' &&
      pathSegments[6] === 'end'
    ) {
      operation = 'endGame';
      payload = { gameId, lobbyId: decodeURIComponent(pathSegments[4]) };
    } else if (
      pathSegments.length === 6 &&
      pathSegments[5] === 'lobby-change-host-request'
    ) {
      operation = 'migrateHost';
      payload = Object.assign(
        {},
        method === 'POST' ? requestBody : {},
        {
          gameId,
          lobbyId: decodeURIComponent(pathSegments[4]),
          mode: method === 'GET' ? 'read' : 'write',
          peerId: url.searchParams.get('peerId') || requestBody.peerId || '',
        }
      );
    } else {
      throw new Error('Unsupported GDevelop Multiplayer lobby operation.');
    }
    const result = await backend.request(operation, payload);
    return {
      ok: true,
      status: 200,
      statusText: 'OK',
      text: async () =>
        result === undefined || result === null
          ? 'OK'
          : JSON.stringify(result),
    };
  };

  const createPlaymeshLobbyControl = (url: string): WebSocket => {
    const backend = getPlaymeshLobbyBackend();
    return (backend
      ? backend.createOfficialLobbyControlFacade()
      : new WebSocket(url)) as any;
  };

  const postOfficialLobbyFrameMessage = (
    iframe: HTMLIFrameElement,
    message: any,
    targetOrigin: string
  ): void => {
    const backend = getPlaymeshLobbyBackend();
    if (backend) {
      backend.postOfficialLobbyFrameMessage(iframe, message);
      return;
    }
    if (iframe.contentWindow) {
      iframe.contentWindow.postMessage(message, targetOrigin);
    }
  };

  const fetchAsPlayer = async ({`,
      'add the private allowlisted Playmesh lobby backend adapter'
    );
    patched = replaceExactly(
      patched,
      `    const response = await fetch(formattedUrl, {
      method,
      headers,
      body,
    });`,
      `    const playmeshResponse = await requestPlaymeshLobbyBackend({
      relativeUrl,
      method,
      body,
    });
    const response =
      playmeshResponse ||
      (await fetch(formattedUrl, {
        method,
        headers,
        body,
      }));`,
      'route the exact lobby HTTP seam through the private facade'
    );
    patched = replaceExactly(
      patched,
      `      const url = \`\${rootApi}/game/public-game/\${gameId}\`;
      return fetch(url, { method: 'HEAD' }).then(`,
      `      const url = \`\${rootApi}/game/public-game/\${gameId}\`;
      const playmeshBackend = getPlaymeshLobbyBackend();
      const registrationRequest = playmeshBackend
        ? playmeshBackend
            .request('checkGameRegistration', { gameId })
            .then(result => ({
              status: result && result.registered === true ? 200 : 404,
              statusText:
                result && result.registered === true ? 'OK' : 'Not Found',
            }))
        : fetch(url, { method: 'HEAD' });
      return registrationRequest.then(`,
      'route the game registration seam through the private facade'
    );
    patched = replaceExactly(
      patched,
      `      _websocket = new WebSocket(wsUrl.toString());`,
      `      _websocket = createPlaymeshLobbyControl(wsUrl.toString());`,
      'replace the exact lobby WebSocket construction seam'
    );
    patched = replaceExactly(
      patched,
      `      _websocket.onmessage = (event) => {`,
      `      _websocket.onmessage = async (event) => {`,
      'make the official lobby callback observable by the private facade'
    );
    patched = replaceExactly(
      patched,
      `              try {
                gdjs.evtTools.network.retryIfFailed(retryData, async () => {
                  handlePeerIdEvent({ peerId, compressionMethod });
                });
              } catch (error) {`,
      `              try {
                await gdjs.evtTools.network.retryIfFailed(
                  retryData,
                  async () => {
                    handlePeerIdEvent({ peerId, compressionMethod });
                  }
                );
              } catch (error) {`,
      'await the official peerId retry so callback failures stay contained'
    );
    patched = replaceExactly(
      patched,
      `        try {
          gdjs.evtTools.network.retryIfFailed(retryData, async () => {
            sendPeerId();
            handleStartGameMessage();
          });
        } catch (error) {
          logger.error(
            \`Sending of peerId message from websocket failed (after {\${retryData.times}} times with a delay of \${retryData.delayInMs}ms). Not trying anymore.\`
          );
        }`,
      `        void gdjs.evtTools.network
          .retryIfFailed(retryData, async () => {
            sendPeerId();
            handleStartGameMessage();
          })
          .catch(() => {
            logger.error(
              \`Sending of peerId message from websocket failed (after {\${retryData.times}} times with a delay of \${retryData.delayInMs}ms). Not trying anymore.\`
            );
          });`,
      'contain the official quick-start retry rejection'
    );
    patched = replaceExactly(
      patched,
      `    export const removeLobbiesContainer = function (
      runtimeScene: gdjs.RuntimeScene
    ) {
      removeLobbiesCallbacks();
      gdjs.multiplayerComponents.removeLobbiesContainer(runtimeScene);
    };`,
      `    export const removeLobbiesContainer = function (
      runtimeScene: gdjs.RuntimeScene
    ) {
      removeLobbiesCallbacks();
      gdjs.multiplayerComponents.removeLobbiesContainer(runtimeScene);
      getPlaymeshLobbyBackend()?.notifyOfficialLobbyFrameClosed();
    };`,
      'acknowledge the exact official lobby frame close boundary'
    );
    patched = replaceExactly(
      patched,
      `      _lobbiesMessageCallback = (event: MessageEvent) => {
        receiveLobbiesMessage(runtimeScene, event, {
          checkOrigin: true,
        });
      };`,
      `      _lobbiesMessageCallback = (event: MessageEvent) => {
        const playmeshBackend = getPlaymeshLobbyBackend();
        if (playmeshBackend) {
          playmeshBackend.handleOfficialLobbyFrameMessage(
            event,
            (receivedEvent: MessageEvent) => {
              receiveLobbiesMessage(runtimeScene, receivedEvent, {
                checkOrigin: false,
              });
            }
          );
          return;
        }
        receiveLobbiesMessage(runtimeScene, event, {
          checkOrigin: true,
        });
      };`,
      'validate the exact local lobby frame receive seam before the official state machine'
    );
    patched = replaceAllExactly(
      patched,
      `lobbiesIframe.contentWindow.postMessage(`,
      `postOfficialLobbyFrameMessage(
        lobbiesIframe,`,
      5,
      'route every official lobby frame output through the private capability'
    );
    return patched;
  },
});

await patchFile({
  relativePath: 'Extensions/Multiplayer/multiplayercomponents.ts',
  expectedGitBlobSha: '1ba58f95a6f59add9033724c5ef601c5f2b02696',
  transform: content => {
    let patched = replaceExactly(
      content,
      `  export namespace multiplayerComponents {
    const loaderContainerId = 'loader-container';`,
      `  export namespace multiplayerComponents {
    const getPlaymeshLobbyFrameBackend = (): any | null => {
      const runtimeGlobal = globalThis as any;
      const registry = runtimeGlobal[
        Symbol.for('playmesh.runtime.backends.v1')
      ];
      if (!registry) {
        if (runtimeGlobal.playmesh) {
          throw new Error(
            'Incompatible Playmesh runtime: GDevelop Multiplayer frame backend v1 is unavailable.'
          );
        }
        return null;
      }
      if (typeof registry.negotiate !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: invalid backend registry.'
        );
      }
      const backend = registry.negotiate({
        engine: 'gdevelop',
        engineVersion: '5.6.276',
        feature: 'multiplayer',
        minVersion: 1,
        maxVersion: 1,
      });
      if (!backend || typeof backend.configureOfficialLobbyFrame !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: GDevelop Multiplayer frame backend v1 is unavailable.'
        );
      }
      return backend;
    };

    const loaderContainerId = 'loader-container';`,
      'add the private lobby frame navigation resolver'
    );
    patched = replaceExactly(
      patched,
      `      iframe.src = url;`,
      `      const playmeshBackend = getPlaymeshLobbyFrameBackend();
      if (playmeshBackend) {
        playmeshBackend.configureOfficialLobbyFrame(iframe);
      } else {
        iframe.src = url;
      }`,
      'replace the unique lobby iframe navigation seam'
    );
    return patched;
  },
});

await patchFile({
  relativePath:
    'Extensions/PlayerAuthentication/playerauthenticationtools.ts',
  expectedGitBlobSha: 'c3aabe47feb2782d560ff45af8915cc87eebbd6f',
  transform: content => {
    let patched = replaceExactly(
      content,
      `  export namespace playerAuthentication {
    // Authentication information.`,
      `  export namespace playerAuthentication {
    const getPlaymeshPlayerAuthenticationBackend = (): any | null => {
      const runtimeGlobal = globalThis as any;
      const registry = runtimeGlobal[
        Symbol.for('playmesh.runtime.backends.v1')
      ];
      if (!registry) {
        if (runtimeGlobal.playmesh) {
          throw new Error(
            'Incompatible Playmesh runtime: GDevelop player authentication backend v1 is unavailable.'
          );
        }
        return null;
      }
      if (typeof registry.negotiate !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: invalid backend registry.'
        );
      }
      const backend = registry.negotiate({
        engine: 'gdevelop',
        engineVersion: '5.6.276',
        feature: 'playerAuthentication',
        minVersion: 1,
        maxVersion: 1,
      });
      if (
        !backend ||
        typeof backend.readOfficialIdentity !== 'function' ||
        typeof backend.writeOfficialIdentity !== 'function' ||
        typeof backend.removeOfficialIdentity !== 'function' ||
        typeof backend.checkGameRegistration !== 'function' ||
        typeof backend.createOfficialAuthenticationControlFacade !==
          'function' ||
        typeof backend.consumeOfficialAuthenticationFrameMessage !==
          'function'
      ) {
        throw new Error(
          'Incompatible Playmesh runtime: incomplete GDevelop player authentication backend v1.'
        );
      }
      return backend;
    };

    // Authentication information.`,
      'add the private allowlisted Playmesh identity backend resolver'
    );
    patched = replaceExactly(
      patched,
      `      const url = \`${'${rootApi}'}/game/public-game/${'${gameId}'}\`;
      return fetch(url, { method: 'HEAD' }).then(`,
      `      const url = \`${'${rootApi}'}/game/public-game/${'${gameId}'}\`;
      const playmeshBackend = getPlaymeshPlayerAuthenticationBackend();
      const registrationRequest = playmeshBackend
        ? Promise.resolve(
            playmeshBackend.checkGameRegistration({ gameId })
          ).then(result => ({
            status: result && result.registered === true ? 200 : 404,
            statusText:
              result && result.registered === true ? 'OK' : 'Not Found',
          }))
        : fetch(url, { method: 'HEAD' });
      return registrationRequest.then(`,
      'route the exact player-auth registration HEAD seam through the private facade'
    );
    patched = replaceExactly(
      patched,
      `        _websocket = new WebSocket(wsPlayApi);`,
      `        const playmeshBackend =
          getPlaymeshPlayerAuthenticationBackend();
        _websocket = (playmeshBackend
          ? playmeshBackend.createOfficialAuthenticationControlFacade()
          : new WebSocket(wsPlayApi)) as any;`,
      'replace the exact player-auth WebSocket construction seam'
    );
    patched = replaceExactly(
      patched,
      `        ({ connectionId }) => {
          const targetUrl = getAuthWindowUrl({`,
      `        ({ connectionId }) => {
          if (getPlaymeshPlayerAuthenticationBackend()) return;
          const targetUrl = getAuthWindowUrl({`,
      'prevent Electron from navigating to the official auth endpoint when the private facade is active'
    );
    patched = replaceExactly(
      patched,
      `        ({ connectionId, resolve }) => {
          const targetUrl = getAuthWindowUrl({`,
      `        ({ connectionId, resolve }) => {
          if (getPlaymeshPlayerAuthenticationBackend()) return;
          const targetUrl = getAuthWindowUrl({`,
      'prevent Cordova from navigating to the official auth endpoint when the private facade is active'
    );
    patched = replaceExactly(
      patched,
      `        _authenticationMessageCallback = (event: MessageEvent) => {
          receiveAuthenticationMessage({
            runtimeScene,
            event,
            checkOrigin: true,
            onDone: (status) => {
              if (isDoneAlready) return;
              isDoneAlready = true;
              resolve(status);
            },
          });
        };`,
      `        _authenticationMessageCallback = (event: MessageEvent) => {
          const playmeshBackend =
            getPlaymeshPlayerAuthenticationBackend();
          const receivedEvent = playmeshBackend
            ? playmeshBackend.consumeOfficialAuthenticationFrameMessage(event)
            : event;
          if (!receivedEvent) return;
          receiveAuthenticationMessage({
            runtimeScene,
            event: receivedEvent,
            checkOrigin: !playmeshBackend,
            onDone: (status) => {
              if (isDoneAlready) return;
              isDoneAlready = true;
              resolve(status);
            },
          });
        };`,
      'validate the local popup-auth frame receive seam before official login handling'
    );
    patched = replaceExactly(
      patched,
      `        const openWindow = () => {
          _authenticationWindow = window.open(
            targetUrl,
            'authentication',
            windowFeatures
          );
        };`,
      `        const openWindow = () => {
          const playmeshBackend =
            getPlaymeshPlayerAuthenticationBackend();
          if (playmeshBackend) {
            if (
              !_authenticationIframeContainer ||
              !_authenticationLoaderContainer ||
              !_authenticationTextContainer
            ) {
              throw new Error(
                'GDevelop PlayerAuthentication local frame container is unavailable.'
              );
            }
            authComponents.displayIframeInsideAuthenticationContainer(
              _authenticationIframeContainer,
              _authenticationLoaderContainer,
              _authenticationTextContainer,
              targetUrl
            );
            return;
          }
          _authenticationWindow = window.open(
            targetUrl,
            'authentication',
            windowFeatures
          );
        };`,
      'replace the exact web popup navigation seam with the local auth frame when active'
    );
    patched = replaceExactly(
      patched,
      `        _authenticationMessageCallback = (event: MessageEvent) => {
          receiveAuthenticationMessage({
            runtimeScene,
            event,
            checkOrigin: true,
            onDone: resolve,
          });
        };
        window.addEventListener(
          'message',
          _authenticationMessageCallback,
          true
        );

        authComponents.displayIframeInsideAuthenticationContainer(
          _authenticationIframeContainer,
          _authenticationLoaderContainer,
          _authenticationTextContainer,
          targetUrl
        );`,
      `        _authenticationMessageCallback = (event: MessageEvent) => {
          const playmeshBackend =
            getPlaymeshPlayerAuthenticationBackend();
          const receivedEvent = playmeshBackend
            ? playmeshBackend.consumeOfficialAuthenticationFrameMessage(event)
            : event;
          if (!receivedEvent) return;
          receiveAuthenticationMessage({
            runtimeScene,
            event: receivedEvent,
            checkOrigin: !playmeshBackend,
            onDone: resolve,
          });
        };
        window.addEventListener(
          'message',
          _authenticationMessageCallback,
          true
        );

        authComponents.displayIframeInsideAuthenticationContainer(
          _authenticationIframeContainer,
          _authenticationLoaderContainer,
          _authenticationTextContainer,
          targetUrl
        );`,
      'validate the local iframe-auth receive seam before official login handling'
    );
    patched = replaceExactly(
      patched,
      `      window.localStorage.removeItem(getLocalStorageKey(gameId));`,
      `      const identityKey = getLocalStorageKey(gameId);
      const playmeshBackend = getPlaymeshPlayerAuthenticationBackend();
      if (playmeshBackend) {
        playmeshBackend.removeOfficialIdentity(identityKey);
      } else {
        window.localStorage.removeItem(identityKey);
      }`,
      'route the exact identity removal seam through the private facade'
    );
    patched = replaceExactly(
      patched,
      `        const authenticatedUserStorageItem = window.localStorage.getItem(
          getLocalStorageKey(gameId)
        );`,
      `        const identityKey = getLocalStorageKey(gameId);
        const playmeshBackend = getPlaymeshPlayerAuthenticationBackend();
        const authenticatedUserStorageItem = playmeshBackend
          ? playmeshBackend.readOfficialIdentity(identityKey)
          : window.localStorage.getItem(identityKey);`,
      'route the exact identity read seam through the private facade'
    );
    patched = replaceExactly(
      patched,
      `        window.localStorage.setItem(
          getLocalStorageKey(gameId),
          JSON.stringify({
            username: _username,
            userId: _userId,
            userToken: _userToken,
          })
        );`,
      `        const identityKey = getLocalStorageKey(gameId);
        const identityRecord = {
          username: _username,
          userId: _userId,
          userToken: _userToken,
        };
        const playmeshBackend = getPlaymeshPlayerAuthenticationBackend();
        if (playmeshBackend) {
          playmeshBackend.writeOfficialIdentity(identityKey, identityRecord);
        } else {
          window.localStorage.setItem(
            identityKey,
            JSON.stringify(identityRecord)
          );
        }`,
      'route the exact identity write seam through the private facade'
    );
    return patched;
  },
});

await patchFile({
  relativePath:
    'Extensions/PlayerAuthentication/playerauthenticationcomponents.ts',
  expectedGitBlobSha: '8352080d4345e9fae45b1940ee1317e2875e8735',
  transform: content => {
    let patched = replaceExactly(
      content,
      `  export namespace playerAuthenticationComponents {
    const getPlayerLoginMessages = ({`,
      `  export namespace playerAuthenticationComponents {
    const getPlaymeshAuthenticationFrameBackend = (): any | null => {
      const runtimeGlobal = globalThis as any;
      const registry = runtimeGlobal[
        Symbol.for('playmesh.runtime.backends.v1')
      ];
      if (!registry) {
        if (runtimeGlobal.playmesh) {
          throw new Error(
            'Incompatible Playmesh runtime: GDevelop player authentication frame backend v1 is unavailable.'
          );
        }
        return null;
      }
      if (typeof registry.negotiate !== 'function') {
        throw new Error(
          'Incompatible Playmesh runtime: invalid backend registry.'
        );
      }
      const backend = registry.negotiate({
        engine: 'gdevelop',
        engineVersion: '5.6.276',
        feature: 'playerAuthentication',
        minVersion: 1,
        maxVersion: 1,
      });
      if (
        !backend ||
        typeof backend.configureOfficialAuthenticationFrame !== 'function'
      ) {
        throw new Error(
          'Incompatible Playmesh runtime: GDevelop player authentication frame backend v1 is unavailable.'
        );
      }
      return backend;
    };

    const getPlayerLoginMessages = ({`,
      'add the private authentication frame navigation resolver'
    );
    patched = replaceExactly(
      patched,
      `      iframe.src = url;`,
      `      const playmeshBackend = getPlaymeshAuthenticationFrameBackend();
      if (playmeshBackend) {
        playmeshBackend.configureOfficialAuthenticationFrame(iframe);
      } else {
        iframe.src = url;
      }`,
      'replace the unique authentication iframe navigation seam'
    );
    return patched;
  },
});

await assertOfficialSourceFile({
  relativePath: 'Extensions/Multiplayer/JsExtension.js',
  expectedGitBlobSha: 'bd558e1626bb9096eac9b6d094a5fabfd10e60c4',
  forbiddenPattern: /playmesh/i,
});

await assertOfficialSourceFile({
  relativePath: 'Extensions/Multiplayer/messageManager.ts',
  expectedGitBlobSha: '146a9b0bf321c71f3a227b10cf97028d539ae52e',
  forbiddenPattern: /playmesh/i,
});

await assertOfficialSourceFile({
  relativePath: 'Extensions/Multiplayer/peer.js',
  expectedGitBlobSha: '0abdf49a5335afc03c8977d7072a9755a27a7b94',
  forbiddenPattern: /playmesh/i,
});

await assertOfficialSourceFile({
  relativePath: 'Extensions/Multiplayer/multiplayerVariablesManager.ts',
  expectedGitBlobSha: '6bfc0160afe40ffe09124b6203d9fe3c5eb56677',
  forbiddenPattern: /playmesh/i,
});

await assertOfficialSourceFile({
  relativePath:
    'Extensions/Multiplayer/multiplayerobjectruntimebehavior.ts',
  expectedGitBlobSha: '05d77a67b5b70661e0fd30c33e02bc39094ad184',
  forbiddenPattern: /playmesh/i,
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/EditorContainers/BaseEditor.js',
  expectedGitBlobSha: '3bdede2fb3a37676bc901e4e43eb83fecc55fa66',
  transform: content =>
    replaceExactly(
      content,
      `  onOpenRecentFile: (file: FileMetadataAndStorageProviderName) => Promise<void>,`,
      `  onOpenRecentFile: (
    file: FileMetadataAndStorageProviderName,
    options?: {| ignorePersistedEditorTabs?: boolean |}
      ) => Promise<void>,`,
      'allow an explicit App project selection to skip Origin-specific tab restore'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/EditorTabs/EditorTabsHandler.js',
  expectedGitBlobSha: '84cfc529abaa169f6aac765b17234e7491cf603e',
  transform: content =>
    replaceExactly(
      content,
      `import { type AskAiEditorInterface } from '../../AiGeneration/AskAiEditorContainer';`,
      `import { type PlaymeshAiEditorInterface as AskAiEditorInterface } from '../../PlaymeshAi/PlaymeshAiIntegration';`,
      'route the generic ask-ai tab ref through the single Playmesh integration facade'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/UI/SelectField.js',
  expectedGitBlobSha: '6af569d80edd52f67f84965f2cdb219a35c67c0a',
  transform: content => {
    content = replaceExactly(
      content,
      `import TextField from '@material-ui/core/TextField';`,
      `import TextField from '@material-ui/core/TextField';
import MenuItem from '@material-ui/core/MenuItem';`,
      'support a correctly anchored non-native menu inside transformed dialogs'
    );
    content = replaceExactly(
      content,
      `  fullWidth?: boolean,
  children: React.Node,`,
      `  fullWidth?: boolean,
  native?: boolean,
  children: React.Node,`,
      'make native select opt-out explicit without changing official callers'
    );
    content = replaceExactly(
      content,
      `          SelectProps={{
            native: true,
            classes: selectStyles,
            IconComponent: ChevronArrowBottom,
          }}`,
      `          SelectProps={{
            native: props.native !== false,
            classes: selectStyles,
            IconComponent: ChevronArrowBottom,
            ...(props.native === false
              ? {
                  MenuProps: {
                    disablePortal: false,
                    getContentAnchorEl: null,
                    anchorOrigin: { vertical: 'bottom', horizontal: 'left' },
                    transformOrigin: { vertical: 'top', horizontal: 'left' },
                  },
                }
              : {}),
          }}`,
      'anchor the opt-in Material UI menu to its field and viewport'
    );
    content = replaceExactly(
      content,
      `          {!hasValidValue ? (
            <option value={INVALID_VALUE} disabled>
              {props.translatableHintText
                ? i18n._(props.translatableHintText)
                : i18n._(t\`Choose an option\`)}
            </option>
          ) : null}
          {props.children}`,
      `          {!hasValidValue ? (
            props.native === false ? (
              <MenuItem value={INVALID_VALUE} disabled>
                {props.translatableHintText
                  ? i18n._(props.translatableHintText)
                  : i18n._(t\`Choose an option\`)}
              </MenuItem>
            ) : (
              <option value={INVALID_VALUE} disabled>
                {props.translatableHintText
                  ? i18n._(props.translatableHintText)
                  : i18n._(t\`Choose an option\`)}
              </option>
            )
          ) : null}
          {props.native === false
            ? React.Children.map(props.children, child => {
                if (!React.isValidElement(child)) return null;
                const option: any = child;
                const optionProps: any = option.props;
                const { value, disabled, label, shouldNotTranslate } =
                  optionProps;
                return (
                  <MenuItem key={String(value)} value={value} disabled={disabled}>
                    {shouldNotTranslate ? label : i18n._(label)}
                  </MenuItem>
                );
              })
            : props.children}`,
      'render SelectOption descriptors as Material UI menu items when requested'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ProjectManager/ProjectPropertiesDialog.js',
  expectedGitBlobSha: '66d7d54557e3bc1e669cfb6210a292a847bb2a39',
  transform: content => {
    content = replaceExactly(
      content,
      `import { ProjectScopedContainersAccessor } from '../InstructionOrExpression/EventsScope';`,
      `import { ProjectScopedContainersAccessor } from '../InstructionOrExpression/EventsScope';
import { type FileMetadata } from '../ProjectsStorage';
import { prepareProjectPersistence } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
import { PlaymeshProjectRekeyController } from '../PlaymeshProjectRekey/PlaymeshProjectRekeyController';
import {
  PlaymeshProjectRekeyStatus,
  usePlaymeshProjectRekeyControllerState,
} from '../PlaymeshProjectRekey/PlaymeshProjectRekeyStatus';
import { PlaymeshProjectConfigClient } from '../PlaymeshProjectConfig/PlaymeshProjectConfigClient';
import { PlaymeshProjectConfigController } from '../PlaymeshProjectConfig/PlaymeshProjectConfigController';
import {
  playmeshProjectConfigMessages,
  translatePlaymeshProjectConfigMessage,
} from '../PlaymeshProjectConfig/PlaymeshProjectConfigMessages';
import PlaymeshProjectConfigSection from '../PlaymeshProjectConfig/PlaymeshProjectConfigSection';
import { type PlaymeshProjectConfigSectionHandle } from '../PlaymeshProjectConfig/PlaymeshProjectConfigSection';
import { usePlaymeshLocalization } from '../PlaymeshLocalization/PlaymeshLocalizationProvider';`,
      'import the Playmesh local identity migration controller and status UI'
    );
    content = replaceExactly(
      content,
      `type ProjectPropertiesTab = 'properties' | 'loading-screen' | 'icons';`,
      `type ProjectPropertiesTab =
  | 'properties'
  | 'loading-screen'
  | 'icons'
  | 'playmesh';`,
      'add one independent Playmesh page to the official properties dialog'
    );
    content = replaceExactly(
      content,
      `  project: gdProject,
  open: boolean,`,
      `  project: gdProject,
  fileMetadata?: ?FileMetadata,
  projectRekeyController?: PlaymeshProjectRekeyController,
  onFileMetadataRekeyed?: FileMetadata => void,
  onRetryProjectRekey?: () => void,
  open: boolean,`,
      'give project properties one authoritative local rekey controller'
    );
    content = replaceExactly(
      content,
      `  onPropertiesApplied: (options: { newName?: string }) => void,`,
      `  onPropertiesApplied: (options: {
    newName?: string,
    keepOpen?: boolean,
  }) => void,`,
      'let an App-sidecar retry keep the official properties dialog open'
    );
    content = replaceExactly(
      content,
      `  const [currentTab, setCurrentTab] = React.useState<
    'properties' | 'loading-screen' | 'icons'
  >(props.initialTab);`,
      `  const [currentTab, setCurrentTab] = React.useState<
    'properties' | 'loading-screen' | 'icons' | 'playmesh'
  >(props.initialTab);
  const fallbackProjectRekeyController = React.useMemo(
    () => new PlaymeshProjectRekeyController(),
    []
  );
  const projectRekeyController =
    props.projectRekeyController || fallbackProjectRekeyController;
  const projectRekeyState = usePlaymeshProjectRekeyControllerState(
    projectRekeyController
  );
  const playmeshProjectConfigController = React.useMemo(
    () =>
      new PlaymeshProjectConfigController({
        client: new PlaymeshProjectConfigClient(),
      }),
    []
  );
  const playmeshProjectConfigSectionRef = React.useRef<?PlaymeshProjectConfigSectionHandle>(
    null
  );
  const [playmeshConfigGameId, setPlaymeshConfigGameId] = React.useState(
    (props.fileMetadata && props.fileMetadata.gameId) ||
      project.getPackageName()
  );
  const { t: playmeshTranslate } = usePlaymeshLocalization();
  const playmeshMessage = React.useCallback(
    (key: any) => translatePlaymeshProjectConfigMessage(key, playmeshTranslate),
    [playmeshTranslate]
  );
  React.useEffect(
    () => () => playmeshProjectConfigController.dispose(),
    [playmeshProjectConfigController]
  );
  const savePlaymeshConfigAfterOfficialApply = React.useCallback(
    async ({ gameId, draftGameType, mustSave }: {|
      gameId: string,
      draftGameType: 'single' | 'online',
      mustSave: boolean,
    |}): Promise<boolean> => {
      let configState = playmeshProjectConfigController.getState();
      if (configState.gameId !== gameId || (mustSave && configState.fieldDisabled)) {
        await playmeshProjectConfigController.load(gameId);
        configState = playmeshProjectConfigController.getState();
        if (!configState.fieldDisabled) {
          playmeshProjectConfigController.selectGameType(draftGameType);
        }
      }
      const section = playmeshProjectConfigSectionRef.current;
      const outcome = section
        ? await section.saveAfterOfficialApply({
            officialApplySucceeded: true,
          })
        : { ok: false, reason: 'config_not_savable' };
      if (outcome.ok || !mustSave) return true;
      setPlaymeshConfigGameId(gameId);
      setCurrentTab('playmesh');
      return false;
    },
    [playmeshMessage, playmeshProjectConfigController]
  );`,
      'mount one App-sidecar config controller for the complete dialog lifecycle'
    );
    content = replaceExactly(
      content,
      `  const onApply = async () => {
    const specialPropertiesChanged =
      name !== initialProperties.name ? { newName: name } : {};

    // $FlowFixMe[incompatible-type]
    const proceed = await props.onApply(specialPropertiesChanged);
    if (!proceed) return;

    const wasProjectPropertiesApplied = applyPropertiesToProject(
      project,
      props.i18n,
      {
        gameResolutionWidth,
        gameResolutionHeight,
        adaptGameResolutionAtRuntime,
        name,
        description,
        author,
        authorIds,
        authorUsernames,
        version,
        packageName,
        orientation,
        scaleMode,
        pixelsRounding,
        antialiasingMode,
        isAntialisingEnabledOnMobile,
        sizeOnStartupMode,
        minFPS,
        maxFPS,
        isFolderProject,
        useDeprecatedZeroAsDefaultZOrder,
        useDeprecatedZeroAsDefaultStringVariable,
        desktopIconResourceNames,
        androidIconResourceNames,
        androidWindowSplashScreenAnimatedIconResourceName,
        iosIconResourceNames,
        sceneResourcesPreloading,
        sceneResourcesUnloading,
      }
    );

    if (wasProjectPropertiesApplied) {
      // $FlowFixMe[incompatible-type]
      props.onPropertiesApplied(specialPropertiesChanged);
    }
  };`,
      `  const onApply = async () => {
    if (projectRekeyState.busy || !projectRekeyState.canClose) return;
    const playmeshStateBeforeApply = playmeshProjectConfigController.getState();
    const playmeshDraftGameType = playmeshStateBeforeApply.draftGameType;
    const playmeshConfigMustSave =
      playmeshStateBeforeApply.requiresExplicitSave;
    const specialPropertiesChanged =
      name !== initialProperties.name ? { newName: name } : {};
    const editedProperties = {
      gameResolutionWidth,
      gameResolutionHeight,
      adaptGameResolutionAtRuntime,
      name,
      description,
      author,
      authorIds,
      authorUsernames,
      version,
      packageName,
      orientation,
      scaleMode,
      pixelsRounding,
      antialiasingMode,
      isAntialisingEnabledOnMobile,
      sizeOnStartupMode,
      minFPS,
      maxFPS,
      isFolderProject,
      useDeprecatedZeroAsDefaultZOrder,
      useDeprecatedZeroAsDefaultStringVariable,
      desktopIconResourceNames,
      androidIconResourceNames,
      androidWindowSplashScreenAnimatedIconResourceName,
      iosIconResourceNames,
      sceneResourcesPreloading,
      sceneResourcesUnloading,
    };

    // $FlowFixMe[incompatible-type]
    const proceed = await props.onApply(specialPropertiesChanged);
    if (!proceed) return;

    const packageNameChanged = packageName !== initialProperties.packageName;
    const fileMetadata = props.fileMetadata;
    const oldGameId = fileMetadata && fileMetadata.gameId;
    const configuredProjectRekeyController = props.projectRekeyController;
    const onFileMetadataRekeyed = props.onFileMetadataRekeyed;
    if (
      !packageNameChanged ||
      !fileMetadata ||
      !oldGameId ||
      !configuredProjectRekeyController ||
      !onFileMetadataRekeyed
    ) {
      const wasProjectPropertiesApplied = applyPropertiesToProject(
        project,
        props.i18n,
        editedProperties
      );
      if (wasProjectPropertiesApplied) {
        const playmeshSaved = await savePlaymeshConfigAfterOfficialApply({
          gameId: playmeshConfigGameId,
          draftGameType: playmeshDraftGameType,
          mustSave: playmeshConfigMustSave,
        });
        if (!playmeshSaved) {
          // Keep official properties and the App sidecar as one visible Apply.
          // No callback is emitted after restoring the exact in-memory state.
          applyPropertiesToProject(project, props.i18n, initialProperties);
          return;
        }
        // $FlowFixMe[incompatible-type]
        props.onPropertiesApplied({
          ...specialPropertiesChanged,
          keepOpen: false,
        });
      }
      return;
    }

    const confirmed = Window.showConfirmDialog(
      props.i18n._(
        t\`Changing the package name also changes this Playmesh game's local identity and moves its local history. The dialog will stay open until the migration or rollback is complete. Continue?\`
      )
    );
    if (!confirmed) return;

    try {
      const result = await configuredProjectRekeyController.execute({
        oldGameId,
        newGameId: packageName,
        fileMetadata,
        prepareCurrentProject: metadata =>
          prepareProjectPersistence(project, metadata),
        applyTargetProperties: () => {
          if (
            !applyPropertiesToProject(project, props.i18n, editedProperties)
          ) {
            throw new Error(
              props.i18n._(t\`The new game properties are invalid.\`)
            );
          }
        },
        restoreSourceProperties: () => {
          if (
            !applyPropertiesToProject(project, props.i18n, initialProperties)
          ) {
            throw new Error(
              props.i18n._(
                t\`The previous game properties could not be restored.\`
              )
            );
          }
        },
      });
      if (result.outcome === 'committed') {
        onFileMetadataRekeyed(result.fileMetadata);
        const playmeshSaved = await savePlaymeshConfigAfterOfficialApply({
          gameId: packageName,
          draftGameType: playmeshDraftGameType,
          mustSave: playmeshConfigMustSave,
        });
        setPlaymeshConfigGameId(packageName);
        // The rekey result already contains the new project name. Avoid a
        // second rename callback based on stale pre-migration metadata.
        props.onPropertiesApplied({ keepOpen: !playmeshSaved });
      }
    } catch (error) {
      // The controller owns the visible failure/rollback state. Keep this
      // handler fulfilled so React does not report an unhandled click promise.
      console.error('Playmesh project identity migration failed.', error);
    }
  };`,
      'route packageName changes through confirmed two-phase local rekey'
    );
    content = replaceExactly(
      content,
      `              <FlatButton
                label={<Trans>Cancel</Trans>}
                primary={false}
                onClick={onCancelChanges}
                key="cancel"
              />,
              <DialogPrimaryButton
                id="apply-button"
                label={<Trans>Apply</Trans>}
                primary={true}
                onClick={onApply}
                key="apply"
              />,`,
      `              <FlatButton
                label={<Trans>Cancel</Trans>}
                primary={false}
                disabled={!projectRekeyState.canClose}
                onClick={() => {
                  if (projectRekeyState.canClose) onCancelChanges();
                }}
                key="cancel"
              />,
              <DialogPrimaryButton
                id="apply-button"
                label={<Trans>Apply</Trans>}
                primary={true}
                disabled={
                  projectRekeyState.busy || !projectRekeyState.canClose
                }
                onClick={onApply}
                key="apply"
              />,`,
      'lock project properties actions during rekey and uncertain rollback'
    );
    content = replaceExactly(
      content,
      `            onRequestClose={onCancelChanges}
            onApply={onApply}`,
      `            onRequestClose={() => {
              if (projectRekeyState.canClose) onCancelChanges();
            }}
            onApply={() => {
              if (!projectRekeyState.busy && projectRekeyState.canClose) {
                onApply();
              }
            }}`,
      'prevent escape and keyboard apply from bypassing the rekey close lock'
    );
    content = replaceExactly(
      content,
      `                options={[
                  { label: <Trans>Properties</Trans>, value: 'properties' },
                  {
                    label: <Trans>Branding and Loading screen</Trans>,
                    value: 'loading-screen',
                  },
                  {
                    label: <Trans>Icons</Trans>,
                    value: 'icons',
                  },
                ]}`,
      `                options={[
                  {
                    label: <Trans>Properties</Trans>,
                    value: 'properties',
                  },
                  {
                    label: <Trans>Branding and Loading screen</Trans>,
                    value: 'loading-screen',
                  },
                  {
                    label: <Trans>Icons</Trans>,
                    value: 'icons',
                  },
                  {
                    label: playmeshMessage(
                      playmeshProjectConfigMessages.title
                    ),
                    value: 'playmesh',
                  },
                ]}`,
      'render Playmesh as an independent official-style tab'
    );
    content = replaceExactly(
      content,
      `          >
            {currentTab === 'properties' && (`,
      `          >
            <PlaymeshProjectRekeyStatus
              state={projectRekeyState}
              onRetry={() => {
                if (props.onRetryProjectRekey) {
                  props.onRetryProjectRekey();
                }
              }}
            />
            <PlaymeshProjectConfigSection
              ref={playmeshProjectConfigSectionRef}
              gameId={playmeshConfigGameId}
              controller={playmeshProjectConfigController}
              visible={currentTab === 'playmesh'}
            />
            {currentTab === 'properties' && (`,
      'keep sidecar state mounted while showing an independent Playmesh page'
    );
    return replaceExactly(
      content,
      `    onClose={props.onClose}
    showOnTop`,
      `    onClose={() => {
      if (
        !props.projectRekeyController ||
        props.projectRekeyController.getState().canClose
      ) {
        props.onClose();
      }
    }}
    showOnTop`,
      'keep the error boundary from closing a locked migration dialog'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ProjectManager/index.js',
  expectedGitBlobSha: '356241f0da2143cb06f231f4f31fc9955abe2657',
  transform: content => {
    content = replaceExactly(
      content,
      `import ProjectPropertiesDialog from './ProjectPropertiesDialog';`,
      `import ProjectPropertiesDialog from './ProjectPropertiesDialog';
import { type FileMetadata } from '../ProjectsStorage';
import { PlaymeshProjectRekeyController } from '../PlaymeshProjectRekey/PlaymeshProjectRekeyController';
import { usePlaymeshProjectRekeyControllerState } from '../PlaymeshProjectRekey/PlaymeshProjectRekeyStatus';`,
      'import the shared Project Manager rekey controller'
    );
    content = replaceExactly(
      content,
      `  project: ?gdProject,
  onChangeProjectName: string => Promise<void>,`,
      `  project: ?gdProject,
  fileMetadata?: ?FileMetadata,
  onFileMetadataRekeyed?: FileMetadata => void,
  onChangeProjectName: string => Promise<void>,`,
      'pass stable file metadata through the Project Manager boundary'
    );
    content = replaceExactly(
      content,
      `      project,
      onChangeProjectName,`,
      `      project,
      fileMetadata,
      onFileMetadataRekeyed = () => {},
      onChangeProjectName,`,
      'receive Playmesh file metadata and rekey result callback'
    );
    content = replaceExactly(
      content,
      `    const [
      projectPropertiesDialogOpen,
      setProjectPropertiesDialogOpen,
    ] = React.useState(false);`,
      `    const projectRekeyController = React.useMemo(
      () => new PlaymeshProjectRekeyController(),
      []
    );
    const projectRekeyState = usePlaymeshProjectRekeyControllerState(
      projectRekeyController
    );
    const [
      projectPropertiesDialogOpen,
      setProjectPropertiesDialogOpen,
    ] = React.useState(false);`,
      'keep one rekey controller alive while the dialog opens and closes'
    );
    content = replaceExactly(
      content,
      `    const openProjectProperties = React.useCallback(() => {
      setProjectPropertiesDialogOpen(true);
      setProjectPropertiesDialogInitialTab('properties');
    }, []);`,
      `    const openProjectProperties = React.useCallback(() => {
      setProjectPropertiesDialogOpen(true);
      setProjectPropertiesDialogInitialTab('properties');
    }, []);
    const retryProjectRekey = React.useCallback(
      async () => {
        if (!fileMetadata) return;
        try {
          await projectRekeyController.recoverIfPending({
            fileMetadata,
            reload: () => window.location.reload(),
          });
        } catch (_) {
          setProjectPropertiesDialogOpen(true);
        }
      },
      [fileMetadata, projectRekeyController]
    );
    React.useEffect(
      () => {
        if (!fileMetadata) return;
        projectRekeyController
          .recoverIfPending({
            fileMetadata,
            reload: () => window.location.reload(),
          })
          .catch(() => setProjectPropertiesDialogOpen(true));
      },
      [
        fileMetadata && fileMetadata.fileIdentifier,
        fileMetadata && fileMetadata.gameId,
        projectRekeyController,
      ]
    );
    React.useEffect(
      () => {
        if (!projectRekeyState.canClose) {
          setProjectPropertiesDialogOpen(true);
        }
      },
      [projectRekeyState.canClose]
    );`,
      'recover only projects with a durable browser journal and surface locks'
    );
    content = replaceExactly(
      content,
      `    const onProjectPropertiesApplied = React.useCallback(
      (options: { newName?: string }) => {`,
      `    const onProjectPropertiesApplied = React.useCallback(
      (options: { newName?: string, keepOpen?: boolean }) => {`,
      'accept a sidecar retry without conflating it with official project data'
    );
    content = replaceExactly(
      content,
      `        setProjectPropertiesDialogOpen(false);
      },
      [triggerUnsavedChanges, onChangeProjectName]`,
      `        if (
          !options.keepOpen &&
          projectRekeyController.getState().canClose
        ) {
          projectRekeyController.reset();
          setProjectPropertiesDialogOpen(false);
        }
      },
      [
        triggerUnsavedChanges,
        onChangeProjectName,
        projectRekeyController,
      ]`,
      'reset completed rekey UI state only after properties are applied'
    );
    content = replaceExactly(
      content,
      `                        project={project}
                        onClose={() => setProjectPropertiesDialogOpen(false)}
                        onApply={onSaveProjectProperties}`,
      `                        project={project}
                        fileMetadata={fileMetadata}
                        projectRekeyController={projectRekeyController}
                        onFileMetadataRekeyed={onFileMetadataRekeyed}
                        onRetryProjectRekey={() => {
                          retryProjectRekey();
                        }}
                        onClose={() => {
                          if (projectRekeyController.getState().canClose) {
                            projectRekeyController.reset();
                            setProjectPropertiesDialogOpen(false);
                          }
                        }}
                        onApply={onSaveProjectProperties}`,
      'wire durable rekey metadata, retry, and close guards into the dialog'
    );
    return content;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/index.js',
  expectedGitBlobSha: '0268fc9b7862c026ce99c756d896e28526aa809f',
  transform: content => {
    content = replaceExactly(
      content,
      `import useVersionHistory from '../VersionHistory/UseVersionHistory';`,
      `import useVersionHistory from '../PlaymeshHistory/UsePlaymeshHistory';`,
      'route the file history drawer to Playmesh local history'
    );
    content = replaceExactly(
      content,
      `  gameId: project.getProjectUuid(),\n  name: project.getName(),`,
      `  gameId: project.getPackageName(),\n  name: project.getName(),`,
      'bind Playmesh game identity to GDevelop packageName rather than projectUuid'
    );
    content = replaceExactly(
      content,
      `  } = useVersionHistory({\n    getStorageProvider,\n    isSavingProject,\n    fileMetadata: currentFileMetadata,`,
      `  } = useVersionHistory({\n    getStorageProvider,\n    isSavingProject,\n    fileMetadata: currentFileMetadata,\n    project: currentProject,`,
      'give the Playmesh history hook the live project for validated restores'
    );
    content = replaceExactly(
      content,
      `import { renderHomePageContainer } from './EditorContainers/HomePage';`,
      `import { renderHomePageContainer } from './EditorContainers/PlaymeshHomePage';`,
      'replace the online GDevelop home page with the Playmesh local home page'
    );
    content = replaceExactly(
      content,
      `import { renderAskAiEditorContainer } from '../AiGeneration/AskAiEditorContainer';`,
      `import {
  canOpenPlaymeshAi,
  getPlaymeshAiEditorExtraProps,
  PLAYMESH_AI_EDITOR_LABEL,
  PlaymeshAiIntegrationHost,
  renderPlaymeshAiEditorContainer as renderAskAiEditorContainer,
  usePlaymeshAiIntegration,
} from '../PlaymeshAi/PlaymeshAiIntegration';`,
      'route all official AI seams through the single Playmesh integration facade'
    );
    content = replaceExactly(
      content,
      `  const currentProjectRef = useStableUpToDateRef(currentProject);

  const getEditorOpeningOptions = React.useCallback(`,
      `  const currentProjectRef = useStableUpToDateRef(currentProject);
  usePlaymeshAiIntegration(state.editorTabs);

  const getEditorOpeningOptions = React.useCallback(`,
      'hand native editor tab state to the Playmesh integration facade'
    );
    content = replaceExactly(
      content,
      `          ? {
              continueProcessingFunctionCallsOnMount,
            }
          : undefined;`,
      `          ? getPlaymeshAiEditorExtraProps({
              continueProcessingFunctionCallsOnMount,
            })
          : undefined;`,
      'delegate Playmesh AI opening options to the integration facade'
    );
    content = replaceExactly(
      content,
      `  const openAskAi = React.useCallback(
    (options: ?OpenAskAiOptions) => {
      const {`,
      `  const openAskAi = React.useCallback(
    (options: ?OpenAskAiOptions) => {
      if (!canOpenPlaymeshAi()) return;
      const {`,
      'guard every ask-ai opener through the Playmesh integration facade'
    );
    content = replaceExactly(
      content,
      `  const hideAskAi =
    !!authenticatedUser.limits &&
    !!authenticatedUser.limits.capabilities.classrooms &&
    authenticatedUser.limits.capabilities.classrooms.hideAskAi;`,
      '  const hideAskAi = !canOpenPlaymeshAi();',
      'control every Ask AI menu entry through the integration facade'
    );
    content = replaceExactly(
      content,
      `    >
      {!!renderPreviewLauncher &&`,
      `    >
      <PlaymeshAiIntegrationHost
        project={currentProject}
        fileMetadata={currentFileMetadata}
      />
      {!!renderPreviewLauncher &&`,
      'bind the AI session lifecycle to the active WebIDE project instead of the panel'
    );
    content = replaceExactly(
      content,
      '? i18n._(t`Ask AI`)',
      '? PLAYMESH_AI_EDITOR_LABEL',
      'delegate the Playmesh AI editor label to the integration facade'
    );
    content = replaceExactly(
      content,
      `        <ProjectManager
          project={currentProject}
          onChangeProjectName={onChangeProjectName}`,
      `        <ProjectManager
          project={currentProject}
          fileMetadata={currentFileMetadata}
          onFileMetadataRekeyed={fileMetadata => {
            setState(state => ({
              ...state,
              currentFileMetadata: fileMetadata,
            }));
          }}
          onChangeProjectName={onChangeProjectName}`,
      'commit rekeyed file metadata into MainFrame without a stale rename pass'
    );
    content = replaceExactly(
      content,
      `            sourceGameId: quickCustomizationDialogOpenedFromGameId || '',
            getIncludeFileHashs:`,
      `            sourceGameId: quickCustomizationDialogOpenedFromGameId || '',
            playmeshGameId: currentFileMetadata?.gameId || '',
            getIncludeFileHashs:`,
      'pass the stable Playmesh fileMetadata gameId to preview packaging'
    );
    content = replaceExactly(
      content,
      `    onOpenLayout: (
      name: string,
      options?: {|
        openEventsEditor: boolean,
        openSceneEditor: boolean,
        focusWhenOpened:
          | 'scene-or-events-otherwise'
          | 'scene'
          | 'events'
          | 'none',
      |}
    ) => openLayout(name, options),
    onWillInstallExtension,
    onExtensionInstalled,
  });`,
      `    onOpenLayout: (
      name: string,
      options?: {|
        openEventsEditor: boolean,
        openSceneEditor: boolean,
        focusWhenOpened:
          | 'scene-or-events-otherwise'
          | 'scene'
          | 'events'
          | 'none',
      |}
    ) => openLayout(name, options),
    onWillInstallExtension,
    onExtensionInstalled,
    onOpenPlaymeshProject: openFromFileMetadataWithStorageProvider,
  });`,
      'open an imported Playmesh example through the existing MainFrame controller'
    );
    content = replaceExactly(
      content,
      `        ignoreAutoSave?: boolean,
        openingMessage?: ?MessageDescriptor,`,
      `        ignoreAutoSave?: boolean,
        ignorePersistedEditorTabs?: boolean,
        openingMessage?: ?MessageDescriptor,`,
      'declare the explicit App project selection tab restore policy'
    );
    content = replaceExactly(
      content,
      `            if (options && options.openAllScenes) {
              openAllScenes({
                currentProject: currentProject,
                editorTabs: state.editorTabs,
              });
            } else if (
              currentProject &&
              hasAPreviousSaveForEditorTabsState(currentProject)
            ) {`,
      `            if (options && options.openAllScenes) {
              openAllScenes({
                currentProject: currentProject,
                editorTabs: state.editorTabs,
              });
            } else if (options && options.ignorePersistedEditorTabs) {
              // A project-manager click is a fresh entry: reuse GDevelop's
              // native new-project initialization and ignore Origin-local tabs.
              openSceneOrProjectManager({
                currentProject: currentProject,
                editorTabs: state.editorTabs,
              });
            } else if (
              currentProject &&
              hasAPreviousSaveForEditorTabsState(currentProject)
            ) {`,
      'bypass persisted editor tabs only for an explicit App project selection'
    );
    content = replaceExactly(
      content,
      `          } else if (
            getAutoOpenMostRecentProject() &&
            hadProjectOpenedDuringLastSession() &&
            getRecentProjectFiles()[0]
          ) {
            // Re-open the last opened project, if any and if asked to.
            const fileMetadataAndStorageProviderName = getRecentProjectFiles()[0];
            const storageProvider = findStorageProviderFor(
              i18n,
              props.storageProviders,
              fileMetadataAndStorageProviderName
            );
            if (!storageProvider) return;

            const storageProviderOperations = getStorageProviderOperations(
              storageProvider
            );
            const proceed = await ensureInteractionHappened(
              storageProviderOperations
            );
            if (proceed)
              openFromFileMetadataWithStorageProvider(
                fileMetadataAndStorageProviderName
              );
          }`,
      `          } else {
            // Playmesh projects are App-owned and shared across browser Origins.
            // Browser recents remain only a fallback for ordinary providers.
            const playmeshFileMetadata = await getPlaymeshInitialProjectFileMetadata();
            if (playmeshFileMetadata) {
              const fileMetadataAndStorageProviderName = {
                fileMetadata: playmeshFileMetadata,
                storageProviderName: 'PlaymeshLocal',
              };
              const storageProvider = findStorageProviderFor(
                i18n,
                props.storageProviders,
                fileMetadataAndStorageProviderName
              );
              if (storageProvider) {
                const storageProviderOperations = getStorageProviderOperations(
                  storageProvider
                );
                const proceed = await ensureInteractionHappened(
                  storageProviderOperations
                );
                if (proceed)
                  openFromFileMetadataWithStorageProvider(
                    fileMetadataAndStorageProviderName
                  );
              }
            } else if (
              getAutoOpenMostRecentProject() &&
              hadProjectOpenedDuringLastSession() &&
              getRecentProjectFiles()[0]
            ) {
              // Re-open non-Playmesh projects from this Origin's UI preferences.
              const fileMetadataAndStorageProviderName = getRecentProjectFiles()[0];
              const storageProvider = findStorageProviderFor(
                i18n,
                props.storageProviders,
                fileMetadataAndStorageProviderName
              );
              if (!storageProvider) return;
              const storageProviderOperations = getStorageProviderOperations(
                storageProvider
              );
              const proceed = await ensureInteractionHappened(
                storageProviderOperations
              );
              if (proceed)
                openFromFileMetadataWithStorageProvider(
                  fileMetadataAndStorageProviderName
                );
            }
          }`,
      'auto-open the App-authoritative active Playmesh project before Origin recents'
    );
    return replaceSectionExactly(
      content,
      `          } else {
            // Playmesh projects are App-owned and shared across browser Origins.`,
      `

          configureNewProjectActionsForProfile({`,
      `          }

`,
      'leave startup on the App-backed project list without automatic opening'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/ExportAndShare/PreviewLauncher.flow.js',
  expectedGitBlobSha: 'b30e07ff90261c6abb0a8c293ac521e92b3d70fc',
  transform: content =>
    replaceExactly(
      content,
      `  sourceGameId: string,
  getIncludeFileHashs: () => { [string]: number },`,
      `  sourceGameId: string,
  playmeshGameId: string,
  getIncludeFileHashs: () => { [string]: number },`,
      'declare the stable Playmesh project identity for preview launchers'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/TabsTitlebar.js',
  expectedGitBlobSha: '987b9c2b67c06260aff78ccc5832fda48988431f',
  transform: content => {
    content = replaceExactly(
      content,
      `import * as React from 'react';`,
      `import * as React from 'react';
import { PlaymeshAiTitlebarActions } from '../PlaymeshAi/PlaymeshAiIntegration';`,
      'route the official titlebar through the single Playmesh integration facade'
    );
    for (const sourceImport of [
      `import RobotIcon from '../ProjectCreation/RobotIcon';\n`,
      `import PreferencesContext from './Preferences/PreferencesContext';\n`,
      `import TextButton from '../UI/TextButton';\n`,
      `import { useInterval } from '../Utils/UseInterval';\n`,
      `import classes from './TabsTitlebar.module.css';\n`,
      `import { useIsMounted } from '../Utils/UseIsMounted';\n`,
      `import AuthenticatedUserContext from '../Profile/AuthenticatedUserContext';\n`,
      `import { AiRequestContext } from '../AiGeneration/AiRequestContext';\n`,
    ]) {
      content = replaceExactly(
        content,
        sourceImport,
        '',
        'move Playmesh AI titlebar dependencies behind the integration facade'
      );
    }
    content = replaceExactly(
      content,
      `  askAiContainer: {
    zIndex: 0, // Create a stacking context to avoid the AI icon z-indexed element to display above other panes or UI elements.
    marginBottom: 4,
    marginRight: 1,
    marginLeft: 2,
  },`,
      '',
      'move Playmesh AI titlebar layout behind the integration facade'
    );
    content = replaceSectionExactly(
      content,
      `const useIsAskAiIconAnimated = (shouldDisplayAskAi: boolean) => {`,
      `/**
 * The titlebar containing a menu, the tabs and giving space for window controls.`,
      '',
      'move Playmesh AI titlebar animation behind the integration facade'
    );
    content = replaceExactly(
      content,
      `  const preferences = React.useContext(PreferencesContext);
  const { limits } = React.useContext(AuthenticatedUserContext);
  const { getWorkingAiRequest } = React.useContext(AiRequestContext);
  // True when an AI request is still working — even if its tab/panel is closed,
  // since the request lives in the app-level AiRequestContext.
  const isAiWorking = !!getWorkingAiRequest();
`,
      '',
      'move Playmesh AI titlebar state behind the integration facade'
    );
    content = replaceSectionExactly(
      content,
      `  const hideAskAi =`,
      `  const handleDoubleClick = React.useCallback(() => {`,
      '',
      'move Playmesh AI titlebar visibility and glow behind the integration facade'
    );
    return replaceSectionExactly(
      content,
      `      {shouldDisplayAskAi ? (`,
      `      {isRightMostPane && <TitleBarRightSafeMargins />}`,
      `      <PlaymeshAiTitlebarActions
        displayAskAi={displayAskAi}
        onAskAiClicked={onAskAiClicked}
        isRightMostPane={isRightMostPane}
      />
`,
      'render Playmesh AI and fullscreen actions through the integration facade'
    );
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/UseCapturesManager.js',
  expectedGitBlobSha: 'b69a0c36bb46b8917af48279fc5670a3d03f868b',
  transform: content => {
    let next = replaceExactly(
      content,
      `import {
  createGameResourceSignedUrls,
  updateGame,
} from '../Utils/GDevelopServices/Game';`,
      `import { updateGame } from '../Utils/GDevelopServices/Game';`,
      'remove official signed screenshot URL request import'
    );
    next = replaceExactly(
      next,
      `      const captureOptions: CaptureOptions = {
        screenshots: [],
      };

      try {
        if (launchCaptureOptions && launchCaptureOptions.screenshots.length) {
          const screenshotOptions = launchCaptureOptions.screenshots;
          const response = await createGameResourceSignedUrls({
            uploadType: 'game-screenshot',
            files: screenshotOptions.map(screenshotOption => ({
              contentType: 'image/png',
            })),
          });
          const signedUrls = response.signedUrls;
          if (!signedUrls || signedUrls.length === 0) {
            throw new Error('No signed url returned');
          }

          captureOptions.screenshots = screenshotOptions
            .map((screenshotOption, index) => {
              const signedUrlInfo = signedUrls[index];
              if (!signedUrlInfo) {
                return null;
              }

              return {
                delayTimeInSeconds: screenshotOption.delayTimeInSeconds,
                signedUrl: signedUrlInfo.signedUrl,
                publicUrl: signedUrlInfo.publicUrl,
              };
            })
            .filter(Boolean);
        }
      } catch (error) {
        console.error(
          'Error caught while creating signed URLs for game resources. Skipping.',
          error
        );
      }

      return captureOptions;`,
      `      // Playmesh previews run in AppGameRuntimeWebView and do not upload
      // automatic screenshots to the official GDevelop cloud.
      return { screenshots: [] };`,
      'disable official signed screenshot URL creation at its capture source'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/ExtensionStore/InstallExtension.js',
  expectedGitBlobSha: 'f07f4a26ebbad25ac47f7659a48ff0a6f4cf6179',
  transform: content => {
    let next = replaceExactly(
      content,
      "import { retryIfFailed } from '../../Utils/RetryIfFailed';",
      `import { retryIfFailed } from '../../Utils/RetryIfFailed';
import { presentPlaymeshExternalDownloadFailure } from '../../PlaymeshCatalog/PlaymeshExternalDownloadErrorPresenter';`,
      'install extensions through the shared Playmesh external failure presenter'
    );
    next = replaceExactly(
      next,
      `    await installRequiredExtensions({
      requiredExtensionInstallation,
      shouldUpdateExtension: extensionUpdateAction === 'update',
      eventsFunctionsExtensionsState,
      project,
      onWillInstallExtension,
      onExtensionInstalled,
      importedSerializedExtensions,
    });
    return true;`,
      `    try {
      await installRequiredExtensions({
        requiredExtensionInstallation,
        shouldUpdateExtension: extensionUpdateAction === 'update',
        eventsFunctionsExtensionsState,
        project,
        onWillInstallExtension,
        onExtensionInstalled,
        importedSerializedExtensions,
      });
      return true;
    } catch (rawError) {
      // Asset installation already owns a richer aggregate error dialog. The
      // extension and behavior entry points share this one download boundary.
      if (reason === 'asset') throw rawError;
      presentPlaymeshExternalDownloadFailure({
        rawError,
        stage:
          reason === 'behavior'
            ? 'behavior_extension_download'
            : 'extension_download',
        operation: 'gdevelop.catalog.artifact.acquire',
        errorId:
          reason === 'behavior'
            ? 'download-behavior-extension-error'
            : 'download-extension-error',
      });
      return false;
    }`,
      'show one sanitized actionable modal for extension and behavior downloads'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/AssetStore/ExtensionStore/ExtensionDetailPanel.js',
  expectedGitBlobSha: '38df6616b672c3e6df4e884e195e157e056ead76',
  transform: content => {
    let next = replaceExactly(
      content,
      `import { Accordion, AccordionHeader, AccordionBody } from '../../UI/Accordion';`,
      `import { Accordion, AccordionHeader, AccordionBody } from '../../UI/Accordion';
import PlaymeshExtensionSourceLink from '../../PlaymeshCatalog/PlaymeshExtensionSourceLink';`,
      'show the fixed provider source for catalog extensions'
    );
    next = replaceExactly(
      next,
      `      <Text noMargin>
        {extensionHeader`,
      `      <PlaymeshExtensionSourceLink header={extensionShortHeader} />
      <Text noMargin>
        {extensionHeader`,
      'render the fixed extension source link in extension details'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/BehaviorsEditor/NewBehaviorDialog.js',
  expectedGitBlobSha: '213c19392e5e7dcc8bca1b87d1500906c246975f',
  transform: content => {
    let next = replaceExactly(
      content,
      "import { Trans } from '@lingui/macro';",
      "import { t, Trans } from '@lingui/macro';",
      'behavior install translated progress and error messages'
    );
    next = replaceExactly(
      next,
      "import { showMessageBox } from '../UI/Messages/MessageBox';",
      "import { showMessageBox } from '../UI/Messages/MessageBox';\nimport AlertMessage from '../UI/AlertMessage';\nimport { presentPlaymeshExternalDownloadFailure } from '../PlaymeshCatalog/PlaymeshExternalDownloadErrorPresenter';",
      'behavior install visible feedback imports'
    );
    next = replaceExactly(
      next,
      "import { type BehaviorShortHeader } from '../Utils/GDevelopServices/Extension';",
      `import {
  getExtensionsRegistry,
  type BehaviorShortHeader,
  type ExtensionShortHeader,
} from '../Utils/GDevelopServices/Extension';`,
      'behavior install can load the owning extension registry independently'
    );
    next = replaceExactly(
      next,
      `      const behaviorShortHeaders: Array<BehaviorShortHeader> = [
        behaviorShortHeader,
      ];
      const requiredExtensions = getRequiredExtensions(behaviorShortHeaders);
      const requiredExtensionInstallation = await checkRequiredExtensionsUpdate(
        {
          requiredExtensions,
          project,
          extensionShortHeadersByName,
        }
      );
      const extensionShortHeader = getExtensionHeader(
        extensionShortHeadersByName,
        behaviorShortHeader.extensionName
      );`,
      `      // The behavior and extension catalogs are loaded independently. A user
      // can open this dialog before ever opening the extension store, in which
      // case its React context is still empty. Resolve installation inputs from
      // the canonical registry so behavior installation never depends on an
      // unrelated dialog having been opened first.
      const extensionRegistry = await getExtensionsRegistry();
      const installExtensionShortHeadersByName: {
        [name: string]: ExtensionShortHeader,
      } = {};
      extensionRegistry.headers.forEach(extensionShortHeader => {
        installExtensionShortHeadersByName[extensionShortHeader.name] =
          extensionShortHeadersByName[extensionShortHeader.name] ||
          extensionShortHeader;
      });
      const behaviorShortHeaders: Array<BehaviorShortHeader> = [
        behaviorShortHeader,
      ];
      const requiredExtensions = getRequiredExtensions(behaviorShortHeaders);
      const requiredExtensionInstallation = await checkRequiredExtensionsUpdate(
        {
          requiredExtensions,
          project,
          extensionShortHeadersByName: installExtensionShortHeadersByName,
        }
      );
      const extensionShortHeader = getExtensionHeader(
        installExtensionShortHeadersByName,
        behaviorShortHeader.extensionName
      );`,
      'behavior install resolves owners and dependencies from the canonical registry'
    );
    next = replaceExactly(
      next,
      `      return wasExtensionInstalled;
    } finally {
      setIsInstalling(false);
    }`,
      `      return wasExtensionInstalled;
    } catch (rawError) {
      presentPlaymeshExternalDownloadFailure({
        message: i18n._(
          t\`Unable to download and install the behavior extension and its dependencies. Verify that your internet connection is working or try again later.\`
        ),
        rawError,
        stage: 'behavior_extension_download',
        operation: 'gdevelop.catalog.artifact.acquire',
        errorId: 'download-behavior-extension-error',
      });
      return false;
    } finally {
      setIsInstalling(false);
    }`,
      'behavior install failure is visible to the user'
    );
    next = replaceExactly(
      next,
      `              primary={false}
              onClick={onClose}`,
      `              primary={false}
              disabled={isInstalling}
              onClick={onClose}`,
      'behavior dialog close is disabled during installation'
    );
    next = replaceExactly(
      next,
      `          open
          onRequestClose={onClose}
          flexBody`,
      `          open
          cannotBeDismissed={isInstalling}
          onRequestClose={isInstalling ? () => {} : onClose}
          flexBody`,
      'behavior dialog cannot disappear during installation'
    );
    next = replaceExactly(
      next,
      `        >
          <BehaviorStore`,
      `        >
          {isInstalling && (
            <AlertMessage kind="info">
              <Trans>Downloading and installing the behavior, please wait...</Trans>
            </AlertMessage>
          )}
          <BehaviorStore`,
      'behavior install progress is visible immediately'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/Utils/GDevelopServices/ApiConfigs.js',
  expectedGitBlobSha: 'cc52e676c4bf4873bb1a0fe6c6568982e1fbd1bb',
  transform: content => {
    const hostPattern = /(?<=['`])(?:https|wss):\/\/[^/'`]*(?:gdevelop\.io|gdevelop-app\.com|gd\.games|firebaseio\.com|firebaseapp\.com|appspot\.com)(?=\/|['`])/g;
    const matches = content.match(hostPattern) || [];
    if (matches.length < 20) {
      throw new Error(
        `Expected at least 20 GDevelop service endpoints, found ${
          matches.length
        }`
      );
    }
    return content.replace(hostPattern, 'https://playmesh.invalid');
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/MainMenu.js',
  expectedGitBlobSha: 'b0e701e77a9c8b21f4b4331cc3e8fb34f9fcff72',
  transform: content => {
    let next = replaceAllExactly(
      content,
      'i18n._(t`About GDevelop`)',
      'i18n._(t`About Playmesh Visual Editor`)',
      2,
      'visible About menu product identity'
    );
    next = replaceExactly(
      next,
      'i18n._(t`GDevelop 5`)',
      'i18n._(t`Playmesh Visual Editor`)',
      'macOS application menu product identity'
    );
    return next;
  },
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/AboutDialog.js',
  expectedGitBlobSha: 'c2be533b97aa4b419246692866cd3a2dadada0bd',
  transform: content =>
    replaceAllExactly(
      content,
      '<Trans>About GDevelop</Trans>',
      '<Trans>About Playmesh Visual Editor</Trans>',
      2,
      'visible About dialog product identity'
    ),
});

await patchFile({
  relativePath: 'newIDE/app/src/MainFrame/ProjectTitlebar.js',
  expectedGitBlobSha: '015035ebd561775e74512baaf6f099813a8814f9',
  transform: content =>
    replaceExactly(
      content,
      "          'GDevelop 5',",
      "          'Playmesh Visual Editor',",
      'window title fallback product identity'
    ),
});

const outputManifest = await loadSourcePolicyOutputManifest(
  path.join(playmeshDirectory, 'source-policy-output-manifest.json')
);
const webIdeLock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
);
assertManifestMatchesWebIdeLock({ manifest: outputManifest, lock: webIdeLock });
const overlayVerification = await verifyOverlayTreeDigest({
  manifest: outputManifest,
  overlayDirectory,
  allowPending: true,
});
const outputVerification = verifyRecordedSourcePolicyOutputs({
  manifest: outputManifest,
  patchedOfficialFiles: patchedOfficialOutputRecords,
  generatedFiles: generatedOutputRecords,
  allowPending: true,
});
const pendingWarnings = [
  ...overlayVerification.warnings,
  ...outputVerification.warnings,
];
if (pendingWarnings.length > 0) {
  process.stderr.write(
    `\n=== PLAYMESH RELEASE BLOCKED: OUTPUT MANIFEST IS PENDING ===\n${pendingWarnings
      .map(warning => `- ${warning}`)
      .join('\n')}\n` +
      'Freeze every digest before running the release verifiers.\n' +
      '==========================================================\n\n'
  );
}

process.stdout.write('GDevelop source policy applied successfully.\n');
