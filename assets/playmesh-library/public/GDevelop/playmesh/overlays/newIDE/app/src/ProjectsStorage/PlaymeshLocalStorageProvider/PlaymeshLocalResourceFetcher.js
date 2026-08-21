// @flow

import {
  type FetchAllProjectResourcesOptions,
  type FetchAllProjectResourcesResult,
} from '../ResourceFetcher';
import { isBlobURL } from '../../ResourcesList/ResourceUtils';
import {
  downloadUrlsToBlobs,
  type ItemResult,
} from '../../Utils/BlobDownloader';
import {
  adoptPlaymeshLocalResourceBlob,
} from './PlaymeshProjectSerializer';
import { playmeshResourceObjectUrlRegistry } from './PlaymeshResourceObjectUrlRegistry';

type ResourceDownloadItem = {|
  url: string,
|};

/**
 * Playmesh implementation of GDevelop's ResourceFetcher seam. Official browser
 * resource editors first attach temporary Blob URLs, call this fetcher, then
 * revoke those temporary URLs. Replace them with registry-owned local URLs
 * before the official cleanup runs.
 */
export const fetchPlaymeshLocalResources = async ({
  project,
  fileMetadata,
  onProgress,
}: FetchAllProjectResourcesOptions): Promise<FetchAllProjectResourcesResult> => {
  const resourcesManager = project.getResourcesManager();
  const resourcesByDownloadItem: Map<
    ResourceDownloadItem,
    gdResource
  > = new Map();
  const resourcesToMaterialize: Array<ResourceDownloadItem> = resourcesManager
    .getAllResourceNames()
    .toJSArray()
    .map(resourceName => {
      const resource = resourcesManager.getResource(resourceName);
      const url = resource.getFile();
      // A save snapshot may already know the logical identity of a temporary
      // external-editor Blob URL. That does not make the URL safe to keep:
      // the official editor lifecycle will revoke it after this fetch step.
      // Only URLs actually owned by the live-resource registry are stable.
      if (!isBlobURL(url) || playmeshResourceObjectUrlRegistry.owns(url)) {
        return null;
      }
      const downloadItem: ResourceDownloadItem = { url };
      resourcesByDownloadItem.set(downloadItem, resource);
      return downloadItem;
    })
    .filter(Boolean);

  const downloadedResources: Array<
    ItemResult<ResourceDownloadItem>
  > = await downloadUrlsToBlobs({
    urlContainers: resourcesToMaterialize,
    onProgress,
  });
  const erroredResources = [];
  for (const { item, blob, error } of downloadedResources) {
    const resource = resourcesByDownloadItem.get(item);
    if (!resource) {
      erroredResources.push({
        resourceName: item.url,
        error: new Error('Unable to associate the downloaded local resource.'),
      });
      continue;
    }
    if (error || !blob) {
      erroredResources.push({
        resourceName: resource.getName(),
        error: error || new Error('Unable to read the local resource Blob.'),
      });
      continue;
    }
    try {
      adoptPlaymeshLocalResourceBlob({
        resource,
        blob,
        fileMetadata,
      });
    } catch (rawError) {
      erroredResources.push({
        resourceName: resource.getName(),
        error:
          rawError instanceof Error
            ? rawError
            : new Error('Unable to materialize the local resource Blob.'),
      });
    }
  }
  return { erroredResources };
};
