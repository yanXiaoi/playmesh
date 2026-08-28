import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceRoot = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshPreview'
);
const runClientSource = await readFile(
  path.join(sourceRoot, 'PlaymeshPreviewRunClient.js'),
  'utf8'
);
const runClient = await import(`data:text/javascript;base64,${Buffer.from(
  runClientSource
).toString('base64')}`);

const gameId = 'com.playmesh.game.gpreview001';
const run = (overrides = {}) => ({
  projectId: gameId,
  runId: 'run-1',
  phase: 'starting',
  joinCode: null,
  links: [],
  message: null,
  updatedAt: 1785800000000,
  ...overrides,
});
const response = (overrides = {}) => ({
  protocolVersion: '1.0.0',
  previewId: 'preview-1',
  gameId,
  expiresAt: 1785800060000,
  run: run(),
  ...overrides,
});

assert.equal(
  runClient.buildPlaymeshPreviewUploadUrl({
    gameId,
  }),
  '/dev/api/gdevelop/projects/com.playmesh.game.gpreview001/preview'
);
assert.equal(
  runClient.assertPlaymeshPreviewResponse(response(), gameId).previewId,
  'preview-1'
);
assert.throws(
  () =>
    runClient.assertPlaymeshPreviewResponse(
      response({ gameId: 'com.playmesh.game.gother001' }),
      gameId
    ),
  /无效的 GDevelop 预览响应/
);

const links = [
  'http://127.0.0.1:9010/play',
  'http://192.168.1.9:9010/play',
  'http://10.80.4.2:9010/play',
];
assert.equal(
  runClient.selectPlaymeshPreviewLink(links, 'http://127.0.0.1:8768/gdevelop/'),
  'http://192.168.1.9:9010/play'
);
assert.equal(
  runClient.selectPlaymeshPreviewLink(links, 'http://10.80.4.2:8768/gdevelop/'),
  'http://10.80.4.2:9010/play'
);

class FakeEventSource {
  static latest = null;

  constructor(url, options) {
    assert.equal(url, '/dev/api/events');
    assert.equal(options.withCredentials, true);
    this.listeners = new Map();
    this.closed = false;
    FakeEventSource.latest = this;
  }

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  emit(type, value) {
    this.listeners.get(type)?.({ data: JSON.stringify(value) });
  }

  close() {
    this.closed = true;
  }
}

{
  const waiting = runClient.waitForPlaymeshPreviewLink({
    initialResponse: response(),
    EventSourceConstructor: FakeEventSource,
    fetchImplementation: () => new Promise(() => {}),
    currentLocation: 'http://10.80.4.2:8768/',
    timeoutMs: 2000,
  });
  FakeEventSource.latest.emit(
    'run.status',
    run({ runId: 'stale-run', phase: 'running', links })
  );
  FakeEventSource.latest.emit('run.status', run({ phase: 'running', links }));
  assert.equal(await waiting, 'http://10.80.4.2:9010/play');
  assert.equal(FakeEventSource.latest.closed, true);
}

{
  const waiting = runClient.waitForPlaymeshPreviewAppRuntime({
    initialResponse: response(),
    EventSourceConstructor: FakeEventSource,
    fetchImplementation: () => new Promise(() => {}),
    timeoutMs: 2000,
  });
  FakeEventSource.latest.emit(
    'run.status',
    run({ phase: 'running', links: [] })
  );
  await waiting;
  assert.equal(FakeEventSource.latest.closed, true);
}

{
  let getCalls = 0;
  const link = await runClient.waitForPlaymeshPreviewLink({
    initialResponse: response(),
    EventSourceConstructor: null,
    fetchImplementation: async (url, options) => {
      getCalls++;
      assert.equal(
        url,
        '/dev/api/gdevelop/projects/com.playmesh.game.gpreview001/preview'
      );
      assert.equal(options.method, 'GET');
      return {
        ok: true,
        status: 200,
        json: async () => response({ run: run({ phase: 'running', links }) }),
      };
    },
    currentLocation: 'http://127.0.0.1:8768/',
    timeoutMs: 2000,
    pollIntervalMs: 1,
  });
  assert.equal(link, 'http://192.168.1.9:9010/play');
  assert.equal(getCalls, 1);
}

let gatewayClientSource = await readFile(
  path.join(sourceRoot, 'PlaymeshGatewayPreviewClient.js'),
  'utf8'
);
const gatewayMocks = {
  supportsPlaymeshStreamingUpload: () => true,
  uploadPlaymeshPackageStream: null,
  uploadPlaymeshPackageBlob: null,
  assertPlaymeshPreviewResponse: runClient.assertPlaymeshPreviewResponse,
  buildPlaymeshPreviewUploadUrl: runClient.buildPlaymeshPreviewUploadUrl,
  PlaymeshPreviewRunError: runClient.PlaymeshPreviewRunError,
};
globalThis.__playmeshGatewayPreviewMocks = gatewayMocks;
gatewayClientSource = gatewayClientSource
  .replace(
    /import \{[\s\S]*?\} from '\.\.\/ExportAndShare\/PlaymeshPackageUploader';/,
    `const {
  supportsPlaymeshStreamingUpload,
  uploadPlaymeshPackageBlob,
  uploadPlaymeshPackageStream,
} = globalThis.__playmeshGatewayPreviewMocks;`
  )
  .replace(
    /import \{[\s\S]*?\} from '\.\/PlaymeshPreviewRunClient';/,
    `const {
  assertPlaymeshPreviewResponse,
  buildPlaymeshPreviewUploadUrl,
  PlaymeshPreviewRunError,
} = globalThis.__playmeshGatewayPreviewMocks;`
  );
const gatewayClient = await import(`data:text/javascript;base64,${Buffer.from(
  gatewayClientSource
).toString('base64')}`);

{
  let streamCalls = 0;
  let blobCalls = 0;
  const result = await gatewayClient.uploadPlaymeshGatewayPreview({
    producer: {},
    gameId,
    supportsStreaming: () => true,
    streamUploader: async args => {
      streamCalls++;
      assert.equal(
        args.requestUrl,
        '/dev/api/gdevelop/projects/com.playmesh.game.gpreview001/preview'
      );
      assert.doesNotMatch(args.requestUrl, /token|packages\/import/);
      return args.responseValidator(response());
    },
    blobUploader: async () => {
      blobCalls++;
    },
  });
  assert.equal(result.previewId, 'preview-1');
  assert.equal(streamCalls, 1);
  assert.equal(blobCalls, 0);
}

{
  let confirmed = 0;
  let blobCalls = 0;
  const fallbackResult = await gatewayClient.uploadPlaymeshGatewayPreview({
    producer: {},
    gameId,
    supportsStreaming: () => true,
    streamUploader: async () => {
      throw Object.assign(new Error('stream unavailable before body'), {
        safeToRetry: true,
        bytesProduced: 0,
      });
    },
    confirmBlobFallback: async () => {
      confirmed++;
      return true;
    },
    blobUploader: async args => {
      blobCalls++;
      return args.responseValidator(response());
    },
  });
  assert.equal(fallbackResult.previewId, 'preview-1');
  assert.equal(confirmed, 1);
  assert.equal(blobCalls, 1);
}

const packageSource = await readFile(
  path.join(sourceRoot, 'PlaymeshGatewayPreviewPackage.js'),
  'utf8'
);

// Execute the real preview package coordinator against an exported GDevelop
// file fixture. A game_not_multiplayer/conflict plan must keep the playable
// index, construct RuntimeGame, start its first scene, and never select a
// diagnostic document in place of the export.
{
  let exportCalls = 0;
  class FakeBrowserFileSystem {
    constructor() {
      this.textFiles = [];
    }

    getAllTextFilesIn() {
      return this.textFiles;
    }

    getAllUrlFilesIn() {
      return [];
    }
  }

  class FakeExporter {
    constructor(fileSystem) {
      this.fileSystem = fileSystem;
    }

    setCodeOutputDirectory() {}

    exportProjectForPixiPreview() {
      exportCalls++;
      this.fileSystem.textFiles = [
        {
          filePath: '/export/index.html',
          text:
            '<!doctype html><html><head>' +
            '<script src="gdjs.js"></script>' +
            '<script src="data.js"></script>' +
            '<script src="code0.js"></script>' +
            '<script src="code8.js"></script></head><body>' +
            '<script>new gdjs.RuntimeGame(gdjs.projectData).startGameLoop();</script>' +
            '</body></html>',
        },
        {
          filePath: '/export/gdjs.js',
          text:
            'globalThis.gdjs = {};' +
            'gdjs.RuntimeGame = function(projectData) {' +
            'if (!projectData || !Array.isArray(projectData.variables)) throw new Error("project data missing");' +
            'globalThis.__runtimeGameConstructions++;' +
            'this.startGameLoop = function() { globalThis.__firstSceneStarts++; };' +
            '};',
        },
        {
          filePath: '/export/data.js',
          text:
            'gdjs.projectData = { variables: [], firstLayout: "FirstScene" };',
        },
        {
          filePath: '/export/code0.js',
          text: 'globalThis.__generatedSceneFiles.push("code0.js");',
        },
        {
          filePath: '/export/code8.js',
          text: 'globalThis.__generatedSceneFiles.push("code8.js");',
        },
      ];
    }

    delete() {}
  }

  class FakePreviewExportOptions {
    constructor() {
      return new Proxy(this, {
        get(target, property) {
          if (property in target) return target[property];
          return () => {};
        },
      });
    }

    delete() {}
  }

  const toPackagePath = filePath =>
    `app/${filePath.replace(/^\/export\//, '')}`;
  globalThis.__playmeshGatewayPreviewPackageMocks = {
    assignIn: (_, source) => source,
    findGDJS: async () => ({ filesContent: {}, gdjsRoot: '/runtime/' }),
    BrowserFileSystem: FakeBrowserFileSystem,
    downloadUrlFilesToBlobFiles: async () => [],
    Window: { isDev: () => true },
    getIDEVersionWithHash: () => 'fixture-version',
    isNativeMobileApp: () => false,
    GDevelopAuthorityBootstrapSource: '// authority fixture',
    GDevelopAppRuntimeDebuggerClientSource: '// debugger fixture',
    GDevelopFpsProbeSource: '// playmesh.gdevelop.fps-probe.v1 performanceApi.reportFrame()',
    GDevelopMultiplayerBridgeSource: '// bridge fixture',
    fetchPlaymeshDeveloperStatus: async () => ({
      gameSdkVersion: '1.0.0',
      appSdkVersion: '1.0.0',
    }),
    buildGDevelopGameManifest: input => {
      globalThis.__playmeshGatewayPreviewManifestInput = input;
      return {
        id: input.gameId,
        mode: input.mode,
        game: { entry: 'index.html' },
      };
    },
    createPlaymeshPackageEntryProducer: fileMap => ({ fileMap }),
    createPlaymeshPackageFileMap: args => {
      const { resourcesDownloadOutput, manifest } = args;
      globalThis.__playmeshGatewayPreviewPackageArgs = args;
      const fixtureFileMap = new Map(
        resourcesDownloadOutput.textFiles.map(file => [
          toPackagePath(file.filePath),
          { kind: 'text', text: file.text },
        ])
      );
      fixtureFileMap.set('main.json', {
        kind: 'text',
        text: JSON.stringify(manifest),
      });
      return fixtureFileMap;
    },
    GDEVELOP_AUTHORITY_ENTRY: 'static/js/service/index.js',
    resolvePlaymeshProjectRuntimePlan: async () => ({
      configStatus: 'single',
      config: {
        minPlayers: 1,
        maxPlayers: 1,
        tags: [],
        webRuntimeMultithreading: true,
      },
      scanActivation: 'enabled',
      plan: {
        bundlePresence: 'full',
        runtimeActivation: 'inactive',
        presentation: 'game',
        manifestMode: 'solo',
        connectCore: false,
        blockBeforeExport: false,
        warning: null,
        reason: 'explicit_single_scan_enabled',
      },
    }),
    getPlaymeshMessage: key => key,
    playmeshMessages: {
      projectConfigScanUnknownWarning: 'scan-warning',
    },
  };
  globalThis.gd = {
    AbstractFileSystemJS: class {},
    Exporter: FakeExporter,
    PreviewExportOptions: FakePreviewExportOptions,
  };
  const packagePreamble = `const {
    assignIn,
    findGDJS,
    BrowserFileSystem,
    downloadUrlFilesToBlobFiles,
    Window,
    getIDEVersionWithHash,
    isNativeMobileApp,
    GDevelopAuthorityBootstrapSource,
    GDevelopAppRuntimeDebuggerClientSource,
    GDevelopFpsProbeSource,
    GDevelopMultiplayerBridgeSource,
    fetchPlaymeshDeveloperStatus,
    buildGDevelopGameManifest,
    createPlaymeshPackageEntryProducer,
    createPlaymeshPackageFileMap,
    GDEVELOP_AUTHORITY_ENTRY,
    resolvePlaymeshProjectRuntimePlan,
    getPlaymeshMessage,
    playmeshMessages,
  } = globalThis.__playmeshGatewayPreviewPackageMocks;\n`;
  const executablePackageSource =
    packagePreamble +
    packageSource
      .replace(/^import[\s\S]*?;\r?\n/gm, '')
      .replace('const gd: libGDevelop = global.gd;', 'const gd = global.gd;');
  const packageModule = await import(
    `data:text/javascript;base64,${Buffer.from(executablePackageSource).toString(
      'base64'
    )}`
  );
  const previewPackage = await packageModule.createPlaymeshGatewayPreviewPackage({
    previewOptions: {
      project: { getTemplateSlug: () => '' },
      isForInGameEdition: false,
      fullLoadingScreen: false,
    },
    launcherProps: {
      playmeshGameId: gameId,
      crashReportUploadLevel: 'none',
      previewContext: 'fixture',
      sourceGameId: '',
      getIncludeFileHashs: () => ({}),
    },
  });
  assert.equal(exportCalls, 1, 'solo warning plans must export the real game');
  assert.equal(previewPackage.manifest.mode, 'solo');
  assert.equal(
    globalThis.__playmeshGatewayPreviewManifestInput
      .webRuntimeMultithreading,
    true
  );
  assert.equal(previewPackage.runtimePlan.plan.connectCore, false);
  assert.match(
    globalThis.__playmeshGatewayPreviewPackageArgs.fpsProbeSource,
    /playmesh\.gdevelop\.fps-probe\.v1/
  );
  assert.equal(
    'injectPlaymeshRuntime' in globalThis.__playmeshGatewayPreviewPackageArgs,
    false,
    'Playmesh packages have one canonical runtime shell path'
  );
  const playableHtml = previewPackage.fileMap.get('app/index.html').text;
  assert.match(playableHtml, /new gdjs\.RuntimeGame\(gdjs\.projectData\)/);
  assert.match(
    playableHtml,
    /<script src="playmesh-gdevelop-app-runtime-debugger-client\.js"><\/script>/
  );
  assert.equal(
    previewPackage.fileMap.get(
      'app/playmesh-gdevelop-app-runtime-debugger-client.js'
    ).text,
    '// debugger fixture'
  );
  assert.doesNotMatch(playableHtml, /多人配置与当前工程状态不一致/);

  const runtimeContext = vm.createContext({
    __runtimeGameConstructions: 0,
    __firstSceneStarts: 0,
    __generatedSceneFiles: [],
  });
  for (const match of playableHtml.matchAll(
    /<script\b([^>]*)>([\s\S]*?)<\/script>/gi
  )) {
    const src = match[1].match(/\bsrc=["']([^"']+)["']/i)?.[1];
    const script = src
      ? previewPackage.fileMap.get(`app/${src}`).text
      : match[2];
    vm.runInContext(script, runtimeContext, {
      filename: src || 'exported-index-inline.js',
    });
  }
  assert.equal(runtimeContext.__runtimeGameConstructions, 1);
  assert.equal(runtimeContext.__firstSceneStarts, 1);
  assert.deepEqual([...runtimeContext.__generatedSceneFiles], [
    'code0.js',
    'code8.js',
  ]);

  await assert.rejects(
    packageModule.createPlaymeshGatewayPreviewPackage({
      previewOptions: {
        project: { getTemplateSlug: () => '' },
        isForInGameEdition: true,
        fullLoadingScreen: false,
      },
      launcherProps: {
        playmeshGameId: gameId,
        crashReportUploadLevel: 'none',
        previewContext: 'fixture',
        sourceGameId: '',
        getIncludeFileHashs: () => ({}),
      },
    }),
    /必须使用本地官方预览链/,
    'in-game edition must never be packaged or uploaded through Playmesh'
  );
}
const launcherSource = await readFile(
  path.join(sourceRoot, 'PlaymeshGatewayPreviewLauncher.js'),
  'utf8'
);
assert.match(
  packageSource,
  /new gd\.PreviewExportOptions\([\s\S]*previewOptions\.project,[\s\S]*outputDir[\s\S]*\)/
);
assert.match(packageSource, /setLayoutName\(sceneName\)/);
assert.match(packageSource, /setExternalLayoutName\(externalLayoutName\)/);
assert.match(packageSource, /setNonRuntimeScriptsCacheBurst\(0\)/);
assert.match(packageSource, /useWindowMessageDebuggerClient\(\)/);
assert.match(packageSource, /GDevelopAppRuntimeDebuggerClientSource/);
assert.match(packageSource, /GDevelopFpsProbeSource/);
assert.doesNotMatch(
  packageSource,
  /setNonRuntimeScriptsCacheBurst\(Date\.now\(\)\)/
);
assert.doesNotMatch(gatewayClientSource, /sceneName|externalLayoutName/);
assert.match(packageSource, /createPlaymeshPackageFileMap/);
assert.match(packageSource, /createPlaymeshPackageEntryProducer/);
assert.match(packageSource, /resolvePlaymeshProjectRuntimePlan/);
assert.match(packageSource, /gameId = launcherProps\.playmeshGameId/);
assert.match(packageSource, /target: 'preview'/);
assert.doesNotMatch(packageSource, /plan\.presentation === 'diagnostic'/);
assert.doesNotMatch(packageSource, /createPlaymeshConfigDiagnosticFile/);
assert.match(packageSource, /const manifestMode = plan\.manifestMode/);
assert.match(packageSource, /mode: manifestMode/);
assert.match(packageSource, /if \(previewOptions\.isForInGameEdition\)/);
const packageEmbeddedGuardIndex = packageSource.indexOf(
  'if (previewOptions.isForInGameEdition)'
);
assert.ok(packageEmbeddedGuardIndex !== -1);
for (const forbiddenBeforeGuard of [
  'runtimePlanLoader({',
  'statusLoader()',
  'createPlaymeshPackageFileMap({',
]) {
  const operationIndex = packageSource.indexOf(forbiddenBeforeGuard);
  assert.ok(
    operationIndex === -1 || packageEmbeddedGuardIndex < operationIndex,
    `embedded package guard must precede ${forbiddenBeforeGuard}`
  );
}
assert.doesNotMatch(packageSource, /runtimeInjection:/);
assert.match(packageSource, /multiplayerBridgeSource:\s*GDevelopMultiplayerBridgeSource/);
assert.match(packageSource, /fpsProbeSource:\s*GDevelopFpsProbeSource/);
assert.doesNotMatch(packageSource, /injectPlaymeshRuntime/);
assert.match(
  packageSource,
  /authorityBootstrapSource:\s*GDevelopAuthorityBootstrapSource/
);
assert.doesNotMatch(packageSource, /projectConfigPreviewDiagnostic/);
assert.doesNotMatch(
  packageSource,
  /resolveGDevelopMultiplayerManifestMode|resolveGDevelopRuntimeActivation|explicitMultiplayer|detectedMultiplayerActivation/
);
assert.match(launcherSource, /canDoNetworkPreview = \(\): boolean => false/);
assert.match(
  launcherSource,
  /immediatelyPreparePreviewWindows[\s\S]*Array<WindowProxy> => \[\]/
);
assert.match(launcherSource, /waitForPlaymeshPreviewAppRuntime/);
assert.match(launcherSource, /playmeshPreviewDebuggerServer/);
assert.match(launcherSource, /getPreviewDebuggerServer[\s\S]*playmeshPreviewDebuggerServer/);
assert.match(launcherSource, /playmeshPreviewDebuggerServer\.startServer/);
assert.match(launcherSource, /playmeshPreviewDebuggerServer\.bindAppRuntime/);
assert.match(launcherSource, /playmeshPreviewDebuggerServer\.unbindAppRuntime/);
assert.doesNotMatch(launcherSource, /setEmbeddedGameFramePreviewLocation/);
assert.doesNotMatch(launcherSource, /surface:\s*['"]embedded['"]/);
assert.match(launcherSource, /if \(previewOptions\.isForInGameEdition\)/);
assert.match(
  launcherSource,
  /GDevelop 游戏内编辑器必须使用本地官方预览链，不能进入 Playmesh 包预览。/
);
const launcherEmbeddedGuardIndex = launcherSource.indexOf(
  'if (previewOptions.isForInGameEdition)'
);
assert.ok(launcherEmbeddedGuardIndex !== -1);
for (const forbiddenBeforeGuard of [
  'createPlaymeshGatewayPreviewPackage({',
  'uploadPlaymeshGatewayPreview({',
]) {
  const operationIndex = launcherSource.indexOf(forbiddenBeforeGuard);
  assert.ok(
    launcherEmbeddedGuardIndex < operationIndex,
    `embedded launcher guard must precede ${forbiddenBeforeGuard}`
  );
}
assert.doesNotMatch(launcherSource, /window\.open|window\.location|<iframe/);
assert.match(launcherSource, /stopPlaymeshPreview/);
assert.match(launcherSource, /signal: abortController\.signal/);
assert.doesNotMatch(launcherSource, /hotReloadAll|sendMessage\(.*hotReload/);

process.stdout.write('GDevelop DeveloperRun gateway preview tests passed.\n');
