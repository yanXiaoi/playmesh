import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const sourcePath = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "GDevelop",
  "playmesh",
  "overlays",
  "newIDE",
  "app",
  "src",
  "PlaymeshAi",
  "PlaymeshAiProjectContext.js",
);
const serializerPath = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "GDevelop",
  "playmesh",
  "overlays",
  "newIDE",
  "app",
  "src",
  "ProjectsStorage",
  "PlaymeshLocalStorageProvider",
  "PlaymeshProjectSerializer.js",
);
const dependencyCache = path.join(
  repositoryRoot,
  "work",
  "gdevelop-webide-build-cache",
  "cache",
  "deps",
);
const dependencyRoot = fs
  .readdirSync(dependencyCache, { withFileTypes: true })
  .filter(
    entry =>
      entry.isDirectory() &&
      !entry.name.startsWith(".") &&
      !entry.name.startsWith("gdjs-"),
  )
  .map(entry => path.join(dependencyCache, entry.name))
  .find(candidate =>
    fs.existsSync(path.join(candidate, "node_modules", "@babel", "core")),
  );
assert.ok(dependencyRoot, "cached GDevelop Babel dependencies are required");

const dependencyRequire = createRequire(path.join(dependencyRoot, "package.json"));
const babel = dependencyRequire("@babel/core");
const presetFlow = dependencyRequire("@babel/preset-flow");
const transformModules = dependencyRequire(
  "@babel/plugin-transform-modules-commonjs",
);
const transformed = babel.transformSync(fs.readFileSync(sourcePath, "utf8"), {
  babelrc: false,
  configFile: false,
  filename: sourcePath,
  plugins: [transformModules],
  presets: [[presetFlow, { all: true }]],
});
assert.ok(transformed?.code);
const serializerSource = fs.readFileSync(serializerPath, "utf8");
assert.doesNotThrow(() =>
  babel.transformSync(serializerSource, {
    babelrc: false,
    configFile: false,
    filename: serializerPath,
    plugins: [transformModules],
    presets: [[presetFlow, { all: true }]],
  }),
);
assert.match(
  serializerSource,
  /export const getPlaymeshLogicalResourceUrl[\s\S]*objectUrlToLogicalUrl\.get\(objectUrl\)/,
);
assert.match(
  serializerSource,
  /objectUrlToLogicalUrl\.set\(objectUrl, resource\.logicalUrl\)/,
);

const runtimeResourceAddress = "blob:runtime-address-never-log";
const logicalResourceAddress =
  "playmesh-local-resource://logical-project-reference";
const lanRuntimeAddressWithQueryToken =
  "http://192.0.2.10:4100/runtime?token=runtime-token-never-log";
const secretFixture = "Bearer secret-never-log";
const independentQueryTokenFixture =
  "mode=preview&token=independent-secret-never-log";
let simplifiedProjectFixture = null;
let extensionSummaryFixture = null;
let selectedSceneEventsFixture = "Scene event text";
let resolveLogicalResource = value =>
  value === runtimeResourceAddress ? logicalResourceAddress : null;
const diagnosticLines = [];

const mocks = {
  "../EditorFunctions/SimplifiedProject/SimplifiedProject": {
    makeSimplifiedProjectBuilder: () => ({
      getSimplifiedProject: () => structuredClone(simplifiedProjectFixture),
      getProjectSpecificExtensionsSummary: () =>
        structuredClone(extensionSummaryFixture),
    }),
  },
  "../EventsSheet/EventsTree/TextRenderer": {
    renderNonTranslatedEventsAsText: () => selectedSceneEventsFixture,
  },
  "./PlaymeshAiProtocol": {
    PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION: "1.0.0",
    validatePlaymeshAiCapabilitiesReference: value => structuredClone(value),
  },
  "../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer": {
    getPlaymeshLogicalResourceUrl: value => resolveLogicalResource(value),
  },
};
const module = { exports: {} };
const evaluate = new Function(
  "require",
  "module",
  "exports",
  "global",
  transformed.code,
);
evaluate(
  request => {
    assert.ok(mocks[request], `unexpected module import: ${request}`);
    return mocks[request];
  },
  module,
  module.exports,
  {
    console: {
      info(line) {
        diagnosticLines.push(String(line));
      },
    },
  },
);
const {
  buildPlaymeshAiProjectContext,
  PlaymeshAiProjectContextError,
} = module.exports;

const baseSimplifiedProject = () => ({
  properties: { gameResolutionWidth: 800, gameResolutionHeight: 600 },
  globalObjects: [],
  globalObjectGroups: [],
  scenes: [
    {
      sceneName: "Scene",
      objects: [],
      objectGroups: [],
      sceneVariables: [],
      layers: [],
      instancesOnSceneDescription: "",
    },
  ],
  globalVariables: [],
  resources: [
    { name: "First", type: "image", file: "first.png" },
    { name: "Second", type: "audio", file: "second.ogg" },
    {
      name: runtimeResourceAddress,
      type: "image",
      file: runtimeResourceAddress,
    },
  ],
});
const safeSimplifiedProject = () => {
  const projectFixture = baseSimplifiedProject();
  return { ...projectFixture, resources: projectFixture.resources.slice(0, 2) };
};
const project = {
  hasLayoutNamed: name => name === "Scene",
  getLayout: () => ({ getEvents: () => ({}) }),
};
const capabilities = {
  contractHash: "0".repeat(64),
  protocolVersion: "1.0.0",
  toolsVersion: "1.0.0",
  gdevelopVersion: "5.6.276",
  upstreamCommit: "commit",
  storeNetworkEnabled: false,
  toolCount: 1,
};
const build = () =>
  buildPlaymeshAiProjectContext({
    project,
    selectedSceneName: "Scene",
    capabilities,
    gd: {},
  });
const assertRejectedAt = (expectedPath, forbiddenValue) => {
  assert.throws(
    build,
    error => {
      assert.ok(error instanceof PlaymeshAiProjectContextError);
      assert.equal(error.code, "project_context_url_or_token_forbidden");
      assert.equal(error.diagnosticPath, expectedPath);
      assert.equal(error.diagnosticType, "string");
      assert.equal(error.reason, `path=${expectedPath} type=string`);
      assert.doesNotMatch(error.reason, new RegExp(forbiddenValue, "i"));
      return true;
    },
  );
};

simplifiedProjectFixture = baseSimplifiedProject();
extensionSummaryFixture = { extensionSummaries: [] };
const restored = build();
const restoredResource = restored.projectSummary.simplifiedProject.resources[2];
assert.equal(restoredResource.name, logicalResourceAddress);
assert.equal(restoredResource.file, logicalResourceAddress);
assert.deepEqual(Object.keys(restored).sort(), [
  "capabilities",
  "projectSummary",
  "schemaVersion",
  "selectedScene",
]);
assert.equal("history" in restored, false);
assert.equal("projectReference" in restored, false);
assert.equal(diagnosticLines.length, 1);
assert.equal(
  diagnosticLines[0],
  "[PlayMesh AI] project_context_sanitized " +
    "path=$.projectSummary.simplifiedProject.resources[2].file " +
    "type=string kind=runtime_address_restored",
);
assert.doesNotMatch(diagnosticLines[0], /blob:|playmesh-local-resource:|secret/i);

diagnosticLines.length = 0;
resolveLogicalResource = () => null;
simplifiedProjectFixture = {
  ...baseSimplifiedProject(),
  resources: [
    {
      name: runtimeResourceAddress,
      type: "image",
      file: runtimeResourceAddress,
    },
  ],
};
const omitted = build();
const omittedResource = omitted.projectSummary.simplifiedProject.resources[0];
assert.doesNotMatch(omittedResource.name, /blob:/i);
assert.doesNotMatch(omittedResource.file, /blob:/i);
assert.match(diagnosticLines[0], /resources\[0\]\.file type=string/);

diagnosticLines.length = 0;
simplifiedProjectFixture = baseSimplifiedProject();
extensionSummaryFixture = {
  extensionSummaries: [{ description: secretFixture }],
};
assert.throws(
  build,
  error => {
    assert.ok(error instanceof PlaymeshAiProjectContextError);
    assert.equal(error.code, "project_context_url_or_token_forbidden");
    assert.equal(
      error.diagnosticPath,
      "$.projectSummary.projectSpecificExtensionsSummary." +
        "extensionSummaries[0].description",
    );
    assert.equal(error.diagnosticType, "string");
    assert.equal(
      error.reason,
      "path=$.projectSummary.projectSpecificExtensionsSummary." +
        "extensionSummaries[0].description type=string",
    );
    assert.doesNotMatch(error.reason, /secret-never-log/i);
    return true;
  },
);

extensionSummaryFixture = {
  extensionSummaries: [
    { description: "A token economy is ordinary natural-language content." },
  ],
};
assert.doesNotThrow(build);

// Runtime transport addresses win over embedded query credentials at the DTO
// boundary. Cover every source that enters the AI context so a hydrated LAN
// URL cannot escape merely because it includes `?token=`.
const runtimeAddressCases = [
  {
    name: "resource",
    configure() {
      simplifiedProjectFixture = {
        ...baseSimplifiedProject(),
        resources: [
          {
            name: lanRuntimeAddressWithQueryToken,
            type: "image",
            file: lanRuntimeAddressWithQueryToken,
          },
        ],
      };
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = "Scene event text";
    },
    read(context) {
      const resource = context.projectSummary.simplifiedProject.resources[0];
      return [resource.name, resource.file];
    },
    diagnosticPath:
      "$.projectSummary.simplifiedProject.resources[0].file",
  },
  {
    name: "properties",
    configure() {
      simplifiedProjectFixture = safeSimplifiedProject();
      simplifiedProjectFixture.properties.runtimeLocation =
        lanRuntimeAddressWithQueryToken;
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = "Scene event text";
    },
    read(context) {
      return [
        context.projectSummary.simplifiedProject.properties.runtimeLocation,
      ];
    },
    diagnosticPath:
      "$.projectSummary.simplifiedProject.properties.runtimeLocation",
  },
  {
    name: "events",
    configure() {
      simplifiedProjectFixture = safeSimplifiedProject();
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = lanRuntimeAddressWithQueryToken;
    },
    read(context) {
      return [context.selectedScene.eventsText];
    },
    diagnosticPath: "$.selectedScene.eventsText",
  },
  {
    name: "extension",
    configure() {
      simplifiedProjectFixture = safeSimplifiedProject();
      extensionSummaryFixture = {
        extensionSummaries: [
          { description: lanRuntimeAddressWithQueryToken },
        ],
      };
      selectedSceneEventsFixture = "Scene event text";
    },
    read(context) {
      return [
        context.projectSummary.projectSpecificExtensionsSummary
          .extensionSummaries[0].description,
      ];
    },
    diagnosticPath:
      "$.projectSummary.projectSpecificExtensionsSummary." +
      "extensionSummaries[0].description",
  },
];
for (const testCase of runtimeAddressCases) {
  diagnosticLines.length = 0;
  resolveLogicalResource = () => null;
  testCase.configure();
  const context = build();
  for (const sanitized of testCase.read(context)) {
    assert.doesNotMatch(
      sanitized,
      /https?:|token=|runtime-token-never-log/i,
      `${testCase.name} runtime address must be omitted or mapped`,
    );
  }
  assert.equal(diagnosticLines.length, 1);
  assert.match(
    diagnosticLines[0],
    new RegExp(
      `path=${testCase.diagnosticPath.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} ` +
        "type=string kind=runtime_address_(?:restored|omitted)$",
    ),
  );
  assert.doesNotMatch(diagnosticLines[0], /https?:|token=|never-log/i);
}

// Strings that are credentials rather than transport addresses are not
// sanitized away. The final strict review must reject each source path.
const strictSecretCases = [
  {
    path: "$.projectSummary.simplifiedProject.resources[0].file",
    value: secretFixture,
    configure(value) {
      simplifiedProjectFixture = {
        ...baseSimplifiedProject(),
        resources: [{ name: "Secret", type: "image", file: value }],
      };
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = "Scene event text";
    },
  },
  {
    path: "$.projectSummary.simplifiedProject.properties.runtimeLocation",
    value: independentQueryTokenFixture,
    configure(value) {
      simplifiedProjectFixture = safeSimplifiedProject();
      simplifiedProjectFixture.properties.runtimeLocation = value;
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = "Scene event text";
    },
  },
  {
    path: "$.selectedScene.eventsText",
    value: secretFixture,
    configure(value) {
      simplifiedProjectFixture = safeSimplifiedProject();
      extensionSummaryFixture = { extensionSummaries: [] };
      selectedSceneEventsFixture = value;
    },
  },
  {
    path:
      "$.projectSummary.projectSpecificExtensionsSummary." +
      "extensionSummaries[0].description",
    value: independentQueryTokenFixture,
    configure(value) {
      simplifiedProjectFixture = safeSimplifiedProject();
      extensionSummaryFixture = { extensionSummaries: [{ description: value }] };
      selectedSceneEventsFixture = "Scene event text";
    },
  },
];
for (const testCase of strictSecretCases) {
  diagnosticLines.length = 0;
  testCase.configure(testCase.value);
  assertRejectedAt(testCase.path, "(?:secret|independent-secret)-never-log");
  assert.equal(diagnosticLines.length, 0);
}

console.log("GDevelop AI real project resource-shape contract passed.");
