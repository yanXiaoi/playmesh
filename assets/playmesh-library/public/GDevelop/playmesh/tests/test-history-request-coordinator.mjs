import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { readFile, readdir } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const coordinatorPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/PlaymeshHistoryRequestCoordinator.js"
);
const hookPath = path.resolve(
  testDirectory,
  "../overlays/newIDE/app/src/PlaymeshHistory/UsePlaymeshHistory.js"
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
      path.join(path.dirname(candidate), "node_modules/@babel/core/package.json")
    )
  );
assert.ok(appPackage, "the fixed WebIDE dependency cache is required");
const appRequire = createRequire(appPackage);
const { transformSync } = appRequire("@babel/core");
const flowStripPlugin = appRequire("@babel/plugin-transform-flow-strip-types");
const stripFlow = source =>
  transformSync(source, {
    babelrc: false,
    configFile: false,
    plugins: [[flowStripPlugin, { all: true }]],
    sourceType: "module"
  }).code;

const coordinatorSource = await readFile(coordinatorPath, "utf8");
const coordinatorModule = await import(
  `data:text/javascript;base64,${Buffer.from(
    stripFlow(coordinatorSource)
  ).toString("base64")}`
);
const { PlaymeshHistoryRequestCoordinator } = coordinatorModule;

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
};

const runRead = async ({
  coordinator,
  kind,
  gameId,
  read,
  getCurrentGameId,
  publish
}) => {
  const handle = coordinator.begin(kind, gameId);
  try {
    const value = await read(handle.signal);
    if (coordinator.isCurrent(handle, getCurrentGameId())) publish(value);
  } finally {
    coordinator.finish(handle);
  }
  return handle;
};

// Two list refreshes for one project: the older transport may ignore abort and
// still resolve, but only the latest token is allowed to publish.
{
  const coordinator = new PlaymeshHistoryRequestCoordinator();
  const first = deferred();
  const second = deferred();
  const published = [];
  let currentGameId = "com.example.one";
  const firstRun = runRead({
    coordinator,
    kind: "list",
    gameId: currentGameId,
    read: signal => {
      assert.equal(signal.aborted, false);
      return first.promise;
    },
    getCurrentGameId: () => currentGameId,
    publish: value => published.push(value)
  });
  const secondRun = runRead({
    coordinator,
    kind: "list",
    gameId: currentGameId,
    read: signal => {
      assert.equal(signal.aborted, false);
      return second.promise;
    },
    getCurrentGameId: () => currentGameId,
    publish: value => published.push(value)
  });
  second.resolve("new-list");
  await secondRun;
  first.resolve("stale-list");
  const firstHandle = await firstRun;
  assert.equal(firstHandle.signal.aborted, true);
  assert.deepEqual(published, ["new-list"]);
}

// Project changes cancel both lanes and reject late responses by captured ID.
{
  const coordinator = new PlaymeshHistoryRequestCoordinator();
  const oldCompare = deferred();
  const newList = deferred();
  const published = [];
  let currentGameId = "com.example.old";
  const oldRun = runRead({
    coordinator,
    kind: "compare",
    gameId: currentGameId,
    read: () => oldCompare.promise,
    getCurrentGameId: () => currentGameId,
    publish: value => published.push(value)
  });
  currentGameId = "com.example.new";
  coordinator.cancelAll();
  const newRun = runRead({
    coordinator,
    kind: "list",
    gameId: currentGameId,
    read: () => newList.promise,
    getCurrentGameId: () => currentGameId,
    publish: value => published.push(value)
  });
  oldCompare.resolve("stale-project-diff");
  newList.resolve("new-project-list");
  const [oldHandle] = await Promise.all([oldRun, newRun]);
  assert.equal(oldHandle.signal.aborted, true);
  assert.deepEqual(published, ["new-project-list"]);
}

// Closing the comparison cancels compare only; closing the panel cancels both.
{
  const coordinator = new PlaymeshHistoryRequestCoordinator();
  const closedCompare = deferred();
  const published = [];
  const compareRun = runRead({
    coordinator,
    kind: "compare",
    gameId: "com.example.close",
    read: () => closedCompare.promise,
    getCurrentGameId: () => "com.example.close",
    publish: value => published.push(value)
  });
  assert.equal(coordinator.hasActive("compare"), true);
  coordinator.cancel("compare");
  closedCompare.resolve("closed-comparison");
  const compare = await compareRun;
  assert.equal(compare.signal.aborted, true);
  assert.equal(coordinator.hasActive("compare"), false);
  assert.equal(
    coordinator.isCurrent(compare, "com.example.close"),
    false
  );

  const closedList = deferred();
  const closedSecondCompare = deferred();
  const listRun = runRead({
    coordinator,
    kind: "list",
    gameId: "com.example.close",
    read: () => closedList.promise,
    getCurrentGameId: () => "com.example.close",
    publish: value => published.push(value)
  });
  const secondCompareRun = runRead({
    coordinator,
    kind: "compare",
    gameId: "com.example.close",
    read: () => closedSecondCompare.promise,
    getCurrentGameId: () => "com.example.close",
    publish: value => published.push(value)
  });
  coordinator.cancelAll();
  closedList.resolve("closed-panel-list");
  closedSecondCompare.resolve("closed-panel-comparison");
  const [list, secondCompare] = await Promise.all([
    listRun,
    secondCompareRun
  ]);
  assert.equal(list.signal.aborted, true);
  assert.equal(secondCompare.signal.aborted, true);
  assert.deepEqual(published, []);
}

// Parse the real hook and assert that both client calls receive their lane
// signal; this complements the executable ordering tests above.
const hookSource = await readFile(hookPath, "utf8");
transformSync(hookSource, {
  babelrc: false,
  configFile: false,
  plugins: [[flowStripPlugin, { all: true }]],
  parserOpts: { plugins: ["jsx"] },
  sourceType: "module"
});
assert.match(
  hookSource,
  /listPlaymeshHistory\(\s*capturedGameId,\s*request\.signal\s*\)/
);
assert.match(
  hookSource,
  /getPlaymeshHistoryDiff\([\s\S]*?newestRevision,\s*request\.signal\s*\)/
);
assert.match(hookSource, /requestCoordinatorRef\.current\.cancelAll\(\)/);
for (const setter of [
  "setDiff(null)",
  "setDiffModel(null)",
  "setSelectedVersion(null)",
  "setComparisonError(null)"
]) {
  assert.ok(
    hookSource.split(setter).length - 1 >= 3,
    `${setter} must release project, comparison and panel state`
  );
}

console.log("Playmesh history request coordinator tests passed.");
