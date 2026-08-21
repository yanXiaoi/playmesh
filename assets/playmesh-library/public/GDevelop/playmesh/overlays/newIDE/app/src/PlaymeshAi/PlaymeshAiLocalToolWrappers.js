// @flow

import { swapAsset } from '../AssetStore/AssetSwapper';
import PixiResourcesLoader from '../ObjectsRendering/PixiResourcesLoader';
import { addSerializedExtensionsToProject } from '../AssetStore/ExtensionStore/InstallExtension';
import { createNewResource } from '../ResourcesList/ResourceSource';
import { applyResourceDefaults } from '../ResourcesList/ResourceUtils';
import { playmeshResourceObjectUrlRegistry } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshResourceObjectUrlRegistry';
import { serializeToJSObject } from '../Utils/Serializer';
import { enumerateAllInstructions } from '../InstructionOrExpression/EnumerateInstructions';
import { enumerateAllExpressions } from '../InstructionOrExpression/EnumerateExpressions';
import { enumerateEventsMetadata } from '../EventsSheet/EnumerateEventsMetadata';
import { formatExpressionCall } from '../EventsSheet/ParameterFields/GenericExpressionField/FormatExpressionCall';
import {
  getPlaymeshBehaviorsRegistry,
  getPlaymeshExtension,
  getPlaymeshExtensionsRegistry,
} from '../PlaymeshCatalog/PlaymeshCatalogSource';
import { playmeshAiRuntimeDebuggerTools } from './PlaymeshAiRuntimeDebuggerTools';
import { createPlaymeshAiPiskelToolWrappers } from './PlaymeshAiPiskelTool';
import { createPlaymeshAiJfxrYarnTools } from './PlaymeshAiJfxrYarnTools';
const gd /*: libGDevelop */ = global.gd;
/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiEventPayload,
  PlaymeshAiObject,
  PlaymeshAiStagedResource,
} from './PlaymeshAiProtocol';
import type {
  PlaymeshAiEditorFunctionExecution,
  PlaymeshAiEditorFunctionWrapperContext,
  PlaymeshAiEditorFunctionWrappers,
  PlaymeshAiRunnerOptions,
} from './PlaymeshAiEditorFunctionTypes';
import type {
  AssetSearchAndInstallResult,
  ResourceSearchAndInstallOptions,
  ResourceSearchAndInstallResult,
} from '../EditorFunctions';
import type {
  BehaviorShortHeader,
  ExtensionShortHeader,
} from '../Utils/GDevelopServices/Extension';

type PlaymeshAiCapabilitySearchEntry = {|
  summary: PlaymeshAiObject,
  searchText: string,
|};

type PlaymeshAiCapabilityFunctionSummaries = {|
  actions: Array<PlaymeshAiObject>,
  conditions: Array<PlaymeshAiObject>,
  expressions: Array<PlaymeshAiObject>,
|};

export type PlaymeshAiPlanItem = {|
  step: string,
  status: 'pending' | 'in_progress' | 'completed',
|};

export type PlaymeshAiPlan = {|
  explanation: string,
  plan: Array<PlaymeshAiPlanItem>,
|};

export type PlaymeshAiLocalToolExecution = PlaymeshAiEditorFunctionExecution;

export type PlaymeshAiLocalToolContext = PlaymeshAiEditorFunctionWrapperContext;

export type PlaymeshAiEventPayloadContext = {
  ...PlaymeshAiLocalToolContext,
  eventPayload: PlaymeshAiEventPayload,
};

export type PlaymeshAiLocalToolWrappersOptions = {|
  applyEventPayload?: PlaymeshAiLocalToolContext =>
    Promise<PlaymeshAiLocalToolExecution>,
  readFullDocs?: ({|
    project: gdProject,
    extensionNames: string,
  |}) => Promise<mixed>,
  updatePlan?: PlaymeshAiPlan => Promise<mixed>,
  stagedResource?: PlaymeshAiStagedResource,
  beforeProjectMutation?: () => void,
  onFetchNewlyAddedResources?: () => Promise<void>,
  onNewResourcesAdded?: () => void,
  toolsContract?: PlaymeshAiObject,
|};

export type PlaymeshAiLocalToolWrappers = PlaymeshAiEditorFunctionWrappers;

type PlaymeshAiFoundProjectObject = {|
  object: gdObject,
  scene: gdLayout,
|};
*/

export class PlaymeshAiLocalToolError extends Error {
  /*:: code: string; */
  /*:: correctable: boolean; */

  constructor(code /*: string */, correctable /*: boolean */ = false) {
    super('The local GDevelop AI tool could not be completed.');
    this.name = 'PlaymeshAiLocalToolError';
    this.code = code;
    this.correctable = correctable;
  }
}

const finished = ({
  call,
  success,
  output,
  createdProject = null,
  didModifyProject = false,
  transientObjectUrls = [],
} /*: {|
  call: PlaymeshAiCall,
  success: boolean,
  output: PlaymeshAiObject,
  createdProject?: ?gdProject,
  didModifyProject?: boolean,
  transientObjectUrls?: Array<string>,
|} */) /*: PlaymeshAiLocalToolExecution */ => ({
  result: {
    status: 'finished',
    call_id: call.callId,
    success,
    output,
    ...(success && didModifyProject ? { didModifyProject: true } : {}),
  },
  createdProject,
  createdSceneNames: [],
  transientObjectUrls,
});

const storeDisabledAssetSearch = async () /*: Promise<AssetSearchAndInstallResult> */ => ({
  status: 'nothing-found',
  message: 'The asset store is disabled.',
  createdObjects: [],
  assetShortHeader: null,
  isTheFirstOfItsTypeInProject: false,
});

const storeDisabledResourceSearch = async ({
  resources,
} /*: ResourceSearchAndInstallOptions */) /*: Promise<ResourceSearchAndInstallResult> */ => ({
  results: resources.map(resource => ({
    resourceName: resource.resourceName,
    resourceKind: resource.resourceKind,
    status: 'nothing-found',
  })),
});

const findProjectObject = ({
  project,
  sceneName,
  objectName,
} /*: {|
  project: gdProject,
  sceneName: string,
  objectName: string,
|} */) /*: ?PlaymeshAiFoundProjectObject */ => {
  if (!project.hasLayoutNamed(sceneName)) return null;
  const scene = project.getLayout(sceneName);
  const sceneObjects = scene.getObjects();
  if (sceneObjects.hasObjectNamed(objectName)) {
    return { object: sceneObjects.getObject(objectName), scene };
  }
  const globalObjects = project.getObjects();
  return globalObjects.hasObjectNamed(objectName)
    ? { object: globalObjects.getObject(objectName), scene }
    : null;
};

const summarizeProjectObject = ({
  object,
  scope,
} /*: {|
  object: gdObject,
  scope: 'scene' | 'global',
|} */) /*: PlaymeshAiObject */ => ({
  name: object.getName(),
  type: object.getType(),
  scope,
  behaviors: object
    .getAllBehaviorNames()
    .toJSArray()
    .map(behaviorName => {
      const behavior = object.getBehavior(behaviorName);
      return {
        name: behavior.getName(),
        type: behavior.getTypeName(),
      };
    }),
});

const summarizeProjectObjects = ({
  objectsContainer,
  scope,
} /*: {|
  objectsContainer: gdObjectsContainer,
  scope: 'scene' | 'global',
|} */) /*: Array<PlaymeshAiObject> */ => {
  const objects = [];
  for (let index = 0; index < objectsContainer.getObjectsCount(); index++) {
    objects.push(
      summarizeProjectObject({
        object: objectsContainer.getObjectAt(index),
        scope,
      })
    );
  }
  return objects;
};

const summarizeProjectObjectGroups = ({
  objectsContainer,
  scope,
} /*: {|
  objectsContainer: gdObjectsContainer,
  scope: 'scene' | 'global',
|} */) /*: Array<PlaymeshAiObject> */ => {
  const groups /*: Array<PlaymeshAiObject> */ = [];
  const objectGroups = objectsContainer.getObjectGroups();
  for (let index = 0; index < objectGroups.count(); index++) {
    const group = objectGroups.getAt(index);
    groups.push({
      name: group.getName(),
      scope,
      members: group.getAllObjectsNames().toJSArray(),
    });
  }
  return groups;
};

const prefabObjectType = (
  extension /*: gdEventsFunctionsExtension */,
  prefab /*: gdEventsBasedObject */
) /*: string */ => `${extension.getName()}::${prefab.getName()}`;

const summarizePrefabReference = ({
  extension,
  prefab,
} /*: {|
  extension: gdEventsFunctionsExtension,
  prefab: gdEventsBasedObject,
|} */) /*: PlaymeshAiObject */ => ({
  extensionName: extension.getName(),
  extensionFullName: extension.getFullName(),
  extensionVersion: extension.getVersion(),
  prefabName: prefab.getName(),
  objectType: prefabObjectType(extension, prefab),
  fullName: prefab.getFullName(),
  description: prefab.getDescription(),
  isPrivate: prefab.isPrivate(),
});

const summarizePrefabVariant = (
  variant /*: gdEventsBasedObjectVariant */
) /*: PlaymeshAiObject */ => ({
  name: variant.getName(),
  initialInstancesCount: variant.getInitialInstances().getInstancesCount(),
  childObjectsCount: variant.getObjects().getObjectsCount(),
  area: {
    minX: variant.getAreaMinX(),
    minY: variant.getAreaMinY(),
    minZ: variant.getAreaMinZ(),
    maxX: variant.getAreaMaxX(),
    maxY: variant.getAreaMaxY(),
    maxZ: variant.getAreaMaxZ(),
  },
});

const inspectPrefabDefinition = ({
  extension,
  prefab,
} /*: {|
  extension: gdEventsFunctionsExtension,
  prefab: gdEventsBasedObject,
|} */) /*: PlaymeshAiObject */ => {
  const properties = prefab.getPropertyDescriptors();
  const propertySummaries = [];
  for (let index = 0; index < properties.getCount(); index++) {
    const property = properties.getAt(index);
    propertySummaries.push({
      name: property.getName(),
      type: property.getType(),
      value: property.getValue(),
      label: property.getLabel(),
      description: property.getDescription(),
    });
  }

  const childObjects = prefab.getObjects();
  const childObjectSummaries = [];
  for (let index = 0; index < childObjects.getObjectsCount(); index++) {
    const childObject = childObjects.getObjectAt(index);
    childObjectSummaries.push({
      name: childObject.getName(),
      type: childObject.getType(),
    });
  }

  const layers = prefab.getLayers();
  const layerNames = [];
  for (let index = 0; index < layers.getLayersCount(); index++) {
    layerNames.push(layers.getLayerAt(index).getName());
  }

  const functions = prefab.getEventsFunctions();
  const eventFunctionNames = [];
  for (let index = 0; index < functions.getEventsFunctionsCount(); index++) {
    eventFunctionNames.push(functions.getEventsFunctionAt(index).getName());
  }

  const variants = prefab.getVariants();
  const variantSummaries = [];
  for (let index = 0; index < variants.getVariantsCount(); index++) {
    variantSummaries.push(summarizePrefabVariant(variants.getVariantAt(index)));
  }

  return {
    ...summarizePrefabReference({ extension, prefab }),
    defaultName: prefab.getDefaultName(),
    assetStoreTag: prefab.getAssetStoreTag(),
    renderedIn3D: prefab.isRenderedIn3D(),
    animatable: prefab.isAnimatable(),
    textContainer: prefab.isTextContainer(),
    innerAreaFollowsParentSize: prefab.isInnerAreaFollowingParentSize(),
    area: {
      minX: prefab.getAreaMinX(),
      minY: prefab.getAreaMinY(),
      minZ: prefab.getAreaMinZ(),
      maxX: prefab.getAreaMaxX(),
      maxY: prefab.getAreaMaxY(),
      maxZ: prefab.getAreaMaxZ(),
    },
    initialInstancesCount: prefab.getInitialInstances().getInstancesCount(),
    properties: propertySummaries,
    childObjects: childObjectSummaries,
    layers: layerNames,
    eventFunctions: eventFunctionNames,
    defaultVariant: summarizePrefabVariant(prefab.getDefaultVariant()),
    variants: variantSummaries,
  };
};

const replaceObjectFromLocalSource = ({
  call,
  project,
  runnerOptions,
} /*: {|
  call: PlaymeshAiCall,
  project: gdProject,
  runnerOptions: PlaymeshAiRunnerOptions,
|} */) /*: PlaymeshAiLocalToolExecution */ => {
  const argumentsMap = call.arguments;
  const sceneName = argumentsMap.scene_name;
  const targetName = argumentsMap.object_name;
  const sourceName = argumentsMap.duplicated_object_name;
  const sourceSceneName = argumentsMap.duplicated_object_scene || sceneName;
  if (
    typeof sceneName !== 'string' ||
    typeof targetName !== 'string' ||
    typeof sourceName !== 'string' ||
    typeof sourceSceneName !== 'string'
  ) {
    return finished({
      call,
      success: false,
      output: { message: 'The local object replacement arguments are invalid.' },
    });
  }
  const target = findProjectObject({
    project,
    sceneName,
    objectName: targetName,
  });
  const source = findProjectObject({
    project,
    sceneName: sourceSceneName,
    objectName: sourceName,
  });
  if (!target || !source) {
    return finished({
      call,
      success: false,
      output: {
        message: 'The target or local replacement source object was not found.',
      },
    });
  }
  if (target.object === source.object) {
    return finished({
      call,
      success: false,
      output: { message: 'The replacement source must differ from the target.' },
    });
  }
  if (target.object.getType() !== source.object.getType()) {
    return finished({
      call,
      success: false,
      output: {
        message: 'The local replacement source must have the same object type.',
      },
    });
  }
  if (!swapAsset(project, PixiResourcesLoader, target.object, source.object)) {
    return finished({
      call,
      success: false,
      output: { message: 'The local object replacement was rejected.' },
    });
  }
  runnerOptions.onObjectsModifiedOutsideEditor({
    scene: target.scene,
    isNewObjectTypeUsed: false,
  });
  return finished({
    call,
    success: true,
    output: { message: 'The object was replaced from a local project object.' },
    didModifyProject: true,
  });
};

const normalizePlanStatus = (
  status /*: mixed */
) /*: 'pending' | 'in_progress' | 'completed' */ => {
  switch (status) {
    case 'pending':
    case 'in_progress':
    case 'completed':
      return status;
    default:
      throw new PlaymeshAiLocalToolError('invalid_local_plan');
  }
};

const validateLocalPlan = (
  argumentsMap /*: PlaymeshAiObject */
) /*: PlaymeshAiPlan */ => {
  const rawPlan = argumentsMap.plan;
  if (!Array.isArray(rawPlan) || rawPlan.length < 1) {
    throw new PlaymeshAiLocalToolError('invalid_local_plan');
  }
  const plan /*: Array<PlaymeshAiPlanItem> */ = rawPlan.map(item => {
    const step = item && typeof item === 'object' ? item.step : null;
    if (
      !item ||
      typeof item !== 'object' ||
      Array.isArray(item) ||
      typeof step !== 'string' ||
      !step.trim()
    ) {
      throw new PlaymeshAiLocalToolError('invalid_local_plan');
    }
    return { step, status: normalizePlanStatus(item.status) };
  });
  return {
    explanation:
      typeof argumentsMap.explanation === 'string'
        ? argumentsMap.explanation
        : '',
    plan,
  };
};

const asObject = (value /*: mixed */) /*: ?PlaymeshAiObject */ =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: any */)
    : null;

const createCanonicalEmptyEventJson = ({
  project,
  eventType,
} /*: {|
  project: gdProject,
  eventType: string,
|} */) /*: PlaymeshAiObject */ => {
  const eventsList = new gd.EventsList();
  try {
    // This is the same factory seam used by the official event sheet. It lets
    // the locked GDevelop build choose the concrete event class and defaults.
    eventsList.insertNewEvent(project, eventType, 0);
    const serializedEvents = serializeToJSObject(eventsList, 'serializeTo', {
      canonicalEventSerialization: true,
    });
    if (
      !Array.isArray(serializedEvents) ||
      serializedEvents.length !== 1 ||
      !asObject(serializedEvents[0]) ||
      serializedEvents[0].type !== eventType
    ) {
      throw new PlaymeshAiLocalToolError('event_type_template_unavailable');
    }
    return serializedEvents[0];
  } finally {
    eventsList.delete();
  }
};

const normalizeEventInstructionKind = (
  value /*: mixed */,
  allowAll /*: boolean */
) /*: 'action' | 'condition' | 'expression' | 'all' */ => {
  if (
    value === 'action' ||
    value === 'condition' ||
    value === 'expression'
  ) {
    return value;
  }
  if (allowAll && value === 'all') return 'all';
  throw new PlaymeshAiLocalToolError('invalid_event_instruction_kind');
};

const summarizeInstructionScope = (
  scope /*: mixed */
) /*: PlaymeshAiObject */ => {
  const scopeObject = asObject(scope) || {};
  const extension = asObject(scopeObject.extension);
  const objectMetadata = asObject(scopeObject.objectMetadata);
  const behaviorMetadata = asObject(scopeObject.behaviorMetadata);
  return {
    extensionName:
      extension && typeof extension.name === 'string' ? extension.name : '',
    object:
      objectMetadata && typeof objectMetadata.name === 'string'
        ? {
            name: objectMetadata.name,
            isPrivate: objectMetadata.isPrivate === true,
          }
        : null,
    behavior:
      behaviorMetadata && typeof behaviorMetadata.name === 'string'
        ? {
            name: behaviorMetadata.name,
            isPrivate: behaviorMetadata.isPrivate === true,
          }
        : null,
  };
};

const summarizeValueTypeMetadata = (
  metadata /*: any */
) /*: PlaymeshAiObject */ => ({
  name: metadata.getName(),
  extraInfo: metadata.getExtraInfo(),
  optional: metadata.isOptional(),
  defaultValue: metadata.getDefaultValue(),
  object: metadata.isObject(),
  behavior: metadata.isBehavior(),
  number: metadata.isNumber(),
  string: metadata.isString(),
  variable: metadata.isVariable(),
  resource: metadata.isResource(),
});

const summarizeInstructionParameter = (
  metadata /*: gdParameterMetadata */,
  index /*: number */
) /*: PlaymeshAiObject */ => ({
  index,
  name: metadata.getName(),
  type: metadata.getType(),
  description: metadata.getDescription(),
  longDescription: metadata.getLongDescription(),
  hint: metadata.getHint(),
  extraInfo: metadata.getExtraInfo(),
  optional: metadata.isOptional(),
  codeOnly: metadata.isCodeOnly(),
  defaultValue: metadata.getDefaultValue(),
  valueType: summarizeValueTypeMetadata(metadata.getValueTypeMetadata()),
});

const summarizeEventInstruction = ({
  kind,
  instruction,
  includeParameters,
} /*: {|
  kind: 'action' | 'condition',
  instruction: any,
  includeParameters: boolean,
|} */) /*: PlaymeshAiObject */ => {
  const metadata = instruction.metadata;
  const summary /*: PlaymeshAiObject */ = {
    kind,
    canonicalType: instruction.type,
    fullName: metadata.getFullName(),
    description: metadata.getDescription(),
    group: metadata.getGroup(),
    scope: summarizeInstructionScope(instruction.scope),
    hidden: metadata.isHidden(),
    private: metadata.isPrivate(),
    relevantForSceneEvents: metadata.isRelevantForLayoutEvents(),
  };
  if (!includeParameters) return summary;

  const parameters = [];
  for (let index = 0; index < metadata.getParametersCount(); index++) {
    parameters.push(
      summarizeInstructionParameter(metadata.getParameter(index), index)
    );
  }
  return {
    ...summary,
    sentence: metadata.getSentence(),
    hint: metadata.getHint(),
    iconFilename: metadata.getIconFilename(),
    smallIconFilename: metadata.getSmallIconFilename(),
    helpPath: metadata.getHelpPath(),
    canHaveSubInstructions: metadata.canHaveSubInstructions(),
    usageComplexity: metadata.getUsageComplexity(),
    deprecationMessage: metadata.getDeprecationMessage(),
    async: metadata.isAsync(),
    optionallyAsync: metadata.isOptionallyAsync(),
    relevantForFunctionEvents: metadata.isRelevantForFunctionEvents(),
    relevantForAsynchronousFunctionEvents: metadata.isRelevantForAsynchronousFunctionEvents(),
    relevantForCustomObjectEvents: metadata.isRelevantForCustomObjectEvents(),
    parameters,
  };
};

const isExpressionParameterVisible = ({
  scope,
  metadata,
  index,
} /*: {|
  scope: mixed,
  metadata: gdParameterMetadata,
  index: number,
|} */) /*: boolean */ => {
  const scopeObject = asObject(scope) || {};
  if (asObject(scopeObject.objectMetadata) && index === 0) return false;
  if (asObject(scopeObject.behaviorMetadata) && index <= 1) return false;
  return !metadata.isCodeOnly();
};

const summarizeEventExpression = ({
  expression,
  includeParameters,
} /*: {|
  expression: any,
  includeParameters: boolean,
|} */) /*: PlaymeshAiObject */ => {
  const metadata = expression.metadata;
  const summary /*: PlaymeshAiObject */ = {
    kind: 'expression',
    canonicalType: expression.type,
    returnType: metadata.getReturnType(),
    fullName: metadata.getFullName(),
    description: metadata.getDescription(),
    group: metadata.getGroup(),
    scope: summarizeInstructionScope(expression.scope),
    shown: metadata.isShown(),
    private: metadata.isPrivate(),
    deprecated: metadata.isDeprecated(),
    relevantForSceneEvents: metadata.isRelevantForLayoutEvents(),
  };
  if (!includeParameters) return summary;

  const parameters = [];
  for (let index = 0; index < metadata.getParametersCount(); index++) {
    const parameterMetadata = metadata.getParameter(index);
    parameters.push({
      ...summarizeInstructionParameter(parameterMetadata, index),
      visibleInExpressionCall: isExpressionParameterVisible({
        scope: expression.scope,
        metadata: parameterMetadata,
        index,
      }),
    });
  }
  return {
    ...summary,
    smallIconFilename: metadata.getSmallIconFilename(),
    helpPath: metadata.getHelpPath(),
    deprecationMessage: metadata.getDeprecationMessage(),
    functionName: metadata.getFunctionName(),
    relevantForFunctionEvents: metadata.isRelevantForFunctionEvents(),
    relevantForAsynchronousFunctionEvents: metadata.isRelevantForAsynchronousFunctionEvents(),
    relevantForCustomObjectEvents: metadata.isRelevantForCustomObjectEvents(),
    parameters,
  };
};

const eventMetadataScopeKey = (scope /*: mixed */) /*: string */ => {
  const summary = summarizeInstructionScope(scope);
  const objectScope = asObject(summary.object);
  const behaviorScope = asObject(summary.behavior);
  return [
    summary.extensionName,
    objectScope && objectScope.name,
    behaviorScope && behaviorScope.name,
  ]
    .map(value => (typeof value === 'string' ? value : ''))
    .join('\u0000');
};

const parseEventExpressionScopeSelector = (
  value /*: mixed */
) /*: any */ => {
  if (value == null) return null;
  const selector = asObject(value);
  if (
    !selector ||
    typeof selector.extension_name !== 'string' ||
    !selector.extension_name ||
    (selector.object_name != null &&
      typeof selector.object_name !== 'string') ||
    (selector.behavior_name != null &&
      typeof selector.behavior_name !== 'string')
  ) {
    throw new PlaymeshAiLocalToolError(
      'invalid_event_expression_scope'
    );
  }
  return {
    extensionName: selector.extension_name,
    objectName:
      typeof selector.object_name === 'string' ? selector.object_name : null,
    behaviorName:
      typeof selector.behavior_name === 'string'
        ? selector.behavior_name
        : null,
  };
};

const eventExpressionMatchesScope = ({
  expression,
  selector,
} /*: {|
  expression: any,
  selector: {|
    extensionName: string,
    objectName: ?string,
    behaviorName: ?string,
  |},
|} */) /*: boolean */ => {
  const scope = summarizeInstructionScope(expression.scope);
  const objectScope = asObject(scope.object);
  const behaviorScope = asObject(scope.behavior);
  return (
    scope.extensionName === selector.extensionName &&
    (objectScope && typeof objectScope.name === 'string'
      ? objectScope.name
      : null) === selector.objectName &&
    (behaviorScope && typeof behaviorScope.name === 'string'
      ? behaviorScope.name
      : null) === selector.behaviorName
  );
};

const enumerateProjectEventExpressions = ({
  project,
  i18n,
} /*: {|
  project: gdProject,
  i18n: any,
|} */) /*: Array<any> */ => {
  const expressions = [
    ...enumerateAllExpressions('number', project, i18n),
    ...enumerateAllExpressions('string', project, i18n),
  ];
  const seen /*: Set<string> */ = new Set();
  return expressions.filter(expression => {
    const key = `${expression.type}\u0000${eventMetadataScopeKey(
      expression.scope
    )}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
};

const enumerateProjectEventInstructions = ({
  project,
  i18n,
  kind,
} /*: {|
  project: gdProject,
  i18n: any,
  kind: 'action' | 'condition' | 'expression' | 'all',
|} */) /*: Array<any> */ => {
  const instructions = [];
  if (kind === 'action' || kind === 'all') {
    enumerateAllInstructions(false, project, i18n).forEach(instruction => {
      instructions.push({ kind: 'action', instruction });
    });
  }
  if (kind === 'condition' || kind === 'all') {
    enumerateAllInstructions(true, project, i18n).forEach(instruction => {
      instructions.push({ kind: 'condition', instruction });
    });
  }
  if (kind === 'expression' || kind === 'all') {
    enumerateProjectEventExpressions({ project, i18n }).forEach(expression => {
      instructions.push({ kind: 'expression', instruction: expression });
    });
  }
  return instructions;
};

const capabilityEndpoint = ({
  type,
  stableId,
} /*: {|
  type: string,
  stableId: string,
|} */) /*: string */ =>
  `/dev/api/gdevelop/catalog/capabilities/${encodeURIComponent(
    type
  )}/${encodeURIComponent(stableId)}`;

const readJsonObjectResponse = async (
  response /*: Response */
) /*: Promise<PlaymeshAiObject> */ => {
  const text = await response.text();
  let decoded;
  try {
    decoded = JSON.parse(text);
  } catch (_) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  const object = asObject(decoded);
  if (!object) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  return object;
};

const requestCapabilityJson = async (
  url /*: string */
) /*: Promise<PlaymeshAiObject> */ => {
  let response;
  try {
    response = await fetch(url, {
      credentials: 'same-origin',
      cache: 'no-store',
    });
  } catch (_) {
    throw new PlaymeshAiLocalToolError('capability_catalog_unavailable');
  }
  if (!response.ok) {
    throw new PlaymeshAiLocalToolError(
      response.status === 404
        ? 'capability_not_found'
        : 'capability_catalog_unavailable'
    );
  }
  return readJsonObjectResponse(response);
};

const capabilityRecord = (
  envelope /*: PlaymeshAiObject */
) /*: PlaymeshAiObject */ => {
  const record =
    asObject(envelope.capability) || asObject(envelope.item) || envelope;
  if (
    typeof record.stableId !== 'string' ||
    typeof record.type !== 'string'
  ) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  return record;
};

const ownerExtensionName = (
  capability /*: PlaymeshAiObject */
) /*: ?string */ => {
  const owner = capability.ownerExtension;
  if (typeof owner === 'string' && owner) {
    return owner.startsWith('extension:')
      ? owner.slice('extension:'.length)
      : owner;
  }
  const ownerRecord = asObject(owner);
  if (ownerRecord) {
    if (typeof ownerRecord.name === 'string' && ownerRecord.name) {
      return ownerRecord.name;
    }
    const ownerStableId = ownerRecord.stableId;
    if (
      typeof ownerStableId === 'string' &&
      ownerStableId.startsWith('extension:')
    ) {
      return ownerStableId.slice('extension:'.length);
    }
  }
  const capabilityStableId = capability.stableId;
  if (
    capability.type === 'extension' &&
    typeof capabilityStableId === 'string' &&
    capabilityStableId.startsWith('extension:')
  ) {
    return capabilityStableId.slice('extension:'.length);
  }
  return null;
};

const requireOwnerExtensionName = (
  capability /*: PlaymeshAiObject */
) /*: string */ => {
  const extensionName = ownerExtensionName(capability);
  if (!extensionName) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  return extensionName;
};

const isCapabilityInstalled = ({
  project,
  capability,
} /*: {|
  project: gdProject,
  capability: PlaymeshAiObject,
|} */) /*: boolean */ => {
  const extensionName = ownerExtensionName(capability);
  if (!extensionName) return false;
  if (project.hasEventsFunctionsExtensionNamed(extensionName)) return true;
  const platform = project.getCurrentPlatform();
  return !!(platform && platform.isExtensionLoaded(extensionName));
};

const withInstalledState = ({
  project,
  capability,
} /*: {|
  project: gdProject,
  capability: PlaymeshAiObject,
|} */) /*: PlaymeshAiObject */ => ({
  ...capability,
  installed: isCapabilityInstalled({ project, capability }),
});

const LOCAL_PLAYMESH_EXTENSION_BASE_PATH =
  '/playmesh/GDevelop/playmesh/extensions/';

const stringValue = (value /*: mixed */) /*: string */ =>
  typeof value === 'string' ? value : '';

const stringValues = (value /*: mixed */) /*: Array<string> */ =>
  Array.isArray(value)
    ? value.filter(item => typeof item === 'string')
    : [];

const isPlaymeshLocalExtensionHeader = (
  value /*: mixed */
) /*: boolean */ => {
  const header = asObject(value);
  return !!(
    header &&
    typeof header.url === 'string' &&
    header.url.startsWith(LOCAL_PLAYMESH_EXTENSION_BASE_PATH)
  );
};

const capabilitySearchEntryFromHeader = ({
  header,
  type,
} /*: {|
  header: mixed,
  type: 'extension' | 'behavior',
|} */) /*: ?PlaymeshAiCapabilitySearchEntry */ => {
  const record = asObject(header);
  if (!record) return null;
  const name = stringValue(record.name);
  const ownerExtension =
    type === 'extension' ? name : stringValue(record.extensionName);
  if (!name || !ownerExtension) return null;
  const stableId =
    type === 'extension' ? name : `${ownerExtension}::${name}`;
  const canonicalName = stringValue(record.fullName) || name;
  const canonicalSummary =
    stringValue(record.shortDescription) || stringValue(record.description);
  const category = stringValue(record.category) || 'General';
  const tags = stringValues(record.tags);
  return {
    summary: {
      stableId,
      type,
      canonicalName,
      localizedName: canonicalName,
      canonicalSummary,
      localizedSummary: canonicalSummary,
      ownerExtension,
      category,
    },
    searchText: [
      stableId,
      canonicalName,
      canonicalSummary,
      ownerExtension,
      category,
      ...tags,
    ]
      .join('\n')
      .toLowerCase(),
  };
};

const loadEditorCapabilitySearchEntries = async () /*: Promise<Array<PlaymeshAiCapabilitySearchEntry>> */ => {
  const [extensionsRegistry, behaviorsRegistry] = await Promise.all([
    getPlaymeshExtensionsRegistry(),
    getPlaymeshBehaviorsRegistry(),
  ]);
  const entries = [];
  extensionsRegistry.headers.forEach(header => {
    const entry = capabilitySearchEntryFromHeader({
      header,
      type: 'extension',
    });
    if (entry) entries.push(entry);
  });
  behaviorsRegistry.headers.forEach(header => {
    const entry = capabilitySearchEntryFromHeader({
      header,
      type: 'behavior',
    });
    if (entry) entries.push(entry);
  });
  entries.sort((left, right) => {
    const leftName = stringValue(left.summary.canonicalName).toLowerCase();
    const rightName = stringValue(right.summary.canonicalName).toLowerCase();
    const byName = leftName.localeCompare(rightName, 'en');
    return byName !== 0
      ? byName
      : stringValue(left.summary.stableId).localeCompare(
          stringValue(right.summary.stableId),
          'en'
        );
  });
  return entries;
};

const findLocalExtensionShortHeader = async (
  extensionName /*: string */
) /*: Promise<?ExtensionShortHeader> */ => {
  const registry = await getPlaymeshExtensionsRegistry();
  return (
    registry.headers.find(
      header =>
        header.name === extensionName &&
        isPlaymeshLocalExtensionHeader(header)
    ) || null
  );
};

const findLocalBehaviorShortHeader = async ({
  extensionName,
  behaviorName,
} /*: {|
  extensionName: string,
  behaviorName: string,
|} */) /*: Promise<?BehaviorShortHeader> */ => {
  const registry = await getPlaymeshBehaviorsRegistry();
  return (
    registry.headers.find(
      header =>
        header.extensionName === extensionName &&
        header.name === behaviorName &&
        isPlaymeshLocalExtensionHeader(header)
    ) || null
  );
};

const summarizeCapabilityFunctions = (
  value /*: mixed */
) /*: PlaymeshAiCapabilityFunctionSummaries */ => {
  const actions /*: Array<PlaymeshAiObject> */ = [];
  const conditions /*: Array<PlaymeshAiObject> */ = [];
  const expressions /*: Array<PlaymeshAiObject> */ = [];
  if (!Array.isArray(value)) return { actions, conditions, expressions };
  value.forEach(item => {
    const record = asObject(item);
    const name = record ? stringValue(record.name) : '';
    if (!record || !name || record.private === true) return;
    const summary /*: PlaymeshAiObject */ = {
      name,
      canonicalName: stringValue(record.fullName) || name,
      summary: stringValue(record.description),
    };
    switch (record.functionType) {
      case 'Action':
      case 'ActionWithOperator':
        actions.push(summary);
        break;
      case 'Condition':
        conditions.push(summary);
        break;
      case 'Expression':
      case 'StringExpression':
        expressions.push(summary);
        break;
      case 'ExpressionAndCondition':
        conditions.push(summary);
        expressions.push(summary);
        break;
    }
  });
  return { actions, conditions, expressions };
};

const localCapabilityDetails = async ({
  type,
  stableId,
} /*: {|
  type: 'extension' | 'behavior',
  stableId: string,
|} */) /*: Promise<?PlaymeshAiObject> */ => {
  const separator = stableId.indexOf('::');
  const extensionName =
    type === 'extension'
      ? stableId
      : separator > 0
      ? stableId.slice(0, separator)
      : '';
  const behaviorName =
    type === 'behavior' && separator > 0
      ? stableId.slice(separator + 2)
      : '';
  if (!extensionName || (type === 'behavior' && !behaviorName)) return null;
  const extensionHeader = await findLocalExtensionShortHeader(extensionName);
  if (!extensionHeader) return null;
  const serializedExtension = await getPlaymeshExtension(extensionHeader);
  const extension = asObject(serializedExtension);
  if (!extension) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  const behaviorHeader =
    type === 'behavior'
      ? await findLocalBehaviorShortHeader({ extensionName, behaviorName })
      : null;
  if (type === 'behavior' && !behaviorHeader) return null;
  const entry = capabilitySearchEntryFromHeader({
    header: type === 'extension' ? extensionHeader : behaviorHeader,
    type,
  });
  if (!entry) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  const behavior =
    type === 'behavior' && Array.isArray(extension.eventsBasedBehaviors)
      ? extension.eventsBasedBehaviors
          .map(item => asObject(item))
          .find(item => item && item.name === behaviorName) || null
      : null;
  if (type === 'behavior' && !behavior) {
    throw new PlaymeshAiLocalToolError('capability_response_invalid');
  }
  const dependencies /*: Array<PlaymeshAiObject> */ = [];
  if (Array.isArray(extension.requiredExtensions)) {
    extension.requiredExtensions.forEach(item => {
      const dependency = asObject(item);
      if (!dependency) return;
      const name = stringValue(dependency.extensionName);
      if (!name) return;
      const minimumVersion = stringValue(dependency.extensionVersion);
      dependencies.push({
        type: 'extension',
        stableId: name,
        ...(minimumVersion ? { minimumVersion } : {}),
      });
    });
  }
  if (
    behaviorHeader &&
    Array.isArray(behaviorHeader.allRequiredBehaviorTypes)
  ) {
    behaviorHeader.allRequiredBehaviorTypes.forEach(requiredType => {
      if (typeof requiredType !== 'string' || !requiredType) return;
      dependencies.push({ type: 'behavior', stableId: requiredType });
    });
  }
  const functions = summarizeCapabilityFunctions(
    behavior ? behavior.eventsFunctions : extension.eventsFunctions
  );
  const objectType = behavior
    ? stringValue(behavior.objectType) ||
      stringValue(behaviorHeader && behaviorHeader.objectType)
    : '';
  return {
    ...entry.summary,
    dependencies,
    applicableObjectTypes: objectType ? [objectType] : [],
    conditions: functions.conditions,
    actions: functions.actions,
    expressions: functions.expressions,
    source: {
      kind: 'playmesh-local-extension',
      path: extensionHeader.url,
      tier: extensionHeader.tier,
      cache: 'bundled',
    },
  };
};

const getCapabilityDetails = async ({
  type,
  stableId,
} /*: {|
  type: 'extension' | 'behavior',
  stableId: string,
|} */) /*: Promise<PlaymeshAiObject> */ => {
  const localCapability = await localCapabilityDetails({ type, stableId });
  if (localCapability) return localCapability;
  return capabilityRecord(
    await requestCapabilityJson(capabilityEndpoint({ type, stableId }))
  );
};

const dependencyReference = (
  value /*: mixed */
) /*: ?{| stableId: string, type: 'extension' | 'behavior' |} */ => {
  if (typeof value === 'string' && value) {
    const type = value.startsWith('behavior:') || value.includes('::')
      ? 'behavior'
      : 'extension';
    return {
      stableId: value.replace(/^(?:behavior|extension):/, ''),
      type,
    };
  }
  const record = asObject(value);
  if (!record) return null;
  const stableId = record.stableId || record.id || record.extensionName;
  if (typeof stableId !== 'string' || !stableId) return null;
  const normalizedStableId = stableId.replace(
    /^(?:behavior|extension):/,
    ''
  );
  const declaredType = record.type;
  return {
    stableId: normalizedStableId,
    type:
      declaredType === 'behavior' ||
      (declaredType !== 'extension' && normalizedStableId.includes('::'))
      ? 'behavior'
      : 'extension',
  };
};

const artifactRequest = (
  capability /*: PlaymeshAiObject */
) /*: PlaymeshAiObject */ => {
  const artifact = asObject(capability.artifact);
  const required = [
    'id',
    'kind',
    'repository',
    'commit',
    'rootTreeSha',
    'path',
    'declaredBytes',
    'sha256',
    'mediaType',
  ];
  if (!artifact || required.some(key => artifact[key] == null)) {
    throw new PlaymeshAiLocalToolError('capability_artifact_unavailable');
  }
  return {
    id: artifact.id,
    kind: artifact.kind,
    repository: artifact.repository,
    commit: artifact.commit,
    rootTreeSha: artifact.rootTreeSha,
    path: artifact.path,
    declaredBytes: artifact.declaredBytes,
    ...(artifact.gitBlobOid ? { gitBlobOid: artifact.gitBlobOid } : {}),
    sha256: artifact.sha256,
    mediaType: artifact.mediaType,
  };
};

const downloadSerializedExtension = async (
  capability /*: PlaymeshAiObject */
) /*: Promise<PlaymeshAiObject> */ => {
  const source = asObject(capability.source);
  if (source && source.kind === 'playmesh-local-extension') {
    const extensionName = requireOwnerExtensionName(capability);
    const extensionHeader = await findLocalExtensionShortHeader(extensionName);
    if (!extensionHeader) {
      throw new PlaymeshAiLocalToolError('capability_artifact_unavailable');
    }
    const extension = asObject(
      await getPlaymeshExtension(extensionHeader)
    );
    if (!extension || extension.name !== extensionName) {
      throw new PlaymeshAiLocalToolError('capability_artifact_unavailable');
    }
    return extension;
  }
  let response;
  try {
    response = await fetch('/dev/api/gdevelop/catalog/artifact', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin',
      cache: 'no-store',
      body: JSON.stringify(artifactRequest(capability)),
    });
  } catch (_) {
    throw new PlaymeshAiLocalToolError('capability_artifact_unavailable');
  }
  if (!response.ok) {
    throw new PlaymeshAiLocalToolError('capability_artifact_unavailable');
  }
  return readJsonObjectResponse(response);
};

const resolveExtensionClosure = async ({
  type,
  stableId,
} /*: {|
  type: 'extension' | 'behavior',
  stableId: string,
|} */) /*: Promise<Array<PlaymeshAiObject>> */ => {
  const pending /*: Array<{|
    type: 'extension' | 'behavior',
    stableId: string,
  |}> */ = [{ type, stableId }];
  const byExtensionName /*: Map<string, PlaymeshAiObject> */ = new Map();
  while (pending.length) {
    const next = pending.pop();
    if (!next) break;
    const details = await getCapabilityDetails(next);
    const extensionName = ownerExtensionName(details);
    if (!extensionName || byExtensionName.has(extensionName)) continue;
    byExtensionName.set(extensionName, details);
    const dependencies = Array.isArray(details.dependencies)
      ? details.dependencies
      : [];
    dependencies.forEach(dependency => {
      const reference = dependencyReference(dependency);
      if (reference) pending.push(reference);
    });
  }
  return Array.from(byExtensionName.values());
};

/**
 * wrapper 只替换官方依赖云 AI、商店或服务端计划的部分。对象工具仍走
 * 锁定版本官方实现，但网络搜索恒定返回 nothing-found，显式 object_type
 * 与复制已有对象仍保持官方语义。
 */
export const createPlaymeshAiLocalToolWrappers = ({
  applyEventPayload,
  readFullDocs,
  updatePlan,
  stagedResource,
  beforeProjectMutation,
  onFetchNewlyAddedResources,
  onNewResourcesAdded,
  toolsContract,
} /*: PlaymeshAiLocalToolWrappersOptions */ = {}) /*: PlaymeshAiLocalToolWrappers */ => {
  const createObject = async (
    context /*: PlaymeshAiLocalToolContext */
  ) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
    const { call, project, runnerOptions, runOfficial } = context;
    if (
      call.toolName === 'create_or_replace_object' &&
      call.arguments.replace_existing_object === true
    ) {
      return replaceObjectFromLocalSource({ call, project, runnerOptions });
    }
    return runOfficial({
        relatedAiRequestId: null,
        getRelatedAiRequestLastMessages: () => ({
          lastUserMessage: null,
          lastAssistantMessages: [],
        }),
        searchAndInstallAsset: storeDisabledAssetSearch,
        searchAndInstallResources: storeDisabledResourceSearch,
        // 仅允许当前内核已注册的类型；官方函数随后仍会通过 MetadataProvider
        // 验证类型，未知扩展不会触发网络安装。
        ensureExtensionInstalled: async () => {},
      });
  };

  return {
    ...playmeshAiRuntimeDebuggerTools.wrappers,
    ...createPlaymeshAiPiskelToolWrappers({
      stagedResource,
      beforeProjectMutation,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    }),
    ...createPlaymeshAiJfxrYarnTools({
      beforeProjectMutation,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    }),
    list_event_types: async ({
      call,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ =>
      finished({
        call,
        success: true,
        output: { eventTypes: enumerateEventsMetadata() },
      }),
    get_event_type_details: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const eventType = call.arguments.event_type;
      if (typeof eventType !== 'string' || !eventType) {
        throw new PlaymeshAiLocalToolError('invalid_event_type');
      }
      const metadata = enumerateEventsMetadata().find(
        candidate => candidate.type === eventType
      );
      return finished({
        call,
        success: true,
        output: metadata
          ? {
              status: 'available',
              eventType,
              fullName: metadata.fullName,
              description: metadata.description,
              canonicalEmptyEventJson: createCanonicalEmptyEventJson({
                project,
                eventType,
              }),
              serialization: 'gd.EventsList/5.6.276-canonical',
            }
          : { status: 'not-found', eventType },
      });
    },
    read_scene_events_json: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const sceneName = call.arguments.scene_name;
      if (
        typeof sceneName !== 'string' ||
        !project.hasLayoutNamed(sceneName)
      ) {
        throw new PlaymeshAiLocalToolError('event_scene_not_found');
      }
      return finished({
        call,
        success: true,
        output: {
          eventsJson: serializeToJSObject(
            project.getLayout(sceneName).getEvents()
          ),
          serialization: 'gd.EventsList/5.6.276',
        },
      });
    },
    list_event_instructions: async ({
      call,
      project,
      runnerOptions,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const kind = normalizeEventInstructionKind(call.arguments.kind, true);
      const rawQuery = call.arguments.query;
      if (typeof rawQuery !== 'string' || !rawQuery.trim()) {
        throw new PlaymeshAiLocalToolError('invalid_event_instruction_query');
      }
      const query = rawQuery.trim();
      const normalizedQuery = query.toLowerCase();
      const instructions = enumerateProjectEventInstructions({
        project,
        i18n: runnerOptions.i18n,
        kind,
      })
        .map(({ kind: instructionKind, instruction }) =>
          instructionKind === 'expression'
            ? summarizeEventExpression({
                expression: instruction,
                includeParameters: false,
              })
            : summarizeEventInstruction({
                kind: instructionKind,
                instruction,
                includeParameters: false,
              })
        )
        .filter(instruction => {
          if (!normalizedQuery) return true;
          const scope = asObject(instruction.scope) || {};
          const objectScope = asObject(scope.object);
          const behaviorScope = asObject(scope.behavior);
          return [
            instruction.canonicalType,
            instruction.fullName,
            instruction.description,
            instruction.group,
            scope.extensionName,
            objectScope && objectScope.name,
            behaviorScope && behaviorScope.name,
          ].some(
            value =>
              typeof value === 'string' &&
              value.toLowerCase().includes(normalizedQuery)
          );
        });
      return finished({
        call,
        success: true,
        output: { kind, query, instructions },
      });
    },
    get_event_instruction_details: async ({
      call,
      project,
      runnerOptions,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const kind = normalizeEventInstructionKind(call.arguments.kind, false);
      const instructionType = call.arguments.instruction_type;
      if (typeof instructionType !== 'string' || !instructionType) {
        throw new PlaymeshAiLocalToolError('invalid_event_instruction_type');
      }
      const matches = enumerateProjectEventInstructions({
        project,
        i18n: runnerOptions.i18n,
        kind,
      })
        .filter(({ instruction }) => instruction.type === instructionType)
        .map(({ kind: instructionKind, instruction }) =>
          instructionKind === 'expression'
            ? summarizeEventExpression({
                expression: instruction,
                includeParameters: true,
              })
            : summarizeEventInstruction({
                kind: instructionKind,
                instruction,
                includeParameters: true,
              })
        );
      return finished({
        call,
        success: true,
        output: {
          status: matches.length ? 'available' : 'not-found',
          kind,
          instructionType,
          matches,
        },
      });
    },
    format_event_expression: async ({
      call,
      project,
      runnerOptions,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const instructionType = call.arguments.instruction_type;
      const rawParameterValues = call.arguments.parameter_values;
      const shouldConvertToString =
        call.arguments.should_convert_to_string === true;
      if (typeof instructionType !== 'string' || !instructionType) {
        throw new PlaymeshAiLocalToolError('invalid_event_instruction_type');
      }
      if (
        !Array.isArray(rawParameterValues) ||
        rawParameterValues.some(value => typeof value !== 'string')
      ) {
        throw new PlaymeshAiLocalToolError(
          'invalid_event_expression_parameter_values'
        );
      }
      const parameterValues /*: Array<string> */ = rawParameterValues.map(
        value => (typeof value === 'string' ? value : '')
      );
      if (
        call.arguments.should_convert_to_string != null &&
        typeof call.arguments.should_convert_to_string !== 'boolean'
      ) {
        throw new PlaymeshAiLocalToolError(
          'invalid_event_expression_conversion'
        );
      }
      const selector = parseEventExpressionScopeSelector(
        call.arguments.scope
      );
      const allMatches = enumerateProjectEventExpressions({
        project,
        i18n: runnerOptions.i18n,
      }).filter(expression => expression.type === instructionType);
      const matches = selector
        ? allMatches.filter(expression =>
            eventExpressionMatchesScope({ expression, selector })
          )
        : allMatches;
      if (matches.length !== 1) {
        return finished({
          call,
          success: true,
          output: {
            status: matches.length ? 'ambiguous' : 'not-found',
            instructionType,
            matches: matches.map(expression =>
              summarizeEventExpression({
                expression,
                includeParameters: true,
              })
            ),
          },
        });
      }

      const expression = matches[0];
      if (
        parameterValues.length !==
        expression.metadata.getParametersCount()
      ) {
        throw new PlaymeshAiLocalToolError(
          'event_expression_parameter_count_mismatch'
        );
      }
      return finished({
        call,
        success: true,
        output: {
          status: 'formatted',
          instructionType,
          scope: summarizeInstructionScope(expression.scope),
          returnType: expression.metadata.getReturnType(),
          expressionText: formatExpressionCall(
            expression,
            parameterValues,
            { shouldConvertToString }
          ),
        },
      });
    },
    import_project_resource: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const resourceName = call.arguments.resource_name;
      const resourceKind = call.arguments.resource_kind;
      const contentHash = call.arguments.content_hash;
      const mime = call.arguments.mime;
      const size = call.arguments.size;
      if (
        !stagedResource ||
        typeof resourceName !== 'string' ||
        typeof resourceKind !== 'string' ||
        stagedResource.resourceName !== resourceName ||
        stagedResource.resourceKind !== resourceKind ||
        stagedResource.contentHash !== contentHash ||
        stagedResource.mime !== mime ||
        stagedResource.size !== size
      ) {
        throw new PlaymeshAiLocalToolError('staged_resource_reference_mismatch');
      }
      const resourcesManager = project.getResourcesManager();
      const resource = createNewResource(resourceKind);
      if (!resource) {
        throw new PlaymeshAiLocalToolError('resource_creation_unavailable');
      }
      const objectUrl = playmeshResourceObjectUrlRegistry.acquire({
        logicalUrl: resourceName,
        blob: stagedResource.blob,
        contentHash: stagedResource.contentHash,
      });
      try {
        resource.setName(resourceName);
        resource.setFile(objectUrl);
        resource.setOrigin('playmesh-local-resource', resourceName);
        applyResourceDefaults(project, resource);
        resourcesManager.addResource(resource);
        if (!resourcesManager.hasResource(resourceName)) {
          throw new PlaymeshAiLocalToolError('resource_add_failed');
        }
      } finally {
        resource.delete();
      }
      return finished({
        call,
        success: true,
        output: {
          resource_name: resourceName,
          resource_kind: resourceKind,
          content_hash: contentHash,
          mime,
          size,
        },
        didModifyProject: true,
      });
    },
    list_scenes: async ({
      call,
      project,
      selectedSceneName,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const sceneNames = [];
      for (let index = 0; index < project.getLayoutsCount(); index++) {
        sceneNames.push(project.getLayoutAt(index).getName());
      }
      return finished({
        call,
        success: true,
        output: {
          sceneNames,
          selectedSceneName:
            selectedSceneName && project.hasLayoutNamed(selectedSceneName)
              ? selectedSceneName
              : null,
        },
      });
    },
    list_project_objects: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const sceneName = call.arguments.scene_name;
      if (
        typeof sceneName !== 'string' ||
        !project.hasLayoutNamed(sceneName)
      ) {
        throw new PlaymeshAiLocalToolError('project_object_scene_not_found');
      }
      const sceneObjects = project.getLayout(sceneName).getObjects();
      const globalObjects = project.getObjects();
      return finished({
        call,
        success: true,
        output: {
          sceneName,
          objects: [
            ...summarizeProjectObjects({
              objectsContainer: sceneObjects,
              scope: 'scene',
            }),
            ...summarizeProjectObjects({
              objectsContainer: globalObjects,
              scope: 'global',
            }),
          ],
          objectGroups: [
            ...summarizeProjectObjectGroups({
              objectsContainer: sceneObjects,
              scope: 'scene',
            }),
            ...summarizeProjectObjectGroups({
              objectsContainer: globalObjects,
              scope: 'global',
            }),
          ],
        },
      });
    },
    list_prefabs: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const prefabs = [];
      for (
        let extensionIndex = 0;
        extensionIndex < project.getEventsFunctionsExtensionsCount();
        extensionIndex++
      ) {
        const extension = project.getEventsFunctionsExtensionAt(extensionIndex);
        const eventsBasedObjects = extension.getEventsBasedObjects();
        for (
          let prefabIndex = 0;
          prefabIndex < eventsBasedObjects.getCount();
          prefabIndex++
        ) {
          prefabs.push(
            summarizePrefabReference({
              extension,
              prefab: eventsBasedObjects.getAt(prefabIndex),
            })
          );
        }
      }
      return finished({ call, success: true, output: { prefabs } });
    },
    inspect_prefab: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const extensionName = call.arguments.extension_name;
      const prefabName = call.arguments.prefab_name;
      if (
        typeof extensionName !== 'string' ||
        !project.hasEventsFunctionsExtensionNamed(extensionName)
      ) {
        throw new PlaymeshAiLocalToolError('prefab_extension_not_found');
      }
      const extension = project.getEventsFunctionsExtension(extensionName);
      const eventsBasedObjects = extension.getEventsBasedObjects();
      if (
        typeof prefabName !== 'string' ||
        !eventsBasedObjects.has(prefabName)
      ) {
        throw new PlaymeshAiLocalToolError('prefab_not_found');
      }
      return finished({
        call,
        success: true,
        output: {
          prefab: inspectPrefabDefinition({
            extension,
            prefab: eventsBasedObjects.get(prefabName),
          }),
        },
      });
    },
    create_object: createObject,
    create_or_replace_object: createObject,
    add_scene_events: async (
      context /*: PlaymeshAiLocalToolContext */
    ) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      if (typeof applyEventPayload !== 'function') {
        throw new PlaymeshAiLocalToolError(
          'event_payload_executor_unavailable',
          true
        );
      }
      return applyEventPayload(context);
    },
    get_gdevelop_tool_details: async ({
      call,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const toolName = call.arguments.tool_name;
      if (typeof toolName !== 'string' || !/^[a-z][a-z0-9_]*$/.test(toolName)) {
        throw new PlaymeshAiLocalToolError('invalid_tool_name');
      }
      try {
        const tools = toolsContract && toolsContract.tools;
        const tool = Array.isArray(tools)
          ? asObject(
              tools.find(candidate => {
                const item = asObject(candidate);
                return item && item.name === toolName;
              })
            )
          : null;
        if (
          !tool ||
          tool.name !== toolName ||
          !asObject(tool.argumentsSchema)
        ) {
          throw new PlaymeshAiLocalToolError('tool_details_response_invalid');
        }
        return finished({
          call,
          success: true,
          output: { status: 'available', tool },
        });
      } catch (error) {
        const code =
          error instanceof PlaymeshAiLocalToolError
            ? error.code
            : 'tool_details_unavailable';
        return finished({
          call,
          success: true,
          output: { status: 'unavailable', code },
        });
      }
    },
    search_gdevelop_capabilities: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const query = call.arguments.query;
      if (typeof query !== 'string') {
        throw new PlaymeshAiLocalToolError('invalid_capability_query');
      }
      const page = call.arguments.page || 1;
      const pageSize = call.arguments.pageSize || 10;
      if (
        !Number.isSafeInteger(page) ||
        page < 1 ||
        !Number.isSafeInteger(pageSize) ||
        pageSize < 1 ||
        pageSize > 50
      ) {
        throw new PlaymeshAiLocalToolError('invalid_capability_query');
      }
      const normalizedQuery = query.trim().toLowerCase();
      const normalizedCategory =
        typeof call.arguments.category === 'string'
          ? call.arguments.category.trim().toLowerCase()
          : '';
      const requestedKind = call.arguments.kind;
      try {
        const matches = (await loadEditorCapabilitySearchEntries()).filter(
          entry => {
            const capabilityType = entry.summary.type;
            if (
              (requestedKind === 'behavior' ||
                requestedKind === 'extension') &&
              capabilityType !== requestedKind
            ) {
              return false;
            }
            if (
              normalizedCategory &&
              stringValue(entry.summary.category).toLowerCase() !==
                normalizedCategory
            ) {
              return false;
            }
            return (
              !normalizedQuery || entry.searchText.includes(normalizedQuery)
            );
          }
        );
        const start = (page - 1) * pageSize;
        const items = matches
          .slice(start, start + pageSize)
          .map(entry =>
            withInstalledState({ project, capability: entry.summary })
          );
        return finished({
          call,
          success: true,
          output: {
            status: 'available',
            requestId: null,
            page,
            pageSize,
            total: matches.length,
            items,
          },
        });
      } catch (error) {
        const code =
          error instanceof PlaymeshAiLocalToolError
            ? error.code
            : 'capability_catalog_unavailable';
        return finished({
          call,
          success: true,
          output: { status: 'unavailable', code, items: [] },
        });
      }
    },
    get_gdevelop_capability_details: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const stableId = call.arguments.stable_id;
      const type = call.arguments.type;
      if (
        typeof stableId !== 'string' ||
        (type !== 'extension' && type !== 'behavior')
      ) {
        throw new PlaymeshAiLocalToolError('invalid_capability_reference');
      }
      try {
        const capability = await getCapabilityDetails({ type, stableId });
        return finished({
          call,
          success: true,
          output: {
            status: 'available',
            capability: withInstalledState({ project, capability }),
          },
        });
      } catch (error) {
        const code =
          error instanceof PlaymeshAiLocalToolError
            ? error.code
            : 'capability_catalog_unavailable';
        return finished({
          call,
          success: true,
          output: { status: 'unavailable', code },
        });
      }
    },
    install_gdevelop_extension: async ({
      call,
      project,
      runnerOptions,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      const stableId = call.arguments.stable_id;
      const type = call.arguments.type;
      if (
        typeof stableId !== 'string' ||
        (type !== 'extension' && type !== 'behavior')
      ) {
        throw new PlaymeshAiLocalToolError('invalid_capability_reference');
      }
      const closure = await resolveExtensionClosure({ type, stableId });
      if (!closure.length) {
        throw new PlaymeshAiLocalToolError('capability_not_found');
      }
      const requested = closure[0];
      const requestedOwner = requireOwnerExtensionName(requested);
      const toInstall = closure.filter(
        capability => !isCapabilityInstalled({ project, capability })
      );
      if (!toInstall.length) {
        return finished({
          call,
          success: true,
          output: {
            status: 'already-installed',
            requestedStableId: stableId,
            ownerExtension: requestedOwner,
            installedExtensions: [],
            dependencies: closure
              .map(requireOwnerExtensionName)
              .filter(name => name !== requestedOwner),
          },
        });
      }
      const serializedExtensions = await Promise.all(
        toInstall.map(downloadSerializedExtension)
      );
      const expectedNames = toInstall.map(requireOwnerExtensionName);
      serializedExtensions.forEach((extension, index) => {
        if (
          typeof extension.name !== 'string' ||
          extension.name !== expectedNames[index]
        ) {
          throw new PlaymeshAiLocalToolError(
            'capability_artifact_identity_mismatch'
          );
        }
      });
      runnerOptions.onWillInstallExtension(expectedNames);
      await addSerializedExtensionsToProject(
        ({
          loadProjectEventsFunctionsExtensions: async () => {},
        } /*: any */),
        project,
        (serializedExtensions /*: any */),
        expectedNames
      );
      runnerOptions.onExtensionInstalled(expectedNames);
      const installedExtensions = expectedNames;
      if (
        installedExtensions.some(
          extensionName =>
            !project.hasEventsFunctionsExtensionNamed(extensionName)
        )
      ) {
        throw new PlaymeshAiLocalToolError('capability_install_incomplete');
      }
      return finished({
        call,
        success: true,
        output: {
          status: 'installed',
          requestedStableId: stableId,
          ownerExtension: requestedOwner,
          installedExtensions,
          dependencies: installedExtensions.filter(
            name => name !== requestedOwner
          ),
        },
        didModifyProject: true,
      });
    },
    read_full_docs: async ({
      call,
      project,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      if (typeof readFullDocs !== 'function') {
        return finished({
          call,
          success: false,
          output: { message: 'Installed extension documentation is unavailable.' },
        });
      }
      const extensionNames = call.arguments.extension_names;
      if (typeof extensionNames !== 'string') {
        return finished({
          call,
          success: false,
          output: { message: 'The extension documentation request is invalid.' },
        });
      }
      const documentation = await readFullDocs({
        project,
        extensionNames,
      });
      return finished({
        call,
        success: true,
        output: { documentation },
      });
    },
    create_or_update_plan: async ({
      call,
    } /*: PlaymeshAiLocalToolContext */) /*: Promise<PlaymeshAiLocalToolExecution> */ => {
      if (typeof updatePlan !== 'function') {
        return finished({
          call,
          success: false,
          output: { message: 'The local plan view is unavailable.' },
        });
      }
      await updatePlan(validateLocalPlan(call.arguments));
      return finished({
        call,
        success: true,
        output: { message: 'The local plan was updated.' },
      });
    },
  };
};

export default createPlaymeshAiLocalToolWrappers;
