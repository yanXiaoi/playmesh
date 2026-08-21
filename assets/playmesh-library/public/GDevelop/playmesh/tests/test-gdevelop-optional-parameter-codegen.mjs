import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const lockPath = path.join(playmeshDirectory, 'webide-lock.json');
const libGdConfigPath = path.join(
  repositoryRoot,
  'work',
  'gdevelop-webide-build-cache',
  'profiles',
  'default',
  'libgd-config.json'
);
const expectedRevision = '9ef4a53e6a9b351618a1e60a99f7d7f4baf36361';
const expectedLibGdFiles = Object.freeze({
  'libGD.js': Object.freeze({
    sha256: '6ab78b6c8b23ab890bec0a7972a94c1d269fdbabb5864db8d67d132c3723c9b5',
    size: 2096916,
  }),
  'libGD.wasm': Object.freeze({
    sha256: '041c6da0859f96047d5a2209f15d36ee1b62fc19a2cf132df9b24768d9c7e46d',
    size: 3391975,
  }),
});

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const readJson = async filePath => JSON.parse(await readFile(filePath, 'utf8'));
const optionValue = option => {
  const index = process.argv.indexOf(option);
  if (index < 0) return null;
  const value = process.argv[index + 1];
  if (!value || value.startsWith('--')) throw new Error(`${option} requires a directory`);
  return value;
};

const [webIdeLock, libGdConfig] = await Promise.all([
  readJson(lockPath),
  readJson(libGdConfigPath),
]);
assert.equal(webIdeLock.upstream.tag, 'v5.6.276');
assert.equal(webIdeLock.upstream.commit, expectedRevision);
assert.equal(libGdConfig.revision, expectedRevision);

const libGdDirectory = path.resolve(optionValue('--libgd') || libGdConfig.cachePath);
for (const [fileName, expected] of Object.entries(expectedLibGdFiles)) {
  assert.deepEqual(libGdConfig.files[fileName], expected);
  const filePath = path.join(libGdDirectory, fileName);
  const [metadata, bytes] = await Promise.all([stat(filePath), readFile(filePath)]);
  assert.equal(metadata.isFile(), true, `${fileName} must be a regular file`);
  assert.equal(bytes.byteLength, expected.size, `${fileName} size mismatch`);
  assert.equal(sha256(bytes), expected.sha256, `${fileName} SHA-256 mismatch`);
}

const require = createRequire(import.meta.url);
const initializeGDevelopJs = require(path.join(libGdDirectory, 'libGD.js'));
const gd = await initializeGDevelopJs({
  locateFile: fileName => path.join(libGdDirectory, fileName),
});

const probeExtension = {
  author: '',
  authorIds: [],
  category: 'Test',
  dependencies: [],
  description: '',
  extensionNamespace: '',
  fullName: 'Optional parameter probe',
  gdevelopVersion: '>=5.6.276',
  helpPath: '',
  iconUrl: '',
  name: 'OptionalProbe',
  previewIconUrl: '',
  shortDescription: '',
  version: '1.0.0',
  tags: [],
  globalVariables: [],
  sceneVariables: [],
  eventsFunctions: [
    {
      description: '',
      fullName: 'Probe optional parameters',
      functionType: 'Action',
      group: 'Probe',
      name: 'Probe',
      sentence: '',
      events: [],
      objectGroups: [],
      parameters: [
        { name: 'NumberWithoutDefault', type: 'expression', optional: true },
        { name: 'StringWithoutDefault', type: 'string', optional: true },
        { name: 'YesNoWithoutDefault', type: 'yesorno', optional: true },
        {
          name: 'NumberWithDefault',
          type: 'expression',
          optional: true,
          defaultValue: '17',
        },
        {
          name: 'StringWithDefault',
          type: 'string',
          optional: true,
          defaultValue: '"fallback"',
        },
        {
          name: 'YesNoWithDefault',
          type: 'yesorno',
          optional: true,
          defaultValue: 'yes',
        },
      ],
    },
  ],
  eventsBasedBehaviors: [],
  eventsBasedObjects: [],
};

const project = new gd.Project();
project.addPlatform(gd.JsPlatform.get());
const serializedExtensions = gd.Serializer.fromJSObject([probeExtension]);
project.unserializeAndInsertExtensionsFrom(serializedExtensions);
const eventsFunctionsExtension = project.getEventsFunctionsExtension('OptionalProbe');
const eventsFunction = eventsFunctionsExtension
  .getEventsFunctions()
  .getEventsFunction('Probe');

const platformExtension = new gd.PlatformExtension();
gd.MetadataDeclarationHelper.declareExtension(
  platformExtension,
  eventsFunctionsExtension
);
const metadataDeclarationHelper = new gd.MetadataDeclarationHelper();
metadataDeclarationHelper.generateFreeFunctionMetadata(
  project,
  platformExtension,
  eventsFunctionsExtension,
  eventsFunction
);
gd.JsPlatform.get().addNewExtension(platformExtension);

const layout = project.insertNewLayout('Scene', 0);
const event = layout
  .getEvents()
  .insertNewEvent(project, 'BuiltinCommonInstructions::Standard', 0);
const action = new gd.Instruction();
action.setType('OptionalProbe::Probe');
action.setParametersCount(0);
gd.asStandardEvent(event).getActions().insert(action, 0);

const layoutCodeGenerator = new gd.LayoutCodeGenerator(project);
const diagnosticReport = new gd.DiagnosticReport();
const code = layoutCodeGenerator.generateLayoutCompleteCode(
  layout,
  new gd.SetString(),
  diagnosticReport,
  true
);

assert.match(
  code,
  /gdjs\.evtsExt__OptionalProbe__Probe\.func\(runtimeScene, 0, "", false, 17, "fallback", true, null\);/,
  'omitted optional parameters must compile to primitive/default values, never undefined'
);

const actualParameters = eventsFunction.getParameters();
assert.equal(actualParameters.getParametersCount(), 6);
for (let index = 0; index < actualParameters.getParametersCount(); index += 1) {
  assert.equal(actualParameters.getParameterAt(index).isOptional(), true);
}
assert.deepEqual(
  Array.from({ length: 6 }, (_, index) =>
    actualParameters.getParameterAt(index).getDefaultValue()
  ),
  ['', '', '', '17', '"fallback"', 'yes'],
  'libGD must preserve the optional/defaultValue metadata used by code generation'
);

process.stdout.write(
  'GDevelop 5.6.276 optional parameter code generation uses primitive/default ' +
    'values rather than preserving omitted/undefined.\n'
);

diagnosticReport.delete();
layoutCodeGenerator.delete();
action.delete();
metadataDeclarationHelper.delete();
platformExtension.delete();
serializedExtensions.delete();
project.delete();
