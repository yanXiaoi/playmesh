// @flow

import type { I18n as I18nType } from '@lingui/core';
import type {
  AssetSearchAndInstallOptions,
  AssetSearchAndInstallResult,
  EditorCallbacks,
  EditorFunctionCall,
  EditorFunctionCallResult,
  EventsGenerationOptions,
  EventsGenerationResult,
  RelatedAiRequestLastMessages,
  ResourceSearchAndInstallOptions,
  ResourceSearchAndInstallResult,
  ToolOptions,
} from '../EditorFunctions';
import type {
  InstancesOutsideEditorChanges,
  ObjectGroupsOutsideEditorChanges,
  ObjectsOutsideEditorChanges,
  ProjectItemRenamedOutsideEditorChanges,
  SceneEventsOutsideEditorChanges,
  WillDeleteObjectChanges,
  WillDeleteSceneChanges,
} from '../EditorFunctions/OutsideEditorChanges';
import type { EnsureExtensionInstalledOptions } from '../AiGeneration/UseEnsureExtensionInstalled';
import type { PlaymeshAiCall, PlaymeshAiObject } from './PlaymeshAiProtocol';

// Mirrors the non-project portion of the pinned official
// ProcessEditorFunctionCallsOptions. Keeping the boundary explicit avoids
// depending on deprecated Flow extraction utilities.
export type PlaymeshAiRunnerOptions = {|
  i18n: I18nType,
  editorCallbacks: EditorCallbacks,
  toolOptions: ToolOptions | null,
  relatedAiRequestId: string | null,
  getRelatedAiRequestLastMessages: () => RelatedAiRequestLastMessages,
  generateEvents: (
    options: EventsGenerationOptions
  ) => Promise<EventsGenerationResult>,
  onSceneEventsModifiedOutsideEditor: (
    changes: SceneEventsOutsideEditorChanges
  ) => void,
  onInstancesModifiedOutsideEditor: (
    changes: InstancesOutsideEditorChanges
  ) => void,
  onObjectsModifiedOutsideEditor: (
    changes: ObjectsOutsideEditorChanges
  ) => void,
  onObjectGroupsModifiedOutsideEditor: (
    changes: ObjectGroupsOutsideEditorChanges
  ) => void,
  onProjectItemRenamedOutsideEditor: (
    changes: ProjectItemRenamedOutsideEditorChanges
  ) => void,
  onWillDeleteScene: (changes: WillDeleteSceneChanges) => Promise<void>,
  onWillDeleteObject: (changes: WillDeleteObjectChanges) => void,
  ensureExtensionInstalled: (
    options: EnsureExtensionInstalledOptions
  ) => Promise<void>,
  onWillInstallExtension: (extensionNames: Array<string>) => void,
  onExtensionInstalled: (extensionNames: Array<string>) => void,
  searchAndInstallAsset: (
    options: AssetSearchAndInstallOptions
  ) => Promise<AssetSearchAndInstallResult>,
  searchAndInstallResources: (
    options: ResourceSearchAndInstallOptions
  ) => Promise<ResourceSearchAndInstallResult>,
  getAssetStoreTagForNewObject: (objectType: string) => string | null,
|};

export type PlaymeshAiRunnerOverrides = Partial<PlaymeshAiRunnerOptions>;

export type PlaymeshAiToolDefinition = {
  +name: string,
  +summary: string,
  +argumentsSchema: PlaymeshAiObject,
  +risk: string,
  +modifiesProject: boolean,
  +approvalRequired: boolean,
  +implementation: string,
  +officialImplementationName: string,
  +chatEnabled: boolean,
  +agentEnabled: boolean,
  +timeoutMs: number,
  +executionKind:
    | 'editor_function'
    | 'event_payload'
    | 'agent_resource_cas',
  +executionConfig: PlaymeshAiObject,
  ...,
};

export type PlaymeshAiToolsContract = {
  +tools: $ReadOnlyArray<PlaymeshAiToolDefinition>,
  ...,
};

export type PlaymeshAiEditorFunctionExecution = {|
  result: EditorFunctionCallResult,
  createdProject: ?gdProject,
  createdSceneNames: Array<string>,
  transientObjectUrls?: Array<string>,
|};

export type PlaymeshAiEditorFunctionCallMapping = {|
  definition: PlaymeshAiToolDefinition,
  functionCall: EditorFunctionCall,
|};

export type PlaymeshAiEditorFunctionWrapperContext = {|
  call: PlaymeshAiCall,
  definition: PlaymeshAiToolDefinition,
  project: gdProject,
  selectedSceneName: ?string,
  runnerOptions: PlaymeshAiRunnerOptions,
  runOfficial: PlaymeshAiRunnerOverrides =>
    Promise<PlaymeshAiEditorFunctionExecution>,
|};

export type PlaymeshAiEditorFunctionWrapper = (
  context: PlaymeshAiEditorFunctionWrapperContext
) => Promise<PlaymeshAiEditorFunctionExecution>;

export type PlaymeshAiEditorFunctionWrappers = {
  +[toolName: string]: ?PlaymeshAiEditorFunctionWrapper,
};
