// @flow

import { convertBlobToDataURL } from '../Utils/BlobDownloader';
import { writePlaymeshAiExternalEditorOutput } from './PlaymeshAiExternalEditorResourceWriter';
import {
  runOfficialJfxrSound,
  runOfficialYarnDialogue,
} from './PlaymeshAiOfficialLocalEditorRunners';
/*::
import type {
  ExternalEditorBase64Resource,
  ExternalEditorOutput,
} from '../ResourcesList/ResourceExternalEditor';
import type {
  PlaymeshAiCall,
  PlaymeshAiObject,
} from './PlaymeshAiProtocol';
import type {
  PlaymeshAiEditorFunctionExecution,
  PlaymeshAiEditorFunctionWrapperContext,
  PlaymeshAiEditorFunctionWrappers,
} from './PlaymeshAiEditorFunctionTypes';

type PlaymeshAiJfxrYarnToolsOptions = {|
  beforeProjectMutation?: () => void,
  onFetchNewlyAddedResources?: () => Promise<void>,
  onNewResourcesAdded?: () => void,
  convertBlobToDataUrl?: typeof convertBlobToDataURL,
  writeExternalEditorOutput?: typeof writePlaymeshAiExternalEditorOutput,
  runJfxrSound?: typeof runOfficialJfxrSound,
  runYarnDialogue?: typeof runOfficialYarnDialogue,
|};
*/

export class PlaymeshAiJfxrYarnToolError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The bundled GDevelop resource editor tool could not be completed.');
    this.name = 'PlaymeshAiJfxrYarnToolError';
    this.code = code;
  }
}

const finished = ({
  call,
  output,
} /*: {|
  call: PlaymeshAiCall,
  output: PlaymeshAiObject,
|} */) /*: PlaymeshAiEditorFunctionExecution */ => ({
  result: {
    status: 'finished',
    call_id: call.callId,
    success: true,
    output,
    didModifyProject: true,
  },
  createdProject: null,
  createdSceneNames: [],
  transientObjectUrls: [],
});

const outputResourceName = ({
  project,
  resourceName,
  resourceKind,
} /*: {|
  project: gdProject,
  resourceName: string,
  resourceKind: 'audio' | 'json',
|} */) /*: ?string */ => {
  const resourcesManager = project.getResourcesManager();
  if (!resourcesManager.hasResource(resourceName)) return null;
  return resourcesManager.getResource(resourceName).getKind() === resourceKind
    ? resourceName
    : null;
};

const createSingleResourceExternalEditorOutput = ({
  project,
  resourceName,
  resourceKind,
  extension,
  dataUrl,
  externalEditorData,
} /*: {|
  project: gdProject,
  resourceName: string,
  resourceKind: 'audio' | 'json',
  extension: '.wav' | '.json',
  dataUrl: string,
  externalEditorData: ?any,
|} */) /*: ExternalEditorOutput */ => {
  const existingResourceName = outputResourceName({
    project,
    resourceName,
    resourceKind,
  });
  const resource /*: ExternalEditorBase64Resource */ = {
    ...(existingResourceName ? { name: existingResourceName } : {}),
    extension,
    dataUrl,
  };
  return {
    resources: [resource],
    baseNameForNewResources: resourceName,
    externalEditorData,
  };
};

export const createPlaymeshAiJfxrYarnTools = ({
  beforeProjectMutation = () => {},
  onFetchNewlyAddedResources = async () => {},
  onNewResourcesAdded = () => {},
  convertBlobToDataUrl = convertBlobToDataURL,
  writeExternalEditorOutput = writePlaymeshAiExternalEditorOutput,
  runJfxrSound = runOfficialJfxrSound,
  runYarnDialogue = runOfficialYarnDialogue,
} /*: PlaymeshAiJfxrYarnToolsOptions */ = {}) /*: PlaymeshAiEditorFunctionWrappers */ => ({
  create_or_update_jfxr_sound: async ({
    call,
    project,
  } /*: PlaymeshAiEditorFunctionWrapperContext */) /*: Promise<PlaymeshAiEditorFunctionExecution> */ => {
    const resourceName /*: string */ = (call.arguments.resource_name /*: any */);
    const serializedSound /*: string */ = (call.arguments
      .serialized_sound /*: any */);
    const jfxrOutput = await runJfxrSound(serializedSound);
    const externalEditorData = {
      data: jfxrOutput.serializedSound,
      name: resourceName,
    };
    const dataUrl = await convertBlobToDataUrl(
      new Blob([jfxrOutput.wavBytes], { type: 'audio/wav' })
    );
    beforeProjectMutation();
    const externalEditorOutput = createSingleResourceExternalEditorOutput({
      project,
      resourceName,
      resourceKind: 'audio',
      extension: '.wav',
      dataUrl,
      externalEditorData,
    });
    const editResult = await writeExternalEditorOutput({
      project,
      externalEditorOutput,
      resourceKind: 'audio',
      metadataKey: 'jfxr',
      resourceMetadata: externalEditorData,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    });
    return finished({
      call,
      output: {
        resource_name: editResult.resources[0].name,
        resource_kind: 'audio',
        serialized_sound: jfxrOutput.serializedSound,
      },
    });
  },

  create_or_update_yarn_dialogue: async ({
    call,
    project,
  } /*: PlaymeshAiEditorFunctionWrapperContext */) /*: Promise<PlaymeshAiEditorFunctionExecution> */ => {
    const resourceName /*: string */ = (call.arguments.resource_name /*: any */);
    const yarnJson /*: Array<Object> */ = (call.arguments.yarn_json /*: any */);
    const canonicalYarnJson = await runYarnDialogue(yarnJson);
    const dataUrl = await convertBlobToDataUrl(
      new Blob([canonicalYarnJson], { type: 'application/json' })
    );
    beforeProjectMutation();
    const externalEditorOutput = createSingleResourceExternalEditorOutput({
      project,
      resourceName,
      resourceKind: 'json',
      extension: '.json',
      dataUrl,
      externalEditorData: null,
    });
    const editResult = await writeExternalEditorOutput({
      project,
      externalEditorOutput,
      resourceKind: 'json',
      metadataKey: 'yarn',
      resourceMetadata: null,
      onFetchNewlyAddedResources,
      onNewResourcesAdded,
    });
    return finished({
      call,
      output: {
        resource_name: editResult.resources[0].name,
        resource_kind: 'json',
        yarn_json: JSON.parse(canonicalYarnJson),
      },
    });
  },
});

export default createPlaymeshAiJfxrYarnTools;
