// @flow

import { serializeToJSObject } from '../../Utils/Serializer';
import { archiveFiles } from '../../Utils/BrowserArchiver';
import { ensureGDevelopJsPlatformIsRegistered } from '../../PlaymeshShared/PlaymeshGDevelopPlatform';
import {
  formatPlaymeshProjectFile,
  splitPlaymeshProject,
} from '../PlaymeshLocalStorageProvider/PlaymeshProjectFiles';

/*::
import type {
  BlobFileDescriptor,
  TextFileDescriptor,
} from '../../Utils/BrowserArchiver';
type DownloadResources = ({|
  project: gdProject,
  onAddBlobFile: (blobFile: BlobFileDescriptor) => void,
|}) => Promise<mixed>;

type Options = {|
  project: gdProject,
  downloadResources: DownloadResources,
  gdImplementation?: libGDevelop,
  archiveImplementation?: typeof archiveFiles,
  serializeImplementation?: typeof serializeToJSObject,
|};
*/

/**
 * Build a source archive using the official desktop folder-project layout.
 *
 * Platform registration belongs before the clone/unserialize boundary, not in
 * individual button handlers. Keeping the whole clone/download/archive chain
 * here also makes every consumer share cleanup and ordering guarantees.
 */
export const createPlaymeshDownloadProjectArchive = async ({
  project,
  downloadResources,
  gdImplementation = global.gd,
  archiveImplementation = archiveFiles,
  serializeImplementation = serializeToJSObject,
} /*: Options */) /*: Promise<Blob> */ => {
  ensureGDevelopJsPlatformIsRegistered(gdImplementation);

  const projectCopy = gdImplementation.ProjectHelper.createNewGDJSProject();
  const serializedProject = new gdImplementation.SerializerElement();
  try {
    project.serializeTo(serializedProject);
    projectCopy.unserializeFrom(serializedProject);
  } catch (error) {
    projectCopy.delete();
    throw error;
  } finally {
    serializedProject.delete();
  }

  try {
    const blobFiles /*: Array<BlobFileDescriptor> */ = [];
    await downloadResources({
      project: projectCopy,
      onAddBlobFile: blobFile => {
        blobFiles.push(blobFile);
      },
    });
    projectCopy.setFolderProject(true);
    const textFiles /*: Array<TextFileDescriptor> */ = splitPlaymeshProject(
      serializeImplementation(projectCopy)
    ).map(file => ({
      text: formatPlaymeshProjectFile(file.content),
      filePath: file.path,
    }));
    return await archiveImplementation({
      textFiles,
      blobFiles,
      basePath: '/',
      onProgress: () => {},
    });
  } finally {
    projectCopy.delete();
  }
};
