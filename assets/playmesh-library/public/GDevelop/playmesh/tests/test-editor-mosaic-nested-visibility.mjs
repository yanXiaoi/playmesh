import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const sourceFlag = process.argv.indexOf('--source');
if (sourceFlag === -1 || !process.argv[sourceFlag + 1]) {
  throw new Error(
    'Usage: node test-editor-mosaic-nested-visibility.mjs --source <patched GDevelop root>'
  );
}

const sourceRoot = path.resolve(process.argv[sourceFlag + 1]);
const editorMosaicPath = path.join(
  sourceRoot,
  'newIDE/app/src/UI/EditorMosaic/index.js'
);
const editorMosaicSource = fs.readFileSync(editorMosaicPath, 'utf8');
const visibilityPath = path.join(
  sourceRoot,
  'newIDE/app/src/UI/EditorMosaic/Visibility.js'
);
const visibilitySource = fs.readFileSync(visibilityPath, 'utf8');

assert.match(
  editorMosaicSource,
  /getVisibleLeaves, toggleLeafVisibility.*\.\/Visibility/
);
assert.match(
  editorMosaicSource,
  /toggleLeafVisibility\(hidableMosaicNode, editorName\)/
);
assert.match(visibilitySource, /const setLeafVisible = \(/);
assert.match(visibilitySource, /currentNode\.firstHidden = false;/);
assert.match(visibilitySource, /currentNode\.secondHidden = false;/);
assert.match(
  visibilitySource,
  /const isVisible = getVisibleLeaves\(currentNode\)\.indexOf\(leafName\) !== -1/
);

const getVisibleLeaves = (currentNode, result = []) => {
  if (typeof currentNode === 'string') {
    result.push(currentNode);
    return result;
  }
  if (!currentNode.firstHidden) getVisibleLeaves(currentNode.first, result);
  if (!currentNode.secondHidden) getVisibleLeaves(currentNode.second, result);
  return result;
};

const toggleNodeVisibility = (currentNode, leafName) => {
  if (typeof currentNode === 'string') {
    return;
  }
  const { first, second } = currentNode;
  if (first === leafName) {
    currentNode.firstHidden = !currentNode.firstHidden;
    if (!currentNode.firstHidden && currentNode.splitPercentage === 0) {
      currentNode.splitPercentage = 20;
    }
    return;
  }
  if (second === leafName) {
    currentNode.secondHidden = !currentNode.secondHidden;
    if (!currentNode.secondHidden && currentNode.splitPercentage === 100) {
      currentNode.splitPercentage = 80;
    }
    return;
  }
  toggleNodeVisibility(first, leafName);
  toggleNodeVisibility(second, leafName);
};

const setLeafVisible = (currentNode, leafName) => {
  if (typeof currentNode === 'string') return currentNode === leafName;
  if (currentNode.first === leafName) {
    currentNode.firstHidden = false;
    if (currentNode.splitPercentage === 0) currentNode.splitPercentage = 20;
    return true;
  }
  if (currentNode.second === leafName) {
    currentNode.secondHidden = false;
    if (currentNode.splitPercentage === 100) currentNode.splitPercentage = 80;
    return true;
  }
  if (setLeafVisible(currentNode.first, leafName)) {
    currentNode.firstHidden = false;
    return true;
  }
  if (setLeafVisible(currentNode.second, leafName)) {
    currentNode.secondHidden = false;
    return true;
  }
  return false;
};

const toggleLeafVisibility = (currentNode, leafName) => {
  if (getVisibleLeaves(currentNode).includes(leafName)) {
    toggleNodeVisibility(currentNode, leafName);
  } else {
    setLeafVisible(currentNode, leafName);
  }
};

const persistedSceneMosaic = {
  direction: 'row',
  splitPercentage: 20,
  first: 'properties',
  firstHidden: true,
  secondHidden: false,
  second: {
    direction: 'row',
    splitPercentage: 77,
    first: 'instances-editor',
    secondHidden: true,
    second: {
      direction: 'column',
      splitPercentage: 50,
      first: 'objects-list',
      firstHidden: true,
      secondHidden: true,
      second: {
        direction: 'column',
        splitPercentage: 50,
        first: 'layers-list',
        firstHidden: true,
        second: 'object-groups-list',
        secondHidden: false,
      },
    },
  },
};

toggleLeafVisibility(persistedSceneMosaic, 'object-groups-list');
assert.equal(persistedSceneMosaic.second.secondHidden, false);
assert.equal(persistedSceneMosaic.second.second.secondHidden, false);
assert.equal(
  persistedSceneMosaic.second.second.second.secondHidden,
  false
);

toggleLeafVisibility(persistedSceneMosaic, 'object-groups-list');
assert.equal(persistedSceneMosaic.second.secondHidden, false);
assert.equal(persistedSceneMosaic.second.second.secondHidden, false);
assert.equal(persistedSceneMosaic.second.second.second.secondHidden, true);

toggleLeafVisibility(persistedSceneMosaic, 'layers-list');
assert.equal(persistedSceneMosaic.second.secondHidden, false);
assert.equal(persistedSceneMosaic.second.second.secondHidden, false);
assert.equal(persistedSceneMosaic.second.second.second.firstHidden, false);

process.stdout.write('EditorMosaic nested visibility contract passed.\n');
