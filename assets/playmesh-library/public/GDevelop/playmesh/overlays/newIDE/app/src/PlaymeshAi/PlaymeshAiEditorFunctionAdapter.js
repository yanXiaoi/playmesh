// @flow

import { processEditorFunctionCalls } from '../EditorFunctions/EditorFunctionCallRunner';
import { AI_ORCHESTRATOR_TOOLS_VERSION } from '../AiGeneration/Utils';
/*::
import type { PlaymeshAiCall } from './PlaymeshAiProtocol';
import type { EditorFunctionCall } from '../EditorFunctions';
import type {
  PlaymeshAiEditorFunctionCallMapping,
  PlaymeshAiEditorFunctionExecution,
  PlaymeshAiEditorFunctionWrappers,
  PlaymeshAiRunnerOptions,
  PlaymeshAiRunnerOverrides,
  PlaymeshAiToolsContract,
} from './PlaymeshAiEditorFunctionTypes';
*/

export class PlaymeshAiEditorFunctionError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The GDevelop editor function could not be executed.');
    this.name = 'PlaymeshAiEditorFunctionError';
    this.code = code;
  }
}

const findTool = (
  toolsContract /*: PlaymeshAiToolsContract */,
  toolName /*: string */
) => {
  if (!toolsContract || !Array.isArray(toolsContract.tools)) {
    throw new PlaymeshAiEditorFunctionError('tools_contract_unavailable');
  }
  const definition = toolsContract.tools.find(tool => tool.name === toolName);
  if (!definition) {
    throw new PlaymeshAiEditorFunctionError('tool_not_exposed');
  }
  return definition;
};

const createNoNetworkRunnerOptions = (
  project /*: gdProject */
) /*: PlaymeshAiRunnerOverrides */ => ({
  generateEvents: async () => ({
    generationCompleted: false,
    errorMessage: 'The official AI generation service is disabled.',
  }),
  searchAndInstallAsset: async () => ({
    status: 'nothing-found',
    message: 'The asset store is disabled.',
    createdObjects: [],
    assetShortHeader: null,
    isTheFirstOfItsTypeInProject: false,
  }),
  searchAndInstallResources: async ({ resources = [] } = {}) => ({
    results: resources.map(resource => ({
      resourceName: resource.resourceName,
      resourceKind: resource.resourceKind,
      status: 'nothing-found',
    })),
  }),
  ensureExtensionInstalled: async ({ extensionName } = {}) => {
    const platform = project.getCurrentPlatform();
    const isBuiltInOrLoaded = !!(
      platform &&
      platform.isExtensionLoaded(extensionName)
    );
    const isProjectExtension = !!(
      project.hasEventsFunctionsExtensionNamed(extensionName)
    );
    if (!isBuiltInOrLoaded && !isProjectExtension) {
      throw new PlaymeshAiEditorFunctionError(
        'extension_not_installed_locally'
      );
    }
  },
  // Outside-editor and lifecycle callbacks intentionally stay owned by the
  // caller. The runner edits the live WebIDE project, so replacing them with
  // no-ops would leave open editors stale and hide unsaved work.
  getAssetStoreTagForNewObject: () => null,
});

/**
 * Gateway DTO 不直接进入官方 runner：只在这一处映射为 GDevelop 的
 * `{name, arguments: JSON-string, call_id}`，避免两套调用语义散落。
 */
export const toGDevelopEditorFunctionCall = ({
  call,
  toolsContract,
} /*: {|
  call: PlaymeshAiCall,
  toolsContract: PlaymeshAiToolsContract,
|} */) /*: PlaymeshAiEditorFunctionCallMapping */ => {
  const definition = findTool(toolsContract, call.toolName);
  return {
    definition,
    functionCall: {
      name: definition.officialImplementationName || definition.name,
      // The v4 contract exposes complete official v12 argument shapes. Calls
      // therefore cross this adapter unchanged; there are no hidden/fixed
      // arguments and no subset facade that can be widened by extra fields.
      arguments: JSON.stringify(call.arguments),
      call_id: call.callId,
    },
  };
};

export const runGDevelopEditorFunctionCall = async ({
  project,
  functionCall,
  runnerOptions,
  runner = processEditorFunctionCalls,
} /*: {|
  project: gdProject,
  functionCall: EditorFunctionCall,
  runnerOptions: PlaymeshAiRunnerOptions,
  runner?: typeof processEditorFunctionCalls,
|} */) /*: Promise<PlaymeshAiEditorFunctionExecution> */ => {
  const result = await runner({
    ...runnerOptions,
    // 安全覆盖永远位于 caller options 之后，wrapper/caller 无法重新打开云或商店。
    ...createNoNetworkRunnerOptions(project),
    project,
    // Use the exact tools generation understood by this pinned official
    // EditorFunctions implementation. Playmesh's own contract version is a
    // different protocol and must not be substituted here.
    toolsVersion: AI_ORCHESTRATOR_TOOLS_VERSION,
    functionCalls: [functionCall],
  });
  if (!result || !Array.isArray(result.results) || result.results.length !== 1) {
    throw new PlaymeshAiEditorFunctionError('invalid_editor_function_result');
  }
  return {
    result: result.results[0],
    createdProject: result.createdProject || null,
    createdSceneNames: result.createdSceneNames || [],
  };
};

/**
 * Playmesh wrapper 只替换官方确实依赖云 AI/商店的运行层；工具名称与
 * arguments schema 永远来自 Gateway tools contract。
 */
export const executePlaymeshAiEditorFunction = async ({
  call,
  project,
  selectedSceneName = null,
  toolsContract,
  playmeshWrappers = {},
  runnerOptions,
  runner = processEditorFunctionCalls,
} /*: {|
  call: PlaymeshAiCall,
  project: gdProject,
  selectedSceneName?: ?string,
  toolsContract: PlaymeshAiToolsContract,
  playmeshWrappers?: PlaymeshAiEditorFunctionWrappers,
  runnerOptions: PlaymeshAiRunnerOptions,
  runner?: typeof processEditorFunctionCalls,
|} */) /*: Promise<PlaymeshAiEditorFunctionExecution> */ => {
  const { definition, functionCall } = toGDevelopEditorFunctionCall({
    call,
    toolsContract,
  });
  const wrapper = playmeshWrappers[definition.name];
  if (definition.implementation === 'playmesh_wrapper') {
    if (!wrapper) {
      throw new PlaymeshAiEditorFunctionError(
        'playmesh_wrapper_unavailable'
      );
    }
    return wrapper({
      call,
      definition,
      project,
      selectedSceneName,
      runnerOptions,
      runOfficial: (options /*: PlaymeshAiRunnerOverrides */) =>
        runGDevelopEditorFunctionCall({
          project,
          functionCall,
          runnerOptions: { ...runnerOptions, ...options },
          runner,
        }),
    });
  }
  return runGDevelopEditorFunctionCall({
    project,
    functionCall,
    runnerOptions,
    runner,
  });
};
