// @flow

import { makeSimplifiedProjectBuilder } from '../EditorFunctions/SimplifiedProject/SimplifiedProject';
import { renderNonTranslatedEventsAsText } from '../EventsSheet/EventsTree/TextRenderer';
import {
  PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION,
  validatePlaymeshAiCapabilitiesReference,
} from './PlaymeshAiProtocol';
import { getPlaymeshLogicalResourceUrl } from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer';
/*::
import type {
  PlaymeshAiCapabilitiesReference,
  PlaymeshAiObject,
} from './PlaymeshAiProtocol';
type PlaymeshAiSimplifiedResource = {
  +file?: string,
  +logicalId?: string,
  +name?: string,
  ...,
};
type PlaymeshAiSimplifiedProject = {
  +resources?: $ReadOnlyArray<PlaymeshAiSimplifiedResource>,
  ...,
};
type PlaymeshAiSelectedSceneContext = {|
  name: string,
  eventsText: string,
|};
type PlaymeshAiProjectContext = {|
  schemaVersion: string,
  selectedScene: ?PlaymeshAiSelectedSceneContext,
  projectSummary: {|
    simplifiedProject: PlaymeshAiSimplifiedProject,
    projectSpecificExtensionsSummary: PlaymeshAiObject,
  |},
  capabilities: PlaymeshAiCapabilitiesReference,
|};
type PlaymeshAiContextSanitizationDiagnostic = {|
  path: string,
  valueType: string,
  kind: 'runtime_address_restored' | 'runtime_address_omitted',
|};
*/

const cloneJsonValue /*: <Value>(value: Value) => Value */ = value => {
  const serialized = JSON.stringify(value);
  if (typeof serialized !== 'string') {
    throw new PlaymeshAiProjectContextError('project_context_not_json');
  }
  return JSON.parse(serialized);
};
const RESOURCE_ADDRESS = /\b(?:https?|wss?|file|data|blob):/i;
const URL_OR_TOKEN = /\b(?:https?|wss?|file|data|blob):|\bbearer\s+\S+|[?&](?:access_)?token=[^\s&#]*/i;
const NON_IDENTIFIER = /[^a-z0-9]/g;
const RUNTIME_ADDRESS_OMITTED =
  '[Runtime address omitted by the local context privacy policy]';
const SELECTED_SCENE_EVENTS_OMITTED =
  '[Playmesh: selected scene events omitted by the local context privacy policy]';

export class PlaymeshAiProjectContextError extends Error {
  /*:: code: string; reason: string; diagnosticPath: string; diagnosticType: string; */

  constructor(
    code /*: string */,
    {
      path = '$',
      valueType = 'unknown',
    } /*: {| path?: string, valueType?: string |} */ = {}
  ) {
    super('The local GDevelop AI project context contains sensitive content.');
    this.name = 'PlaymeshAiProjectContextError';
    this.code = code;
    this.diagnosticPath = path;
    this.diagnosticType = valueType;
    // `reason` is the only detail consumed by the bounded UI diagnostic. It
    // contains structural metadata only, never the rejected value.
    this.reason = `path=${path} type=${valueType}`;
  }
}

const diagnosticValueType = (value /*: mixed */) /*: string */ =>
  value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;

const diagnosticChildPath = (
  path /*: string */,
  key /*: string */
) /*: string */ =>
  /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && !sensitiveStringCode(key)
    ? `${path}.${key}`
    : `${path}.*`;

const recordFirstSanitization = (
  diagnostic /*: {| current: ?PlaymeshAiContextSanitizationDiagnostic |} */,
  next /*: PlaymeshAiContextSanitizationDiagnostic */
) /*: void */ => {
  if (!diagnostic.current) diagnostic.current = next;
};

const sensitiveStringCode = (
  value /*: string */
) /*: ?string */ => {
  if (URL_OR_TOKEN.test(value)) {
    return 'project_context_url_or_token_forbidden';
  }
  const lower = value.toLowerCase();
  if (
    lower.includes('__playmesh') ||
    lower.includes('/playmesh/') ||
    (lower.includes('playmesh') && lower.includes('bridge'))
  ) {
    return 'project_context_bridge_forbidden';
  }
  return null;
};

const assertSafeContextValue = (
  value /*: mixed */,
  path /*: string */ = '$'
) /*: void */ => {
  if (typeof value === 'string') {
    const code = sensitiveStringCode(value);
    if (code) {
      throw new PlaymeshAiProjectContextError(code, {
        path,
        valueType: 'string',
      });
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      assertSafeContextValue(item, `${path}[${index}]`)
    );
    return;
  }
  if (!value || typeof value !== 'object') return;
  const objectValue /*: { +[key: string]: mixed } */ = value;
  Object.keys(objectValue).forEach((key /*: string */) => {
    const normalizedKey = key.toLowerCase().replace(NON_IDENTIFIER, '');
    if (
      normalizedKey.includes('authorization') ||
      normalizedKey.includes('credential') ||
      normalizedKey.includes('password') ||
      normalizedKey.includes('secret') ||
      normalizedKey.includes('token') ||
      normalizedKey.includes('bridge')
    ) {
      throw new PlaymeshAiProjectContextError(
        'project_context_sensitive_field',
        {
          path: diagnosticChildPath(path, key),
          valueType: diagnosticValueType(objectValue[key]),
        }
      );
    }
    assertSafeContextValue(
      objectValue[key],
      diagnosticChildPath(path, key)
    );
  });
};

// The official simplified project can contain hydrated runtime addresses in
// nested object/extension data, not just resources[].file. These addresses
// belong to the current WebIDE transport (and can include the LAN bootstrap
// query token), so they are not project facts and must not enter model context.
// Sensitive field names and Playmesh bridge content are intentionally not
// hidden here: the final strict review still rejects them.
const omitRuntimeAddresses = (
  value /*: mixed */,
  path /*: string */,
  diagnostic /*: {| current: ?PlaymeshAiContextSanitizationDiagnostic |} */
) /*: mixed */ => {
  if (typeof value === 'string') {
    // A hydrated address is transport data as a whole. It must be omitted
    // before looking for embedded query credentials, otherwise a LAN URL such
    // as `http://host/runtime?token=...` is incorrectly preserved and then
    // rejected by the final strict policy. Strings without an address remain
    // untouched, so standalone Bearer/query-token secrets are still rejected.
    if (!RESOURCE_ADDRESS.test(value)) return value;
    recordFirstSanitization(diagnostic, {
      path,
      valueType: 'string',
      kind: 'runtime_address_omitted',
    });
    return RUNTIME_ADDRESS_OMITTED;
  }
  if (Array.isArray(value)) {
    return value.map((item, index) =>
      omitRuntimeAddresses(item, `${path}[${index}]`, diagnostic)
    );
  }
  if (!value || typeof value !== 'object') return value;
  const objectValue /*: { +[key: string]: mixed } */ = value;
  return Object.keys(objectValue).reduce(
    (sanitized /*: { [key: string]: mixed } */, key /*: string */) => {
      sanitized[key] = omitRuntimeAddresses(
        objectValue[key],
        diagnosticChildPath(path, key),
        diagnostic
      );
      return sanitized;
    },
    {}
  );
};

const omitRuntimeAddressesPreservingShape /*: <Value>(
  value: Value,
  path: string,
  diagnostic: {| current: ?PlaymeshAiContextSanitizationDiagnostic |}
) => Value */ = (value, path, diagnostic) =>
  (omitRuntimeAddresses(value, path, diagnostic) /*: any */);

const normalizeSimplifiedResourceFiles = (
  simplifiedProject /*: PlaymeshAiSimplifiedProject */,
  diagnostic /*: {| current: ?PlaymeshAiContextSanitizationDiagnostic |} */
) /*: PlaymeshAiSimplifiedProject */ => {
  if (!simplifiedProject || !Array.isArray(simplifiedProject.resources)) {
    return simplifiedProject;
  }
  const resources = simplifiedProject.resources.map((resource /*: PlaymeshAiSimplifiedResource */, index /*: number */) => {
    if (
      !resource ||
      typeof resource !== 'object' ||
      typeof resource.file !== 'string' ||
      !RESOURCE_ADDRESS.test(resource.file)
    ) {
      return resource;
    }
    // 官方 SimplifiedResource 以 name 标识资源；兼容携带 logicalId 的
    // Playmesh 资源时优先保留其逻辑引用，绝不把临时或带签名地址交给模型。
    const logicalUrl = getPlaymeshLogicalResourceUrl(resource.file);
    const referenceCandidates = [
      logicalUrl,
      resource.logicalId,
      resource.name,
    ];
    const stableReference = referenceCandidates.find(
      candidate =>
        typeof candidate === 'string' &&
        candidate.length > 0 &&
        !sensitiveStringCode(candidate)
    );
    const path = `$.projectSummary.simplifiedProject.resources[${index}].file`;
    recordFirstSanitization(diagnostic, {
      path,
      valueType: 'string',
      kind: stableReference
        ? 'runtime_address_restored'
        : 'runtime_address_omitted',
    });
    return {
      ...resource,
      ...(typeof resource.name === 'string' &&
      RESOURCE_ADDRESS.test(resource.name)
        ? { name: logicalUrl || stableReference || RUNTIME_ADDRESS_OMITTED }
        : {}),
      file: stableReference || RUNTIME_ADDRESS_OMITTED,
    };
  });
  return { ...simplifiedProject, resources };
};

/**
 * ProjectContext 只读取 GDevelop 官方简化器与事件文本渲染器的输出。
 * 它不序列化 Playmesh bridge、Gateway 路由或任何鉴权数据。
 */
export const buildPlaymeshAiProjectContext = ({
  project,
  selectedSceneName = null,
  capabilities,
  gd = global.gd,
} /*: {|
  project: gdProject,
  selectedSceneName?: ?string,
  capabilities: mixed,
  gd?: libGDevelop,
|} */) /*: PlaymeshAiObject */ => {
  if (!project || !gd) {
    throw new Error('The GDevelop AI project context is unavailable.');
  }
  const simplifiedProjectBuilder = makeSimplifiedProjectBuilder(gd);
  const simplifiedProject = simplifiedProjectBuilder.getSimplifiedProject(
    project,
    {}
  );
  const projectSpecificExtensionsSummary =
    simplifiedProjectBuilder.getProjectSpecificExtensionsSummary(project);
  const sanitizationDiagnostic /*: {| current: ?PlaymeshAiContextSanitizationDiagnostic |} */ = {
    current: null,
  };
  let selectedScene /*: ?PlaymeshAiSelectedSceneContext */ = null;
  if (
    selectedSceneName &&
    project.hasLayoutNamed(selectedSceneName)
  ) {
    const scene = project.getLayout(selectedSceneName);
    const eventsText = renderNonTranslatedEventsAsText({
      eventsList: scene.getEvents(),
    });
    const omitEventsText =
      typeof eventsText === 'string' &&
      RESOURCE_ADDRESS.test(eventsText);
    if (omitEventsText) {
      recordFirstSanitization(sanitizationDiagnostic, {
        path: '$.selectedScene.eventsText',
        valueType: 'string',
        kind: 'runtime_address_omitted',
      });
    }
    selectedScene = {
      name: selectedSceneName,
      eventsText: omitEventsText
        ? SELECTED_SCENE_EVENTS_OMITTED
        : eventsText,
    };
  }
  // DTO 边界只克隆一次；后续资源改写与审查不会触碰 gdProject 或官方
  // simplifiedProject，同时 capabilities 也不会与调用方共享可变引用。
  const context /*: PlaymeshAiProjectContext */ = cloneJsonValue({
    schemaVersion: PLAYMESH_AI_PROJECT_CONTEXT_SCHEMA_VERSION,
    selectedScene,
    projectSummary: {
      simplifiedProject: omitRuntimeAddressesPreservingShape(
        normalizeSimplifiedResourceFiles(
          simplifiedProject,
          sanitizationDiagnostic
        ),
        '$.projectSummary.simplifiedProject',
        sanitizationDiagnostic
      ),
      projectSpecificExtensionsSummary: omitRuntimeAddressesPreservingShape(
        projectSpecificExtensionsSummary,
        '$.projectSummary.projectSpecificExtensionsSummary',
        sanitizationDiagnostic
      ),
    },
    capabilities: validatePlaymeshAiCapabilitiesReference(capabilities),
  });
  assertSafeContextValue(context);
  if (sanitizationDiagnostic.current) {
    const diagnostic = sanitizationDiagnostic.current;
    // Intentionally path/type/kind only. Never log the source or replacement.
    global.console.info(
      `[PlayMesh AI] project_context_sanitized path=${diagnostic.path} ` +
        `type=${diagnostic.valueType} kind=${diagnostic.kind}`
    );
  }
  return context;
};

export default buildPlaymeshAiProjectContext;
