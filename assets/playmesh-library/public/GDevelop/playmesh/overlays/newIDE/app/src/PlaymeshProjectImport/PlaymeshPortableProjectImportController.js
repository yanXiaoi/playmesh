// @flow

import { importPlaymeshPortableProject } from './PlaymeshPortableProjectImporter';
import { generateCopiedGDevelopGameId } from '../PlaymeshManifest/PlaymeshGDevelopManifestController';

/*::
type ImportResult = {
  status: string,
  [string]: mixed,
};

type ImportOptions = {|
  archiveBlob?: Blob,
  projectJsonBlob?: Blob,
  importProject?: Object => Promise<ImportResult>,
  generatePackageName?: () => string,
  confirmCopy: ({|
    reason: string,
    sourcePackageName: string,
    suggestedPackageName: string,
  |}) => boolean | Promise<boolean>,
|};
*/

export class PlaymeshPortableProjectImportControllerError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshPortableProjectImportControllerError';
    this.code = code;
  }
}

const requireImportResult = (value /*: mixed */) /*: ImportResult */ => {
  const result /*: any */ = value;
  if (
    !result ||
    typeof result !== 'object' ||
    typeof result.status !== 'string'
  ) {
    throw new PlaymeshPortableProjectImportControllerError(
      'invalid_import_result',
      'GDevelop 导入返回了无效结果。'
    );
  }
  return (result /*: ImportResult */);
};

export const importPortableProjectWithCopyDecision = async (
  {
    archiveBlob,
    projectJsonBlob,
    importProject = importPlaymeshPortableProject,
    generatePackageName = generateCopiedGDevelopGameId,
    confirmCopy,
  } /*: ImportOptions */
) /*: Promise<ImportResult> */ => {
  if (
    typeof importProject !== 'function' ||
    typeof confirmCopy !== 'function'
  ) {
    throw new PlaymeshPortableProjectImportControllerError(
      'invalid_import_dependencies',
      'GDevelop 导入控制器依赖不完整。'
    );
  }
  const source = projectJsonBlob ? { projectJsonBlob } : { archiveBlob };
  const initialResult = requireImportResult(
    await importProject(source)
  );
  if (initialResult.status !== 'needsNewPackageName') return initialResult;

  const suggestedPackageName = String(generatePackageName() || '').trim();
  if (!suggestedPackageName) {
    throw new PlaymeshPortableProjectImportControllerError(
      'package_name_generation_failed',
      '无法生成 GDevelop 导入副本的游戏标识。'
    );
  }
  const sourcePackageName = String(
    initialResult.sourcePackageName || initialResult.packageName || ''
  );
  const accepted = await confirmCopy({
    reason: String(initialResult.reason || 'identity_conflict'),
    sourcePackageName,
    suggestedPackageName,
  });
  if (!accepted) return { status: 'cancelled' };

  const copiedResult = requireImportResult(
    await importProject({
      ...source,
      packageName: suggestedPackageName,
      identityMode: 'copy',
    })
  );
  if (copiedResult.status === 'needsNewPackageName') {
    throw new PlaymeshPortableProjectImportControllerError(
      'copy_identity_conflict',
      '新生成的 GDevelop 游戏标识仍发生冲突，请重新导入。'
    );
  }
  return copiedResult;
};
