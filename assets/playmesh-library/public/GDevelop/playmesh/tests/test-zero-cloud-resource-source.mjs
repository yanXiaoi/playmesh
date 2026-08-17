import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const sourceIndex = process.argv.indexOf('--source');
if (sourceIndex === -1 || !process.argv[sourceIndex + 1]) {
  throw new Error(
    'Usage: node test-zero-cloud-resource-source.mjs --source <patched GDevelop root>'
  );
}

const sourceRoot = path.resolve(process.argv[sourceIndex + 1]);
const readSource = relativePath =>
  readFile(path.join(sourceRoot, relativePath), 'utf8');

const browserApp = await readSource('newIDE/app/src/BrowserApp.js');
const previewLauncherRouter = await readSource(
  'newIDE/app/src/PlaymeshPreview/PlaymeshPreviewLauncherRouter.js'
);
const localPreviewInitializer = await readSource(
  'newIDE/app/src/PlaymeshPreview/PlaymeshLocalBrowserSWPreview.js'
);
const browserSwPreviewStore = await readSource(
  'newIDE/app/src/ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher/BrowserSWPreviewIndexedDB.js'
);
const browserSwTemplate = await readSource(
  'newIDE/app/scripts/service-worker-template/service-worker-template.js'
);
const localGdjsFinder = await readSource(
  'newIDE/app/src/GameEngineFinder/BrowserS3GDJSFinder.js'
);
const browserEntry = await readSource('newIDE/app/src/index.js');
const projectCache = await readSource('newIDE/app/src/Utils/ProjectCache.js');
const userUuid = await readSource('newIDE/app/src/Utils/Analytics/UserUUID.js');
const localStats = await readSource('newIDE/app/src/Utils/Analytics/LocalStats.js');
const browserPersistenceCleanup = await readSource(
  'newIDE/app/src/PlaymeshBrowserPersistence/PlaymeshBrowserPersistenceCleanup.js'
);
const generatedCodeWriter = await readSource(
  'newIDE/app/src/EventsFunctionsExtensionsLoader/CodeWriters/PlaymeshEventsFunctionCodeWriter.js'
);
const playmeshProjectStore = await readSource(
  'newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore.js'
);
const playmeshCatalogCache = await readSource(
  'newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogCache.js'
);
const playmeshHistoryJournal = await readSource(
  'newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRestoreJournal.js'
);
const playmeshRekeyJournal = await readSource(
  'newIDE/app/src/PlaymeshProjectRekey/PlaymeshProjectRekeyJournal.js'
);
const resourceSources = await readSource(
  'newIDE/app/src/ResourcesList/BrowserResourceSources.js'
);
const localUploader = await readSource(
  'newIDE/app/src/ResourcesList/FileToPlaymeshLocalResourceUploader.js'
);
const eventSender = await readSource(
  'newIDE/app/src/Utils/Analytics/EventSender.js'
);
const catalogSource = await readSource(
  'newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogSource.js'
);
const catalogRuntime = await readSource(
  'newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogRuntime.js'
);
const courseStore = await readSource(
  'newIDE/app/src/Course/CourseStoreContext.js'
);
const announcementsFeed = await readSource(
  'newIDE/app/src/AnnouncementsFeed/AnnouncementsFeedContext.js'
);
const inAppTutorialProvider = await readSource(
  'newIDE/app/src/InAppTutorial/InAppTutorialProvider.js'
);
const assetStore = await readSource(
  'newIDE/app/src/AssetStore/AssetStoreContext.js'
);
const resourceStore = await readSource(
  'newIDE/app/src/AssetStore/ResourceStore/ResourceStoreContext.js'
);
const authenticatedUserProvider = await readSource(
  'newIDE/app/src/Profile/AuthenticatedUserProvider.js'
);
const extensionStoreContext = await readSource(
  'newIDE/app/src/AssetStore/ExtensionStore/ExtensionStoreContext.js'
);
const behaviorStoreContext = await readSource(
  'newIDE/app/src/AssetStore/BehaviorStore/BehaviorStoreContext.js'
);
const bundleStoreContext = await readSource(
  'newIDE/app/src/AssetStore/Bundles/BundleStoreContext.js'
);
const privateGameTemplateStoreContext = await readSource(
  'newIDE/app/src/AssetStore/PrivateGameTemplates/PrivateGameTemplateStoreContext.js'
);
const capturesManager = await readSource(
  'newIDE/app/src/MainFrame/UseCapturesManager.js'
);
const generationService = await readSource(
  'newIDE/app/src/Utils/GDevelopServices/Generation.js'
);
const gameService = await readSource(
  'newIDE/app/src/Utils/GDevelopServices/Game.js'
);
const packageJson = JSON.parse(await readSource('newIDE/app/package.json'));
const multiplayerTools = await readSource(
  'Extensions/Multiplayer/multiplayertools.ts'
);
const multiplayerComponents = await readSource(
  'Extensions/Multiplayer/multiplayercomponents.ts'
);
const playerAuthenticationTools = await readSource(
  'Extensions/PlayerAuthentication/playerauthenticationtools.ts'
);
const playerAuthenticationComponents = await readSource(
  'Extensions/PlayerAuthentication/playerauthenticationcomponents.ts'
);

assert.doesNotMatch(browserApp, /CloudStorageProvider/);
assert.match(
  browserApp,
  /storageProviders=\{\[\s*PlaymeshLocalStorageProvider,\s*UrlStorageProvider,\s*DownloadFileStorageProvider,\s*\]\}/
);
assert.match(
  browserApp,
  /defaultStorageProvider=\{PlaymeshLocalStorageProvider\}/
);
assert.match(browserApp, /makePlaymeshEventsFunctionCodeWriter/);
assert.doesNotMatch(
  browserApp,
  /Browser(?:SW|S3)PreviewLauncher|ensureBrowserSWPreviewSession|isServiceWorkerSupported|makeBrowserSWEventsFunctionCodeWriter|makeBrowserS3EventsFunctionCodeWriter/,
  'BrowserApp must leave preview transport selection to the Playmesh router'
);
assert.match(
  browserApp,
  /import PlaymeshPreviewLauncherRouter from '\.\/PlaymeshPreview\/PlaymeshPreviewLauncherRouter';/
);
assert.match(
  browserApp,
  /<PlaymeshPreviewLauncherRouter \{\.\.\.props\} ref=\{ref\} \/>/
);
assert.match(
  previewLauncherRouter,
  /import BrowserSWPreviewLauncher from '\.\.\/ExportAndShare\/BrowserExporters\/BrowserSWPreviewLauncher';/
);
assert.match(
  previewLauncherRouter,
  /import PlaymeshGatewayPreviewLauncher from '\.\/PlaymeshGatewayPreviewLauncher';/
);
assert.doesNotMatch(
  previewLauncherRouter,
  /BrowserS3PreviewLauncher|BrowserS3FileSystem|GDevelopServices\/Preview|makeBrowserS3EventsFunctionCodeWriter|uploadPendingObjects|getBaseUrl\(/,
  'the preview router must not retain an S3 preview fallback or uploader'
);
assert.match(
  browserSwPreviewStore,
  /const documentBaseUri: string = document\.baseURI \|\| window\.location\.href;/
);
assert.match(
  browserSwPreviewStore,
  /new URL\('\.', documentBaseUri\)/
);
assert.match(
  browserSwPreviewStore,
  /'browser_sw_preview'/
);
assert.doesNotMatch(
  browserSwPreviewStore,
  /\$\{origin\}\/browser_sw_preview/,
  'the local preview URL must not escape the current WebIDE subdirectory'
);
assert.match(
  browserSwTemplate,
  /new URL\(self\.registration\.scope\)\.pathname\.replace/
);
assert.match(
  browserSwTemplate,
  /const previewPath = registrationPath \+ 'browser_sw_preview\/'/
);
assert.doesNotMatch(
  browserSwTemplate,
  /workbox-sw\.js|resources\.gdevelop-app\.com|storage\.googleapis\.com|amazonaws\.com/
);
assert.match(
  localPreviewInitializer,
  /new URL\('service-worker\.js', baseUrl\)\.href/
);
assert.match(
  localPreviewInitializer,
  /normalizeDirectoryUrl\(readyRegistration\.scope\) !== baseUrl/
);
assert.match(
  localPreviewInitializer,
  /不会回退到云端预览/
);
assert.doesNotMatch(
  localPreviewInitializer,
  /BrowserS3|GDevelopServices\/Preview|uploadObjects|uploadPendingObjects|getBaseUrl\(/
);

// The upstream historical filename is retained to keep official imports stable,
// but its implementation must resolve the packaged runtime under this WebIDE.
// A remote GDJS CDN here would make both local SW and Gateway previews cloud-backed.
assert.match(localGdjsFinder, /document\.baseURI \|\| window\.location\.href/);
assert.ok(
  localGdjsFinder.includes(
    "const gdjsRoot = new URL('./GDJS', documentBaseUri).href.replace(/\\/$/, '');"
  ),
  'the packaged GDJS root must be resolved under document.baseURI'
);
assert.doesNotMatch(
  localGdjsFinder,
  /resources\.gdevelop-app\.com|storage\.googleapis\.com|amazonaws\.com|localhost:5002|getIDEVersionWithHash|\bWindow\b/,
  'BrowserS3GDJSFinder is a historical name only and must load local GDJS'
);
assert.match(browserApp, /cleanupPlaymeshLegacyBrowserPersistence\(\)/);
assert.doesNotMatch(browserEntry, /registerServiceWorker/);
assert.doesNotMatch(
  projectCache,
  /indexedDB|IDBDatabase|serializeToJSON|createObjectStore|objectStore\(/
);
assert.match(projectCache, /static isAvailable\(\): any \{\s*return false;/);
assert.match(projectCache, /async get\([^]*?return null;/);
assert.doesNotMatch(userUuid, /localStorage|gd-user-uuid/);
assert.doesNotMatch(localStats, /localStorage|gd-local-stats/);
assert.match(browserPersistenceCleanup, /gdevelop-cloud-project-autosave/);
assert.doesNotMatch(browserPersistenceCleanup, /gdevelop-browser-sw-preview/);
assert.match(browserPersistenceCleanup, /deleteDatabase\(databaseName\)/);
assert.doesNotMatch(
  browserPersistenceCleanup,
  /registration\.unregister\(\)|getRegistrations\(\)|service-worker/
);
assert.match(browserPersistenceCleanup, /gd-user-uuid/);
assert.match(browserPersistenceCleanup, /gd-local-stats-program-opening/);
assert.match(
  generatedCodeWriter,
  /\/dev\/api\/gdevelop\/generated-code\//
);
assert.match(generatedCodeWriter, /credentials: 'same-origin'/);
assert.doesNotMatch(generatedCodeWriter, /IndexedDB|indexedDB/);

// 项目、目录下载缓存和事务事实全部属于 App。浏览器侧只保留本页 Map，
// 不能重新引入可跨会话留存的 IndexedDB 副本。
for (const [label, source] of [
  ['project session store', playmeshProjectStore],
  ['catalog staging cache', playmeshCatalogCache],
  ['history restore session journal', playmeshHistoryJournal],
  ['project rekey session journal', playmeshRekeyJournal],
]) {
  assert.doesNotMatch(
    source,
    /indexedDB|IDBDatabase|IDBTransaction|IDBRequest|createObjectStore|objectStore\(/,
    `${label} retained browser persistent storage`
  );
}

for (const forbidden of [
  /FileToCloudProjectResourceUploader/,
  /uploadProjectResourceFiles/,
  /AuthenticatedUserContext/,
  /GDevelop Cloud/,
  /create your account/i,
  /getStorageProvider\(\)\.internalName/,
]) {
  assert.doesNotMatch(
    `${resourceSources}\n${localUploader}`,
    forbidden,
    `browser resource import retained a cloud-only dependency: ${forbidden}`
  );
}

assert.match(
  resourceSources,
  /import FileToPlaymeshLocalResourceUploader from '\.\/FileToPlaymeshLocalResourceUploader';/
);
assert.match(
  resourceSources,
  /renderComponent: \(props: ResourceSourceComponentProps\) => \(\s*<FileToPlaymeshLocalResourceUploader/
);
assert.equal(
  resourceSources.match(/<FileToPlaymeshLocalResourceUploader/g)?.length,
  1,
  'all browser storage providers must share one local resource picker path'
);

// This one unconditional component covers the default/new, PlaymeshLocal,
// Url and DownloadFile project origins. It must remain usable while offline.
for (const provider of [
  'default',
  'PlaymeshLocal',
  'Url',
  'DownloadFile',
]) {
  assert.equal(
    resourceSources.includes('props.getStorageProvider().internalName'),
    false,
    `${provider} resource import must not branch to GDevelop Cloud`
  );
}
assert.match(localUploader, /URL\.createObjectURL\(file\)/);
assert.match(
  localUploader,
  /newResource\.setOrigin\('playmesh-local-resource', file\.name\)/
);
assert.match(localUploader, /if \(resources\.length\) onChooseResources\(resources\)/);
assert.doesNotMatch(localUploader, /\bfetch\b|\baxios\b|disabled=|isConnected/);
assert.doesNotMatch(
  packageJson.scripts['import-resources'],
  /import-zipped-external-editors/,
  'disabled browser editors must not remain a production build download'
);

for (const forbidden of [
  /posthog-js/,
  /app\.posthog\.com/,
  /resources\.gdevelop\.io\/a\/gea\.js/,
  /retrying in 2s/i,
  /Retrying to send the app analytics event/,
]) {
  assert.doesNotMatch(
    eventSender,
    forbidden,
    `official EventSender retained automatic telemetry: ${forbidden}`
  );
}
assert.match(eventSender, /const recordEvent = \(name: string,[\s\S]*?\) => \{\};/);
assert.match(eventSender, /export const installAnalyticsEvents = \(\) => \{\};/);
assert.match(eventSender, /export const identifyUserForAnalytics = \([\s\S]*?\) => \{\};/);
assert.match(eventSender, /export const aliasUserForAnalyticsAfterSignUp = \([\s\S]*?\) => \{\};/);
assert.doesNotMatch(eventSender, /posthog\.(init|capture|identify|alias|reset)/);

// 隐藏的官方云内容入口必须在数据源最低层返回合法空状态，不能依赖网络
// 失败后再降级，否则每次进入 WebIDE 都会制造错误日志与重试流量。
for (const [label, source, forbiddenCalls] of [
  [
    'course store',
    courseStore,
    [/\blistListedCourses\b/, /\blistListedCourseChapters\b/],
  ],
  [
    'announcements feed',
    announcementsFeed,
    [/\blistAllAnnouncements\b/, /\blistAllPromotions\b/],
  ],
  [
    'asset store',
    assetStore,
    [
      /\blistAllPublicAssets\b/,
      /\blistAllAuthors\b/,
      /\blistAllLicenses\b/,
      /\blistListedPrivateAssetPacks\b/,
    ],
  ],
  [
    'resource store',
    resourceStore,
    [/\blistAllResources\b/, /\blistAllAuthors\b/, /\blistAllLicenses\b/],
  ],
  [
    'anonymous profile recommendations',
    authenticatedUserProvider,
    [/\blistDefaultRecommendations\b/, /\bgetAchievements\b/],
  ],
]) {
  for (const forbiddenCall of forbiddenCalls) {
    assert.doesNotMatch(
      source,
      forbiddenCall,
      `${label} retained an automatic official cloud call: ${forbiddenCall}`
    );
  }
}
assert.match(courseStore, /setListedCourses\(\[\]\)/);
assert.match(courseStore, /setListedCourseChapters\(\[\]\)/);
assert.match(announcementsFeed, /setAnnouncements\(\[\]\)/);
assert.match(announcementsFeed, /setPromotions\(\[\]\)/);
assert.match(inAppTutorialProvider, /setInAppTutorialShortHeaders\(\[\]\)/);
assert.doesNotMatch(
  inAppTutorialProvider,
  /fetchInAppTutorialShortHeaders\s*\(/
);
assert.match(assetStore, /setPublicAssetShortHeaders\(\[\]\)/);
assert.match(resourceStore, /setSvgResourcesByUrl\(\{\}\)/);
assert.match(authenticatedUserProvider, /achievements:\s*\[\]/);
assert.match(
  extensionStoreContext,
  /if \(loadedLanguage === language \|\| isLoading\.current\) return;/
);
assert.match(
  behaviorStoreContext,
  /if \(loadedLanguage === language \|\| isLoading\.current\) return;/
);
assert.doesNotMatch(bundleStoreContext, /listListedBundles\s*\(/);
assert.match(
  bundleStoreContext,
  /fetchedBundleListingDatas: Array<BundleListingData> = \[\]/
);
assert.doesNotMatch(
  privateGameTemplateStoreContext,
  /listListedPrivateGameTemplates\s*\(/
);
assert.match(
  privateGameTemplateStoreContext,
  /fetchedPrivateGameTemplateListingDatas: Array<PrivateGameTemplateListingData> = \[\]/
);
assert.doesNotMatch(capturesManager, /createGameResourceSignedUrls\s*\(/);
assert.match(capturesManager, /return \{ screenshots: \[\] \};/);
assert.match(
  generationService,
  /export const fetchAiSettings = async \(\{[\s\S]*?presets: \[\]/
);
assert.doesNotMatch(
  generationService,
  /GDevelopAiCdn\.baseUrl\[environment\][\s\S]*?ai-settings\.json/,
  'the production Generation service must not call the official AI settings endpoint'
);
assert.match(
  gameService,
  /export const getGameCategories = async \(\): Promise<GameCategory\[\]> =>\s*\[\];/
);
assert.doesNotMatch(
  gameService,
  /client\.get\(['"]\/game-category['"]\)/,
  'the production Game service must not call the official game categories endpoint'
);

// 遥测在 EventSender 最低层停用，不通过全局 fetch/XHR 拦截误伤用户主动下载。
assert.match(catalogSource, /fetchCatalogArtifact|loadCatalogJson/);
assert.match(catalogRuntime, /\bfetch\(/);
assert.match(catalogSource, /export const getPlaymeshExtension = async/);
assert.match(catalogSource, /export const getPlaymeshExampleManifest = async/);
assert.match(catalogSource, /export const fetchPlaymeshArtifact =/);
assert.doesNotMatch(eventSender, /global\.fetch\s*=|XMLHttpRequest|window\.fetch\s*=/);

// 这里只禁止运行时自动访问官方多人/身份服务。用户主动点击下载示例或扩展属于
// 独立的可失败目录能力，不应被这个门禁误判为自动 telemetry 或运行时回落。
assert.doesNotMatch(
  multiplayerTools,
  /_websocket = new WebSocket\(wsUrl\.toString\(\)\)/
);
assert.match(
  multiplayerTools,
  /runtimeGlobal\.playmesh[\s\S]*GDevelop Multiplayer backend v1 is unavailable/
);
assert.match(
  multiplayerTools,
  /handleOfficialLobbyFrameMessage\([\s\S]*checkOrigin: false/
);
assert.equal(
  multiplayerTools.match(/postOfficialLobbyFrameMessage\(\s*lobbiesIframe,/g)
    ?.length,
  5
);
assert.match(
  multiplayerComponents,
  /playmeshBackend\.configureOfficialLobbyFrame\(iframe\)[\s\S]*else \{\s*iframe\.src = url;/
);

assert.doesNotMatch(
  playerAuthenticationTools,
  /_websocket = new WebSocket\(wsPlayApi\);/
);
assert.match(
  playerAuthenticationTools,
  /playmeshBackend\.checkGameRegistration\(\{ gameId \}\)/
);
assert.match(
  playerAuthenticationTools,
  /playmeshBackend\.createOfficialAuthenticationControlFacade\(\)/
);
assert.equal(
  playerAuthenticationTools.match(
    /if \(getPlaymeshPlayerAuthenticationBackend\(\)\) return;/g
  )?.length,
  2,
  'Electron and Cordova external auth navigation must be skipped under Playmesh'
);
assert.equal(
  playerAuthenticationTools.match(
    /consumeOfficialAuthenticationFrameMessage\(event\)/g
  )?.length,
  2,
  'web and web-iframe authentication must use the bound local frame capability'
);
assert.match(
  playerAuthenticationComponents,
  /playmeshBackend\.configureOfficialAuthenticationFrame\(iframe\)[\s\S]*else \{\s*iframe\.src = url;/
);

process.stdout.write(
  'GDevelop zero-cloud browser resource source tests passed.\n'
);
