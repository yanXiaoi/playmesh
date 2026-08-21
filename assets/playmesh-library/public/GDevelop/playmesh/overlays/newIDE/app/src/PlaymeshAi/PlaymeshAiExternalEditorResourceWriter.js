// @flow

import {
  freeBlobsAndUpdateMetadata,
  patchExternalEditorMetadataWithResourcesNamesIfNecessary,
  saveBlobUrlsFromExternalEditorBase64Resources,
} from '../ResourcesList/ResourceExternalEditor';
import { triggerOnResourceExternallyChanged } from '../MainFrame/ResourcesWatcher';
/*::
import type {
  EditWithExternalEditorReturn,
  ExternalEditorOutput,
} from '../ResourcesList/ResourceExternalEditor';
import type { ResourceKind } from '../ResourcesList/ResourceSource';
*/

/**
 * The resource half of the official browser external-editor lifecycle, with
 * the editor's resource-management callback as the storage-provider seam.
 */
export const writePlaymeshAiExternalEditorOutput = async ({
  project,
  externalEditorOutput,
  resourceKind,
  metadataKey,
  resourceMetadata = null,
  onFetchNewlyAddedResources,
  onNewResourcesAdded,
} /*: {|
  project: gdProject,
  externalEditorOutput: ExternalEditorOutput,
  resourceKind: ResourceKind,
  metadataKey: string,
  resourceMetadata?: ?any,
  onFetchNewlyAddedResources: () => Promise<void>,
  onNewResourcesAdded: () => void,
|} */) /*: Promise<EditWithExternalEditorReturn> */ => {
  const modifiedResources = await saveBlobUrlsFromExternalEditorBase64Resources(
    {
      baseNameForNewResources:
        externalEditorOutput.baseNameForNewResources,
      project,
      resources: externalEditorOutput.resources,
      resourceKind,
    }
  );

  try {
    await onFetchNewlyAddedResources();
  } catch (error) {
    console.error(
      'An error happened while fetching the newly added resources:',
      error
    );
  }

  freeBlobsAndUpdateMetadata({
    modifiedResources,
    metadataKey,
    metadata: resourceMetadata,
  });

  const hasCreatedAnyResource = externalEditorOutput.resources.some(
    resource => !resource.name
  );
  if (hasCreatedAnyResource) {
    onNewResourcesAdded();
  }

  const modifiedResourceNames = modifiedResources.map(({ resource }) =>
    resource.getName()
  );
  patchExternalEditorMetadataWithResourcesNamesIfNecessary(
    modifiedResourceNames,
    externalEditorOutput.externalEditorData
  );
  modifiedResourceNames.forEach(resourceName => {
    if (!project.getResourcesManager().hasResource(resourceName)) return;
    const resource = project.getResourcesManager().getResource(resourceName);
    const file = resource.getFile();
    if (!file) return;
    triggerOnResourceExternallyChanged({ identifier: file });
  });

  return {
    resources: modifiedResources.map(({ resource, originalIndex }) => ({
      name: resource.getName(),
      originalIndex,
    })),
    newName: externalEditorOutput.baseNameForNewResources,
    newMetadata: {
      [metadataKey]: externalEditorOutput.externalEditorData,
    },
  };
};

export default writePlaymeshAiExternalEditorOutput;
