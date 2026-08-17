// @flow

import { serializeToJSObject } from '../../Utils/Serializer';
import { archiveFiles } from '../../Utils/BrowserArchiver';
import { ensureGDevelopJsPlatformIsRegistered } from '../../PlaymeshShared/PlaymeshGDevelopPlatform';

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
 * Build the official portable GDevelop project archive.
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
    const textFiles /*: Array<TextFileDescriptor> */ = [
      {
        text: JSON.stringify(serializeImplementation(projectCopy)),
        filePath: 'game.json',
      },
    ];
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
