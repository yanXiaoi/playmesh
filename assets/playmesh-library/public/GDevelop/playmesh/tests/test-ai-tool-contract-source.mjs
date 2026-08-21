import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const contractPath = path.join(
  playmeshDirectory,
  'runtime',
  'ai',
  'tools.json'
);

const exactOfficialToolNames = [
  'inspect_project_properties_resources',
  'change_project_properties_resources',
  'inspect_object_properties_effects',
  'change_object_properties_effects',
  'add_behavior',
  'inspect_behavior_properties',
  'change_behavior_property',
  'describe_instances',
  'put_2d_instances',
  'put_3d_instances',
  'read_scene_events',
  'read_events_source',
  'create_scene',
  'inspect_scene_properties_layers_effects',
  'change_scene_properties_layers_effects_groups',
  'add_or_edit_variable',
  'inspect_variables',
];

const removedFacadeNames = [
  'list_project_resources',
  'change_project_resources',
  'inspect_object_properties',
  'change_object_property',
  'delete_object',
  'remove_behavior',
  'delete_scene',
];

const helperIdentifiersByOfficialTool = {
  change_object_properties_effects: [
    'applyObjectPropertyChange',
    'applyEffectChange',
  ],
  change_scene_properties_layers_effects_groups: ['applyEffectChange'],
  add_or_edit_variable: ['extractVariableOperations'],
};

// These fingerprints freeze the exact, manually reviewed Playmesh schemas and
// the official v5.6.276 implementation blocks they were reviewed against.
// The public GDevelop source archive does not contain the generation-api input
// schemas, so a changed schema or official implementation must be reviewed and
// deliberately re-frozen instead of being accepted by a field-name-only check.
const expectedOfficialSchemaSha256 = {
  inspect_project_properties_resources:
    '4157826f326508d39f8558645af6bf6d7dcf6102a975473010068eb975cd78d8',
  change_project_properties_resources:
    'c5e5153292c0d90d13c3f4669ebe8fc87ff7663cddd586cb7b97f00f9dfa0b14',
  inspect_object_properties_effects:
    '96bfcea81b5c3bad77b1215ffb69dff57da036d8836da3af597dcd50a2cffafe',
  change_object_properties_effects:
    'e2bd5f977e652243aa603cff94e1ac7f617988b4620df79d9dcf20b8fecfddd4',
  add_behavior:
    '327169811aa32f6843807a81ae155f6178b907bb46abb08d12f7e4e40cbc6edc',
  inspect_behavior_properties:
    '8bb3b1ee42b8bc8fb6c111bec1a32d2ba5b403ac8600d1b30a632bac12dfa64e',
  change_behavior_property:
    'efd95dbfb36d258de80c1c5fc3700652876524db7906c7fd6e8ee3d2c99e949e',
  describe_instances:
    'a8bfddc90e663c4c5b0812066b4a658545ccc6bed6c2611df1cbe6a19332cce0',
  put_2d_instances:
    '1ef17b459102871e9bad152bbeb7815f138a12316979d6adf107f00989280ebb',
  put_3d_instances:
    'd66060b75d0db2d4e5a02e391a4ac4e50f2e3ceddf3c0699bb544586dabff212',
  read_scene_events:
    'dae22de414e1991ff54b1b803a5c2245043b4c633d9d2165578d62f1e2b6b524',
  read_events_source:
    '31b2c484dd2d710deb555f134c501d9ce65b2a67564748401a4d8c874da48217',
  create_scene:
    '1a26fc3f9c9a4e6e268e0a2df31e18b7126f8edb3dad9f59b134d86df6b81afd',
  inspect_scene_properties_layers_effects:
    'dae22de414e1991ff54b1b803a5c2245043b4c633d9d2165578d62f1e2b6b524',
  change_scene_properties_layers_effects_groups:
    '56c6d83f1e2014ad86e7f9f48f404ac8cb025ce3a619faf636d1c212c40ce5b4',
  add_or_edit_variable:
    'ba40002fd8a4ca9dc4f6202cea87ec5bfbd6a21603cc06f0f663ae31c8de8d60',
  inspect_variables:
    'd880b21122b0c4e380951cf8143039253c6af6fb7e257d7cb089de997afa2cc8',
};

// These independent facet fingerprints make the schema boundary auditable by
// semantic category. `propertyPaths` freezes every property at its exact
// nested object/array path (and therefore rejects extra properties), while the
// other facets freeze type/items, required lists, and enums. The complete
// schema fingerprint above remains the catch-all for keywords such as minimum
// and description. This is a Playmesh snapshot reviewed against the pinned
// source implementation; the official source archive does not publish these
// JSON Schemas.
const expectedOfficialSchemaFacetSha256 = {
  inspect_project_properties_resources: {
    propertyPaths:
      '746e213ace8834bfe58005ae83e4b3d025446305080deb59062bb83eeed6ed3f',
    typesAndItems:
      '4fe89c3f0522a571e8c3421f2ffe430cd0477475266508d67c913481756ffa4c',
    required:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  change_project_properties_resources: {
    propertyPaths:
      '9537b14c516b7de34183dd9175954e90e01cf06c05a516ef39c4a7f5b1d72aaa',
    typesAndItems:
      'd56db7ab609075552c06684f48507b42d6f69103da801b21a61aced794926b6c',
    required:
      '39d5fa185df153d7d0fe5e9416f568506c6992bd2aebc3dd690b55a37014547e',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  inspect_object_properties_effects: {
    propertyPaths:
      'd8cf97a9d38614a0a2ba7d55264894d9d82af75b893e2194fe7e14cb6f9be39a',
    typesAndItems:
      '0ab4cbc567fbec2711bdb92f1de81bcd5947901c36901b363fa2b3185739e4b3',
    required:
      'd8cf97a9d38614a0a2ba7d55264894d9d82af75b893e2194fe7e14cb6f9be39a',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  change_object_properties_effects: {
    propertyPaths:
      '15ccbe0360b2b14d7352df6cb49a2f678d3e0db40d50905daf9fb1713dedf510',
    typesAndItems:
      '7bbe2d9c7fcec13fb19245b137e607b0f7019ca0cf0c85cc6567fbe0a564ab40',
    required:
      'ef477fb77a5deb26ef3c0b5bc22c9a1b11a2ca69511928f3860cb2e5c4d01947',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  add_behavior: {
    propertyPaths:
      'aa943e0c17fb3f0af75b359a013548434f348ae632afcb8674191e38a9e77bd1',
    typesAndItems:
      '217bf6131a6e344a2b3752e26e04ce14773a598d5a4657a61f182be9f886b903',
    required:
      'a70be4e718f0d358482f065c92cb208b53381cd63f092e0862a631c222839f64',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  inspect_behavior_properties: {
    propertyPaths:
      'efec426dac4d02b32dc1bad866a0914bd160f709c23db05b35a135cfa1717cd3',
    typesAndItems:
      '6275e3687d0a7e247e2b2d157bc9c92db56c0234cb2d567ec3e2e3d0ce06dae9',
    required:
      'efec426dac4d02b32dc1bad866a0914bd160f709c23db05b35a135cfa1717cd3',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  change_behavior_property: {
    propertyPaths:
      '957e2884cb2a982089feda6ca6d39ef190f8ea1eb748f3e7250595d94ad6c6aa',
    typesAndItems:
      'bec5e81ea737ed54e0d66d2ffcd5224e635d2af525946a98aa6e68677ca30975',
    required:
      'bd17adddc7da09f268aa5fbdbb19964d99409e97549b02bf7d60c9953d4b7228',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  describe_instances: {
    propertyPaths:
      'bacd21fab60d3ae4e035ba967dde5c7c9c1f6ec187a1cea9e93c5292003f8235',
    typesAndItems:
      '06d9928701acfed8a5ed3bc558a556fc04a8d6cbea897d63f8754407d73ec178',
    required:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  put_2d_instances: {
    propertyPaths:
      '52d215ca5316d2da5d00d2296ad989791ae4a2877e19d8226c6dadd85d1531dc',
    typesAndItems:
      '9fd0fe951078ca985e7cfa9eb17d48165ce48f105c527e0511997dce3ba60226',
    required:
      '996d1b8fd20a2d4f34335b98bff5c1aef6e176dbea7a63ced71fa5986283b688',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  put_3d_instances: {
    propertyPaths:
      'c6ef6b584d6ae2396937ac1b472756a2a431b10d99833b506aaa9eed406db0d7',
    typesAndItems:
      'b6d3b575e7b0614bf746cc9897d9bf894bd325e440fe4d5fc700f6dd999e16a9',
    required:
      '996d1b8fd20a2d4f34335b98bff5c1aef6e176dbea7a63ced71fa5986283b688',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  read_scene_events: {
    propertyPaths:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    typesAndItems:
      '8ea704e58b2774db211b1456d045aaf6e7d80924d425984ca14b285ee0ddc15f',
    required:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  read_events_source: {
    propertyPaths:
      'efd85382e07b29b2b5a061713cbf2455c5ad21dc3f881c78974032bb937c544c',
    typesAndItems:
      'e395bf199d7672886bfc2515802163559b2d66fa81c702257ad4714247bc89f6',
    required:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  create_scene: {
    propertyPaths:
      '38d718f9e509805e5f24fd0ca0b44a8a4247bec84a24aee596a444b8595f1df0',
    typesAndItems:
      '5d75d3cf60cbe55d1af9fdc6e4316401c6db73955d7229723d6a3a1d6cd1fc47',
    required:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  inspect_scene_properties_layers_effects: {
    propertyPaths:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    typesAndItems:
      '8ea704e58b2774db211b1456d045aaf6e7d80924d425984ca14b285ee0ddc15f',
    required:
      'b714c177396dc3a900d397c0345482995eb82c397c3ffd1345eb4a9e2a5477f9',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  change_scene_properties_layers_effects_groups: {
    propertyPaths:
      'ae64fbc49368621e62c4dccf54d2380630dc2f2b627eb2400c66a6a79f1a33d5',
    typesAndItems:
      '85d69b527deb62a8a4d469bc18b92e8c8ac8fd0c621e75c68a77e44a2a1430c2',
    required:
      '0ce35c543556bc18583aa3813ae615ee0e4abdc843ceeec530bc3a03c0228d29',
    enums:
      '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  },
  add_or_edit_variable: {
    propertyPaths:
      '2cd1d6d0b5706564d545c8dcc49a46a5b1dd0b86960752163dbd3cf2dc238d52',
    typesAndItems:
      '96c957edd0e5ac2180a28db50809816676b982efac86ef2f2789999dfd5bbee3',
    required:
      '0cb5d1be5560284fdd34f9fe1df2c112f92a98ce0f35fd25a28e30a840a2a1ab',
    enums:
      '8a8bedd51d8dbd7d45231606f39c067893603ec431bef408d8d549367d85d33d',
  },
  inspect_variables: {
    propertyPaths:
      'c51a4c8b116edab2897d5bd748847a02465695a1c6a38804fbbf8f3ccf4ffa17',
    typesAndItems:
      'c9d5347de363bdf838e0590f9ec12ac12e5dcabd043d3e5eed3ddf6d8837dcbd',
    required:
      'ff6cf470bfac347a2521d7d8df2235737e4522ff77ae522399333933ef9df49c',
    enums:
      '5b170bc1f035aa8b79ef08f8716827a6b310cc7d338dcd9b305d559746386272',
  },
};

const expectedOfficialImplementationSha256 = {
  inspectProjectPropertiesResources:
    '8ea9e65ee09fa172e9c66641bda76daa3b7b861ef57f0265a21fa65d7b7b8ae2',
  changeProjectPropertiesResources:
    'ba4d6de135b917b582be8f5b51a7c73cf9ba772be0c1c5cb1d63b54a8daa377a',
  inspectObjectPropertiesEffects:
    '2ac438629b3b314af3b407d511de10e1746de2151a9cd9208a483c9cfbfc3651',
  changeObjectPropertiesEffects:
    '4602024b2da837f399c4ed03e053e403c92a2bc3dabaca0563e1cca033ad5a5f',
  addBehavior:
    '77b82d7eeb3d497cd85fd81dae6dcfb456d80804c656d2d17c721dfa2fa8502b',
  inspectBehaviorProperties:
    '1a736560a4efeb8c4e7eb5c76858f3718d0b6ed0282216d152aa2f969a807911',
  changeBehaviorProperty:
    'd3478022d95d94c2dfb27014f31bc3be717bfc04cf4913af33b14b5cd1a59d82',
  describeInstances:
    '752c9cffb2ef41d48e4b633b8a55fe617ec1c3efa4fc0d75c53c6ff2a6d47786',
  put2dInstances:
    '561b2e9b834b45dd3548b00b23f069290604d9bc791f5aafba4b7f0a56f5fe0e',
  put3dInstances:
    '988cc3247d05666764ddd1babb798edce51fb61c71fdb0442524a659f6de14a7',
  readSceneEvents:
    'e75a32ead3b0395511e6395a45ecc98c8b22cb4c410e24c45ac4ca887210efd8',
  readEventsSource:
    '2cc55acadf0fbbe20932cafb5e78e901b124bb68c80a0220d619b7008768a617',
  createScene:
    '832b7cc1ec6968938a508483178fd6faa92bee92284e76ecb88afb7540bca263',
  inspectScenePropertiesLayersEffects:
    '65fcde656d274ed7f639eb6cd1f9aba5976ff2302d999ffa04e9c2f0adc2f789',
  changeScenePropertiesLayersEffectsGroups:
    '61af22b6e3958845b26b61ba1eb9ca09495383982cdb188457062a9bfcf9684d',
  addOrEditVariable:
    '3ddbaf1999c176c4cf43a21279a88d68cbb1a688e5cf6f694a9795eb204e467e',
  inspectVariables:
    'e7407578a6bd64cef48d9c2d31f98bb38d763e8c044eec95b27c1cf179b3b811',
};

const expectedOfficialHelperSha256 = {
  applyObjectPropertyChange:
    '7f3f845e52a4cd92120407a7ec5597b6092347321dfd2cd27408a4b71ca1bff0',
  applyEffectChange:
    'efb5195e7f1f6ab95bea9349ea386e5bdebc728c1a939f8fe403a324d004fd97',
  extractVariableOperations:
    'bf4eec717ef15a645b175d1e692ece3dec16c68f82a3ea66f9958e5cc9906572',
};

const canonicalizeJson = value => {
  if (Array.isArray(value)) return value.map(canonicalizeJson);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map(key => [key, canonicalizeJson(value[key])])
  );
};

const sha256Text = value =>
  createHash('sha256')
    .update(value.replace(/\r\n/g, '\n').trimEnd(), 'utf8')
    .digest('hex');

const sha256Json = value =>
  sha256Text(JSON.stringify(canonicalizeJson(value)));

const collectSchemaFacets = schema => {
  const facets = {
    propertyPaths: [],
    typesAndItems: [],
    required: [],
    enums: [],
  };
  const propertyOccurrences = new Map();
  const visit = (node, schemaPath) => {
    if (!node || typeof node !== 'object' || Array.isArray(node)) return;
    if (Object.prototype.hasOwnProperty.call(node, 'type')) {
      facets.typesAndItems.push([schemaPath, 'type', node.type]);
    }
    if (Object.prototype.hasOwnProperty.call(node, 'items')) {
      facets.typesAndItems.push([schemaPath, 'items']);
      visit(node.items, `${schemaPath}[]`);
    }
    if (Object.prototype.hasOwnProperty.call(node, 'required')) {
      facets.required.push([schemaPath, [...node.required].sort()]);
    }
    if (Object.prototype.hasOwnProperty.call(node, 'enum')) {
      facets.enums.push([schemaPath, [...node.enum].sort()]);
    }
    if (
      node.properties &&
      typeof node.properties === 'object' &&
      !Array.isArray(node.properties)
    ) {
      const names = Object.keys(node.properties).sort();
      facets.propertyPaths.push([schemaPath, names]);
      for (const name of names) {
        const propertyPath = `${schemaPath}.${name}`;
        const occurrences = propertyOccurrences.get(name) || [];
        occurrences.push(propertyPath);
        propertyOccurrences.set(name, occurrences);
        visit(node.properties[name], propertyPath);
      }
    }
    for (const keyword of ['allOf', 'anyOf', 'oneOf']) {
      if (Array.isArray(node[keyword])) {
        node[keyword].forEach((child, index) =>
          visit(child, `${schemaPath}.${keyword}[${index}]`)
        );
      }
    }
  };
  visit(schema, '$');
  return { facets, propertyOccurrences };
};

const extractTopLevelConstBlock = (source, identifier) => {
  const startPattern = new RegExp(`^const ${identifier}(?=[: =(])`, 'm');
  const startMatch = startPattern.exec(source);
  if (!startMatch) return null;
  const nextMatch = /^const [A-Za-z_$][A-Za-z0-9_$]*(?=[: =(])/m.exec(
    source.slice(startMatch.index + startMatch[0].length)
  );
  const end = nextMatch
    ? startMatch.index + startMatch[0].length + nextMatch.index
    : source.length;
  return source.slice(startMatch.index, end);
};

const collectSafeExtractorFields = source => {
  const fields = new Set();
  const extractorPattern = /(?:extractRequiredString|SafeExtractor\.extract[A-Za-z]+Property)\([\s\S]{0,180}?,\s*['"]([^'"]+)['"]\s*\)/g;
  for (const match of source.matchAll(extractorPattern)) fields.add(match[1]);
  return fields;
};

const collectOfficialExportMap = editorFunctionsSource => {
  const start = editorFunctionsSource.indexOf(
    'export const editorFunctions: { [string]: EditorFunction } = {'
  );
  const end = editorFunctionsSource.indexOf(
    'export const editorFunctionsWithoutProject:',
    start
  );
  assert.ok(start >= 0 && end > start, 'official editorFunctions registry missing');
  const registrySource = editorFunctionsSource.slice(start, end);
  const exportMap = new Map();
  for (const match of registrySource.matchAll(
    /^\s*([a-z0-9_]+):\s*([A-Za-z_$][A-Za-z0-9_$]*),/gm
  )) {
    exportMap.set(match[1], match[2]);
  }
  return exportMap;
};

const collectContractErrors = ({
  contract,
  editorFunctionsSource,
  utilsSource,
}) => {
  const errors = [];
  const tools = Array.isArray(contract.tools) ? contract.tools : [];
  const byName = new Map(tools.map(tool => [tool.name, tool]));
  const officialTools = tools.filter(
    tool => tool.implementation === 'official_editor_function'
  );
  const versionMatch = utilsSource.match(
    /export const AI_ORCHESTRATOR_TOOLS_VERSION = ['"]([^'"]+)['"];/
  );
  if (!versionMatch) {
    errors.push('official AI_ORCHESTRATOR_TOOLS_VERSION constant is missing');
  } else if (versionMatch[1] !== contract.officialToolsVersion) {
    errors.push(
      `official tools version drift: source=${versionMatch[1]} contract=${contract.officialToolsVersion}`
    );
  }
  if (contract.toolsVersion !== '4.0.0') {
    errors.push(`Playmesh toolsVersion must be 4.0.0, got ${contract.toolsVersion}`);
  }
  if (
    !contract.officialToolsContract ||
    contract.officialToolsContract.kind !==
      'playmesh_source_aligned_snapshot' ||
    contract.officialToolsContract.schemaPublishedByOfficialSourceArchive !==
      false ||
    contract.officialToolsContract.argumentForwarding !== 'direct'
  ) {
    errors.push('official source snapshot semantics are not declared');
  }
  if (
    !contract.implementationKinds ||
    typeof contract.implementationKinds.playmesh_wrapper !== 'string' ||
    !contract.implementationKinds.playmesh_wrapper.includes('facade')
  ) {
    errors.push('Playmesh facade semantics are not declared');
  }
  if (contract.toolCount !== tools.length) {
    errors.push(`toolCount ${contract.toolCount} does not match ${tools.length}`);
  }
  for (const name of removedFacadeNames) {
    if (byName.has(name)) errors.push(`removed facade is still exposed: ${name}`);
  }
  if (
    officialTools.map(tool => tool.name).join('\n') !==
    exactOfficialToolNames.join('\n')
  ) {
    errors.push('official direct tool set or order does not match pinned v12');
  }
  for (const tool of tools) {
    if (Object.prototype.hasOwnProperty.call(tool, 'officialArguments')) {
      errors.push(`${tool.name} still declares hidden officialArguments`);
    }
    if (
      tool.implementation !== 'official_editor_function' &&
      tool.implementation !== 'playmesh_wrapper'
    ) {
      errors.push(`${tool.name} has an undeclared implementation kind`);
    }
  }
  for (const dangerousToolName of [
    'change_project_properties_resources',
    'change_object_properties_effects',
    'change_behavior_property',
    'change_scene_properties_layers_effects_groups',
    'add_or_edit_variable',
  ]) {
    const tool = byName.get(dangerousToolName);
    if (!tool || tool.risk !== 'high' || tool.approvalRequired !== true) {
      errors.push(`${dangerousToolName} must gate its complete delete-capable interface`);
    }
  }
  const changedResourceItems =
    byName.get('change_project_properties_resources')?.argumentsSchema
      ?.properties?.changed_resources?.items;
  if (
    !Array.isArray(changedResourceItems?.required) ||
    !changedResourceItems.required.includes('resource_name')
  ) {
    errors.push(
      'change_project_properties_resources requires changed_resources[].resource_name'
    );
  }

  const exportMap = collectOfficialExportMap(editorFunctionsSource);
  for (const tool of officialTools) {
    const expectedSchemaHash = expectedOfficialSchemaSha256[tool.name];
    const actualSchemaHash = sha256Json(tool.argumentsSchema);
    if (!expectedSchemaHash || actualSchemaHash !== expectedSchemaHash) {
      errors.push(
        `${tool.name} reviewed schema drift: expected=${
          expectedSchemaHash || 'missing'
        } actual=${actualSchemaHash}`
      );
    }
    const expectedSchemaFacets =
      expectedOfficialSchemaFacetSha256[tool.name];
    const { facets: actualSchemaFacets, propertyOccurrences } =
      collectSchemaFacets(tool.argumentsSchema);
    for (const [facetName, actualFacet] of Object.entries(
      actualSchemaFacets
    )) {
      const expectedFacetHash = expectedSchemaFacets?.[facetName];
      const actualFacetHash = sha256Json(actualFacet);
      if (!expectedFacetHash || actualFacetHash !== expectedFacetHash) {
        errors.push(
          `${tool.name} reviewed schema ${facetName} drift: expected=${
            expectedFacetHash || 'missing'
          } actual=${actualFacetHash}`
        );
      }
    }
    if (tool.officialImplementationName !== tool.name) {
      errors.push(
        `${tool.name} is not direct: official name is ${tool.officialImplementationName}`
      );
      continue;
    }
    const implementationIdentifier = exportMap.get(tool.name);
    if (!implementationIdentifier) {
      errors.push(`${tool.name} is missing from official editorFunctions`);
      continue;
    }
    const implementationBlock = extractTopLevelConstBlock(
      editorFunctionsSource,
      implementationIdentifier
    );
    if (!implementationBlock) {
      errors.push(
        `${tool.name} official implementation ${implementationIdentifier} is missing`
      );
      continue;
    }
    const expectedImplementationHash =
      expectedOfficialImplementationSha256[implementationIdentifier];
    const actualImplementationHash = sha256Text(implementationBlock);
    if (
      !expectedImplementationHash ||
      actualImplementationHash !== expectedImplementationHash
    ) {
      errors.push(
        `${tool.name} official implementation drift: expected=${
          expectedImplementationHash || 'missing'
        } actual=${actualImplementationHash}`
      );
    }
    const modifiesMatch = implementationBlock.match(
      /\n  modifiesProject: (true|false),\s*\n};/
    );
    if (!modifiesMatch) {
      errors.push(`${tool.name} official modifiesProject marker is missing`);
    } else if ((modifiesMatch[1] === 'true') !== tool.modifiesProject) {
      errors.push(
        `${tool.name} modifiesProject drift: source=${modifiesMatch[1]} contract=${tool.modifiesProject}`
      );
    }

    const consumedFields = collectSafeExtractorFields(implementationBlock);
    for (const helperIdentifier of
      helperIdentifiersByOfficialTool[tool.name] || []) {
      const helperBlock = extractTopLevelConstBlock(
        editorFunctionsSource,
        helperIdentifier
      );
      if (!helperBlock) {
        errors.push(`${tool.name} source helper ${helperIdentifier} is missing`);
        continue;
      }
      const expectedHelperHash =
        expectedOfficialHelperSha256[helperIdentifier];
      const actualHelperHash = sha256Text(helperBlock);
      if (!expectedHelperHash || actualHelperHash !== expectedHelperHash) {
        errors.push(
          `${tool.name} official helper ${helperIdentifier} drift: expected=${
            expectedHelperHash || 'missing'
          } actual=${actualHelperHash}`
        );
      }
      for (const field of collectSafeExtractorFields(helperBlock)) {
        consumedFields.add(field);
      }
    }
    const missingFields = [...consumedFields].filter(
      field => !propertyOccurrences.has(field)
    );
    if (missingFields.length > 0) {
      errors.push(
        `${tool.name} omits official consumed fields: ${missingFields.sort().join(', ')}`
      );
    }
  }
  return errors;
};

const clone = value => JSON.parse(JSON.stringify(value));
const contract = JSON.parse(await readFile(contractPath, 'utf8'));
const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex === -1) {
  assert.equal(contract.toolsVersion, '4.0.0');
  assert.equal(contract.officialToolsVersion, 'v12');
  assert.equal(contract.toolCount, 50);
  assert.equal(contract.tools.length, 50);
  assert.deepEqual(
    contract.tools
      .filter(tool => tool.implementation === 'official_editor_function')
      .map(tool => tool.name),
    exactOfficialToolNames
  );
  assert.deepEqual(
    removedFacadeNames.filter(name => contract.tools.some(tool => tool.name === name)),
    []
  );
  assert.equal(contract.tools.some(tool => 'officialArguments' in tool), false);
  for (const tool of contract.tools.filter(
    candidate => candidate.implementation === 'official_editor_function'
  )) {
    assert.equal(
      sha256Json(tool.argumentsSchema),
      expectedOfficialSchemaSha256[tool.name],
      `${tool.name} reviewed schema fingerprint drifted`
    );
    const { facets } = collectSchemaFacets(tool.argumentsSchema);
    for (const [facetName, facet] of Object.entries(facets)) {
      assert.equal(
        sha256Json(facet),
        expectedOfficialSchemaFacetSha256[tool.name]?.[facetName],
        `${tool.name} reviewed schema ${facetName} fingerprint drifted`
      );
    }
  }
  const inspectSceneTool = contract.tools.find(
    tool => tool.name === 'inspect_scene_properties_layers_effects'
  );
  const changeSceneTool = contract.tools.find(
    tool => tool.name === 'change_scene_properties_layers_effects_groups'
  );
  assert.match(inspectSceneTool.summary, /list_project_objects/);
  assert.match(changeSceneTool.summary, /list_project_objects/);
  process.stdout.write(
    'GDevelop AI tool contract static v4 boundary passed; source verification runs during clean replay.\n'
  );
} else {
  const sourceArgument = process.argv[sourceArgumentIndex + 1];
  if (!sourceArgument) throw new Error('--source requires a GDevelop source root');
  const sourceRoot = path.resolve(sourceArgument);
  const editorFunctionsSource = await readFile(
    path.join(sourceRoot, 'newIDE', 'app', 'src', 'EditorFunctions', 'index.js'),
    'utf8'
  );
  const utilsSource = await readFile(
    path.join(sourceRoot, 'newIDE', 'app', 'src', 'AiGeneration', 'Utils.js'),
    'utf8'
  );
  const errors = collectContractErrors({
    contract,
    editorFunctionsSource,
    utilsSource,
  });
  assert.deepEqual(errors, [], errors.join('\n'));

  const oldGroupShape = clone(contract);
  const groupProperties = oldGroupShape.tools.find(
    tool => tool.name === 'change_scene_properties_layers_effects_groups'
  ).argumentsSchema.properties.changed_groups.items.properties;
  delete groupProperties.objects_to_add;
  delete groupProperties.objects_to_remove;
  groupProperties.objects = {
    type: 'array',
    items: {
      type: 'object',
      properties: { object_name: { type: 'string' } },
    },
  };
  assert.match(
    collectContractErrors({
      contract: oldGroupShape,
      editorFunctionsSource,
      utilsSource,
    }).join('\n'),
    /objects_to_add|objects_to_remove/
  );

  for (const [toolName, fieldName] of [
    ['put_2d_instances', 'instances_rotation'],
    ['put_2d_instances', 'instances_opacity'],
    ['create_scene', 'is_first_scene'],
    ['change_scene_properties_layers_effects_groups', 'new_visibility'],
  ]) {
    const drifted = clone(contract);
    const tool = drifted.tools.find(candidate => candidate.name === toolName);
    const removeField = schema => {
      if (!schema || typeof schema !== 'object') return false;
      if (schema.properties && fieldName in schema.properties) {
        delete schema.properties[fieldName];
        return true;
      }
      return (
        (schema.properties &&
          Object.values(schema.properties).some(removeField)) ||
        removeField(schema.items) ||
        ['allOf', 'anyOf', 'oneOf'].some(keyword =>
          Array.isArray(schema[keyword])
            ? schema[keyword].some(removeField)
            : false
        )
      );
    };
    assert.equal(removeField(tool.argumentsSchema), true);
    assert.match(
      collectContractErrors({
        contract: drifted,
        editorFunctionsSource,
        utilsSource,
      }).join('\n'),
      new RegExp(fieldName)
    );
  }

  const assertReviewedSchemaDrift = (mutate, expectedFacetName) => {
    const drifted = clone(contract);
    mutate(drifted);
    const errors = collectContractErrors({
      contract: drifted,
      editorFunctionsSource,
      utilsSource,
    }).join('\n');
    assert.match(
      errors,
      /reviewed schema drift/
    );
    assert.match(
      errors,
      new RegExp(`reviewed schema ${expectedFacetName} drift`)
    );
  };
  assertReviewedSchemaDrift(
    drifted => {
      const schema = drifted.tools.find(
        tool => tool.name === 'change_scene_properties_layers_effects_groups'
      ).argumentsSchema;
      const groupProperties =
        schema.properties.changed_groups.items.properties;
      schema.properties.objects_to_add = groupProperties.objects_to_add;
      delete groupProperties.objects_to_add;
    },
    'propertyPaths'
  );
  assertReviewedSchemaDrift(
    drifted => {
      drifted.tools.find(
        tool =>
          tool.name === 'change_scene_properties_layers_effects_groups'
      ).argumentsSchema.properties.changed_groups.items.properties.objects_to_remove.items.type =
        'number';
    },
    'typesAndItems'
  );
  assertReviewedSchemaDrift(
    drifted => {
      drifted.tools.find(
        tool => tool.name === 'change_scene_properties_layers_effects_groups'
      ).argumentsSchema.required = [];
    },
    'required'
  );
  assertReviewedSchemaDrift(
    drifted => {
      drifted.tools.find(
        tool => tool.name === 'add_or_edit_variable'
      ).argumentsSchema.properties.variable_scope.enum.push('not_official');
    },
    'enums'
  );
  assertReviewedSchemaDrift(
    drifted => {
      drifted.tools.find(
        tool => tool.name === 'inspect_project_properties_resources'
      ).argumentsSchema.properties.not_official = { type: 'string' };
    },
    'propertyPaths'
  );

  process.stdout.write(
    'GDevelop AI tool contract matches the Playmesh source-aligned schema snapshot and pinned official v12 implementation blocks.\n'
  );
}
