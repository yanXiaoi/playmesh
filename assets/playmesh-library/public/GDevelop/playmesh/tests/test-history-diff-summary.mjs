import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile, readdir } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const summarySourcePath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryDiffSummary.js"
);
const historyUiPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/UsePlaymeshHistory.js"
);
const diffModelPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryDiffModel.js"
);
const diffDialogPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryDiffDialog.js"
);
const diffCssPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryDiffDialog.module.css"
);
const repositoryRoot = path.resolve(testDirectory, "../../../../../..");
const dependencyCacheRoot = path.resolve(
  repositoryRoot,
  "work/gdevelop-webide-build-cache/cache/deps"
);
const dependencyCaches = existsSync(dependencyCacheRoot)
  ? await readdir(dependencyCacheRoot)
  : [];
const appPackage = dependencyCaches
  .map(entry => path.join(dependencyCacheRoot, entry, "package.json"))
  .find(candidate =>
    existsSync(
      path.join(
        path.dirname(candidate),
        "node_modules/@babel/core/package.json"
      )
    )
  );
assert.ok(
  appPackage && existsSync(appPackage),
  "the fixed WebIDE dependency cache is required for the JSX/Flow parse contract"
);
const appRequire = createRequire(appPackage);
const { transformSync } = appRequire("@babel/core");
const flowStripPlugin = appRequire("@babel/plugin-transform-flow-strip-types");
const stripFlowSource = source =>
  transformSync(source, {
    babelrc: false,
    configFile: false,
    plugins: [[flowStripPlugin, { all: true }]],
    parserOpts: { plugins: ["jsx"] },
    sourceType: "module"
  }).code;

const summarySource = stripFlowSource(
  await readFile(summarySourcePath, "utf8")
);
const summaryModule = await import(`data:text/javascript;base64,${Buffer.from(
  summarySource
).toString("base64")}`);
const modelSourceText = await readFile(diffModelPath, "utf8");
assert.match(
  modelSourceText,
  /const evidence = after \|\| before;\s+if \(!evidence\) \{\s+continue;\s+\}/,
  "Map.get resource evidence must be narrowed before its name and MIME are read"
);
const modelSource = stripFlowSource(modelSourceText);
const modelModule = await import(`data:text/javascript;base64,${Buffer.from(
  modelSource
).toString("base64")}`);

const beforeProject = {
  properties: { name: "Before" },
  objects: [{ name: "GlobalScore", type: "TextObject::Text", string: "0" }],
  layouts: [
    {
      name: "Game",
      objects: [
        { name: "Hero", type: "Sprite", animations: ["idle"] },
        { name: "Enemy", type: "Sprite" }
      ],
      instances: [
        { name: "Hero", x: 10, y: 20 },
        { name: "Enemy", x: 50, y: 20 }
      ],
      events: []
    },
    {
      name: "RemovedScene",
      objects: [{ name: "RemovedObject", type: "Sprite" }],
      instances: [],
      events: []
    }
  ],
  externalLayouts: [
    { name: "Hud", instances: [{ name: "HudLabel", x: 0, y: 0 }] }
  ],
  resources: {
    resources: [
      {
        name: "hero.png",
        file: "playmesh-local-resource://history/hero-v1.png",
        kind: "image"
      },
      {
        name: "unused.png",
        file: "playmesh-local-resource://history/unused.png",
        kind: "image"
      }
    ]
  }
};
const afterProject = {
  properties: { name: "After" },
  objects: [{ name: "GlobalScore", type: "TextObject::Text", string: "1" }],
  layouts: [
    {
      name: "Game",
      objects: [
        { name: "Hero", type: "Sprite", animations: ["idle"] },
        { name: "Coin", type: "Sprite" }
      ],
      instances: [
        { name: "Hero", x: 30, y: 20 },
        { name: "Coin", x: 50, y: 20 }
      ],
      events: [{ type: "BuiltinCommonInstructions::Standard" }]
    },
    {
      name: "AddedScene",
      objects: [{ name: "AddedObject", type: "Sprite" }],
      instances: [],
      events: []
    }
  ],
  externalLayouts: [
    { name: "Hud", instances: [{ name: "HudLabel", x: 12, y: 0 }] }
  ],
  resources: {
    resources: [
      {
        name: "hero.png",
        file: "playmesh-local-resource://history/hero-v2.png",
        kind: "image"
      },
      {
        name: "music.ogg",
        file: "playmesh-local-resource://history/music.ogg",
        kind: "audio"
      }
    ]
  }
};

const summary = summaryModule.buildPlaymeshHistoryDiffSummary({
  before: JSON.stringify(beforeProject),
  after: JSON.stringify(afterProject)
});
assert.deepEqual(summary.scenes.added.map(item => item.name), ["AddedScene"]);
assert.deepEqual(summary.scenes.removed.map(item => item.name), [
  "RemovedScene"
]);
assert.deepEqual(summary.scenes.modified.map(item => item.name), ["Game"]);
assert.deepEqual(summary.resources.added.map(item => item.name), ["music.ogg"]);
assert.deepEqual(summary.resources.removed.map(item => item.name), [
  "unused.png"
]);
assert.deepEqual(summary.resources.modified.map(item => item.name), [
  "hero.png"
]);
assert.ok(
  summary.objects.modified.some(
    item => item.locationType === "scene" && item.name === "Hero"
  ),
  "moving a scene instance must identify its object as modified"
);
assert.ok(
  summary.objects.modified.some(
    item => item.locationType === "externalLayout" && item.name === "HudLabel"
  ),
  "external-layout instance changes must not disappear from the object summary"
);
assert.ok(
  summary.objects.modified.some(
    item => item.locationType === "global" && item.name === "GlobalScore"
  )
);
assert.ok(summary.fields.changes.some(change => change.path.includes("Game")));
assert.equal(summary.fields.truncated, false);

const model = modelModule.buildPlaymeshHistoryDiffModel(summary);
assert.deepEqual(
  model.entries
    .filter(entry => entry.category === "resources")
    .map(entry => [entry.status, entry.path]),
  [["added", "music.ogg"], ["modified", "hero.png"], ["removed", "unused.png"]],
  "resources must use Git-like A/M/D rows instead of concatenated names"
);
const modifiedResourceEntry = model.entries.find(
  entry => entry.category === "resources" && entry.status === "modified"
);
assert.equal(
  modifiedResourceEntry.resourceLogicalIdBefore,
  "playmesh-local-resource://history/hero-v1.png"
);
assert.equal(
  modifiedResourceEntry.resourceLogicalIdAfter,
  "playmesh-local-resource://history/hero-v2.png"
);
const addedResourceEntry = model.entries.find(
  entry => entry.category === "resources" && entry.status === "added"
);
assert.equal(addedResourceEntry.resourceLogicalIdBefore, null);
assert.equal(
  addedResourceEntry.resourceLogicalIdAfter,
  "playmesh-local-resource://history/music.ogg"
);
const removedResourceEntry = model.entries.find(
  entry => entry.category === "resources" && entry.status === "removed"
);
assert.equal(
  removedResourceEntry.resourceLogicalIdBefore,
  "playmesh-local-resource://history/unused.png"
);
assert.equal(removedResourceEntry.resourceLogicalIdAfter, null);
assert.ok(
  model.entries.some(
    entry =>
      entry.category === "objects" &&
      entry.path === "Game/Hero" &&
      entry.fields.some(field => field.path.includes(".instances"))
  ),
  "object rows must own their field-level changes"
);
assert.ok(
  model.entries.some(
    entry =>
      entry.category === "project" &&
      entry.fields.some(field => field.path === "$.properties.name")
  ),
  "unscoped project property changes must remain visible"
);
assert.deepEqual(
  modelModule
    .filterPlaymeshHistoryDiffEntries(model, {
      query: "hero.png",
      category: "resources",
      status: "modified"
    })
    .map(entry => entry.path),
  ["hero.png"],
  "query/category/status filters must compose"
);
assert.equal(
  modelModule.groupPlaymeshHistoryDiffEntries(model.entries)[0].category,
  "scenes"
);
const largeResourceModel = modelModule.buildPlaymeshHistoryDiffModel({
  scenes: { added: [], modified: [], removed: [] },
  objects: { added: [], modified: [], removed: [] },
  resources: {
    added: Array.from({ length: 245 }, (_, index) => ({
      key: `asset-${index}.png`,
      name: `asset-${index}.png`,
      value: { kind: "image" }
    })),
    modified: [],
    removed: []
  },
  fields: { changes: [], truncated: false }
});
assert.equal(largeResourceModel.entries.length, 245);
assert.equal(
  new Set(largeResourceModel.entries.map(entry => entry.id)).size,
  245
);
assert.equal(modelModule.HISTORY_DIFF_INITIAL_ENTRY_LIMIT, 80);
assert.equal(modelModule.HISTORY_DIFF_ENTRY_PAGE_SIZE, 80);
assert.equal(modelModule.HISTORY_DIFF_INITIAL_FIELD_LIMIT, 60);
assert.equal(modelModule.HISTORY_DIFF_FIELD_PAGE_SIZE, 60);

const contentOnlyLogicalId =
  "playmesh-local-resource://history/content-only.png";
const contentOnlyResourceModel = modelModule.buildPlaymeshHistoryDiffModel(
  {
    scenes: { added: [], modified: [], removed: [] },
    objects: { added: [], modified: [], removed: [] },
    resources: { added: [], modified: [], removed: [] },
    fields: { changes: [], truncated: false }
  },
  {
    before: [
      {
        logicalId: contentOnlyLogicalId,
        name: "content-only.png",
        contentHash: "1".repeat(64),
        mime: "image/png",
        size: 10
      }
    ],
    after: [
      {
        logicalId: contentOnlyLogicalId,
        name: "content-only.png",
        contentHash: "2".repeat(64),
        mime: "image/png",
        size: 12
      }
    ]
  }
);
assert.deepEqual(
  contentOnlyResourceModel.entries.map(entry => ({
    status: entry.status,
    path: entry.path,
    before: entry.resourceLogicalIdBefore,
    after: entry.resourceLogicalIdAfter
  })),
  [
    {
      status: "modified",
      path: "content-only.png",
      before: contentOnlyLogicalId,
      after: contentOnlyLogicalId
    }
  ],
  "resource bytes changed under a stable logicalId must still get a preview row"
);

const addedOnlyLogicalId =
  "playmesh-local-resource://history/added-evidence.png";
const removedOnlyLogicalId =
  "playmesh-local-resource://history/removed-evidence.ogg";
const oneSidedResourceModel = modelModule.buildPlaymeshHistoryDiffModel(
  {
    scenes: { added: [], modified: [], removed: [] },
    objects: { added: [], modified: [], removed: [] },
    resources: { added: [], modified: [], removed: [] },
    fields: { changes: [], truncated: false }
  },
  {
    before: [
      {
        logicalId: removedOnlyLogicalId,
        name: "removed-evidence.ogg",
        contentHash: "3".repeat(64),
        mime: "audio/ogg",
        size: 20
      }
    ],
    after: [
      {
        logicalId: addedOnlyLogicalId,
        name: "added-evidence.png",
        contentHash: "4".repeat(64),
        mime: "image/png",
        size: 30
      }
    ]
  }
);
assert.deepEqual(
  oneSidedResourceModel.entries.map(entry => ({
    status: entry.status,
    path: entry.path,
    kind: entry.resourceKind,
    before: entry.resourceLogicalIdBefore,
    after: entry.resourceLogicalIdAfter
  })),
  [
    {
      status: "added",
      path: "added-evidence.png",
      kind: "image",
      before: null,
      after: addedOnlyLogicalId
    },
    {
      status: "removed",
      path: "removed-evidence.ogg",
      kind: "audio",
      before: removedOnlyLogicalId,
      after: null
    }
  ],
  "one-sided Map evidence must retain its name, MIME kind and logicalId"
);

const reordered = summaryModule.buildPlaymeshHistoryDiffSummary({
  before: JSON.stringify({ layouts: [{ name: "First" }, { name: "Second" }] }),
  after: JSON.stringify({ layouts: [{ name: "Second" }, { name: "First" }] })
});
assert.ok(
  reordered.fields.changes.some(change => change.path === "$.layouts.[order]"),
  "named-array ordering changes must remain visible in the field diff"
);

assert.throws(
  () =>
    summaryModule.buildPlaymeshHistoryDiffSummary({
      before: "[]",
      after: "{}"
    }),
  /invalid_history_project_json/
);

const historyUiSource = await readFile(historyUiPath, "utf8");
const diffDialogSource = await readFile(diffDialogPath, "utf8");
const diffCssSource = await readFile(diffCssPath, "utf8");
assert.match(
  historyUiSource,
  /import Drawer from ["']@material-ui\/core\/Drawer["'];/
);
assert.match(
  historyUiSource,
  /import PlaymeshHistoryDiffDialog from ["']\.\/PlaymeshHistoryDiffDialog["'];/
);
assert.match(historyUiSource, /<PlaymeshHistoryDiffDialog\b/);
assert.doesNotMatch(
  historyUiSource,
  /styles\.fieldChanges|styles\.changeGrid/,
  "the drawer must not render the full comparison inline"
);
assert.equal(
  (historyUiSource.match(/<DrawerTopBar\b/g) || []).length,
  1,
  "history UI must expose one visible top bar and one close button"
);
const drawerTopBarSource = historyUiSource.match(
  /<DrawerTopBar[\s\S]*?id="playmesh-version-history-drawer"\s*\/>/
);
assert.ok(drawerTopBarSource, "history UI must render its drawer top bar");
assert.doesNotMatch(
  drawerTopBarSource[0],
  /\bicon=/,
  "the shared DrawerTopBar icon slot is an interactive close button and must not be used for decorative history branding"
);
assert.match(
  drawerTopBarSource[0],
  /\bonClose=/,
  "the right-side close button must remain available"
);
assert.match(
  drawerTopBarSource[0],
  /<span aria-hidden="true" style=\{styles\.drawerTitleIcon\}>/,
  "the history icon must render as a non-interactive, screen-reader-hidden decoration inside the title"
);
assert.doesNotMatch(
  historyUiSource,
  /playmesh-version-history-drawer-icon/,
  "the history drawer DOM must not expose a second interactive close control"
);
assert.match(historyUiSource, /buildPlaymeshHistoryDiffSummary/);
assert.match(historyUiSource, /buildPlaymeshHistoryDiffModel/);
assert.match(historyUiSource, /nextDiff\.resourceEvidence/);

assert.match(diffDialogSource, /import Dialog from ["']\.\.\/UI\/Dialog["'];/);
assert.match(diffDialogSource, /id="playmesh-history-diff-dialog"/);
assert.match(diffDialogSource, /maxWidth="xl"/);
assert.match(diffDialogSource, /fullHeight/);
assert.match(diffDialogSource, /onRequestClose=\{onClose\}/);
assert.doesNotMatch(
  diffDialogSource,
  /\bactions=|<FlatButton|<RaisedButton/,
  "the comparison modal must expose one close control only"
);
assert.match(diffDialogSource, /type="search"/);
assert.match(diffDialogSource, /aria-expanded=/);
assert.match(diffDialogSource, /aria-current=/);
assert.match(diffDialogSource, /data-history-diff-entry="true"/);
assert.match(diffDialogSource, /ArrowDown/);
assert.match(diffDialogSource, /ArrowUp/);
assert.match(diffDialogSource, /mobileBackButtonRef\.current\.focus\(\)/);
assert.match(diffDialogSource, /selectedButton\.focus\(\)/);
assert.match(diffDialogSource, /HISTORY_DIFF_INITIAL_ENTRY_LIMIT/);
assert.match(diffDialogSource, /HISTORY_DIFF_INITIAL_FIELD_LIMIT/);
assert.match(diffDialogSource, /mobilePane === ["']detail["']/);
assert.match(diffDialogSource, /<details/);
assert.match(diffDialogSource, /ResourceEvidenceComparison/);
assert.match(diffDialogSource, /side="before"/);
assert.match(diffDialogSource, /side="after"/);
assert.match(diffDialogSource, /aria-label=\{label\}/);
assert.match(diffDialogSource, /preload="metadata"/);
assert.equal(
  (diffDialogSource.match(/data-history-diff-value=/g) || []).length,
  2,
  "before and after values must both use dedicated selectable controls"
);
assert.equal(
  (diffDialogSource.match(/<textarea/g) || []).length,
  2,
  "history field values must render as native read-only text areas"
);
assert.equal(
  (diffDialogSource.match(/\breadOnly\b/g) || []).length,
  2,
  "history value controls must be immutable while remaining selectable"
);
assert.doesNotMatch(diffDialogSource, /createObjectURL|blob:|https?:\/\//);
assert.match(diffCssSource, /grid-template-columns:\s*minmax\(270px, 34%\)/);
assert.match(diffCssSource, /@media \(max-width: 700px\)/);
assert.match(diffCssSource, /@media \(max-width: 430px\)/);
assert.match(
  diffCssSource,
  /\.fieldValues,\s*\n\s*\.rawGrid,\s*\n\s*\.evidenceGrid\s*\{\s*\n\s*grid-template-columns: minmax\(0, 1fr\)/,
  "before/after values must stack on mobile"
);
assert.match(diffCssSource, /\.evidenceGrid\s*\{[\s\S]*?grid-template-columns:\s*minmax\(0, 1fr\) minmax\(0, 1fr\)/);
assert.match(diffCssSource, /\.previewViewport\s*\{[\s\S]*?max-height:\s*240px/);
assert.match(diffCssSource, /\.previewMedia\s*\{[\s\S]*?object-fit:\s*contain/);
assert.match(diffCssSource, /overflow-x: hidden/);
assert.match(diffCssSource, /:focus-visible/);
assert.match(diffCssSource, /\.value\s*\{[\s\S]*?user-select:\s*text/);

for (const [label, source] of [
  ["history drawer", historyUiSource],
  ["history diff dialog", diffDialogSource]
]) {
  assert.doesNotThrow(
    () =>
      transformSync(source, {
        babelrc: false,
        configFile: false,
        plugins: [[flowStripPlugin, { all: true }]],
        parserOpts: { plugins: ["jsx"] },
        sourceType: "module"
      }),
    `${label} must remain valid Flow and JSX`
  );
}

process.stdout.write(
  "GDevelop Git-like history diff model, modal, Flow/JSX and responsive UI contracts passed.\n"
);
