// @flow

import { showErrorBox } from '../UI/Messages/MessageBox';
import { getPlaymeshMessage } from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';
import {
  formatPlaymeshExternalDownloadFailure,
  logPlaymeshExternalDownloadFailure,
  normalizePlaymeshExternalDownloadFailure,
  type PlaymeshExternalDownloadFailure,
} from './PlaymeshExternalDownloadDiagnostic';
import type {
  ExtensionShortHeader,
  SerializedExtension,
} from '../Utils/GDevelopServices/Extension';

export const presentPlaymeshExternalDownloadFailure = ({
  rawError,
  targetUrl = '',
  stage = 'external_download',
  operation = 'gdevelop.catalog.artifact.acquire',
  errorId = 'playmesh-external-download-error',
  message = null,
}: {|
  rawError: mixed,
  targetUrl?: mixed,
  stage?: string,
  operation?: string,
  errorId?: string,
  message?: ?string,
|}): PlaymeshExternalDownloadFailure => {
  const failure = normalizePlaymeshExternalDownloadFailure({
    rawError,
    targetUrl,
    stage,
    operation,
  });
  const formattedMessage = formatPlaymeshExternalDownloadFailure(
    typeof message === 'string' && message
      ? message
      : getPlaymeshMessage(playmeshMessages.externalDownloadFailed),
    failure
  );
  logPlaymeshExternalDownloadFailure(failure);
  // Never pass the original error to the official analytics hook: a transport
  // error can contain a signed URL or credentials. The synthetic error and the
  // visible message contain only the sanitized diagnostic contract.
  showErrorBox({
    message: formattedMessage,
    rawError: new Error(
      `${failure.code}:${failure.reason}:${failure.requestId}`
    ),
    errorId,
    doNotReport: true,
  });
  return failure;
};

/**
 * Own exactly the external artifact acquisition seam. The caller continues
 * with GDevelop's official deserialization, project insertion, registry load
 * and callbacks after this Promise resolves; none of those steps are caught
 * or reclassified here.
 */
export const acquirePlaymeshExtensionArtifacts = async ({
  extensionShortHeaders,
  acquire,
  reason,
}: {|
  extensionShortHeaders: Array<ExtensionShortHeader>,
  acquire: ExtensionShortHeader => Promise<SerializedExtension>,
  reason: 'asset' | 'extension' | 'behavior',
|}): Promise<Array<SerializedExtension>> => {
  try {
    return await Promise.all(extensionShortHeaders.map(acquire));
  } catch (rawError) {
    // Asset installation already owns its aggregate user-facing error. The
    // other two catalog entry points need one sanitized download diagnostic.
    if (reason !== 'asset') {
      presentPlaymeshExternalDownloadFailure({
        rawError,
        stage:
          reason === 'behavior'
            ? 'behavior_extension_download'
            : 'extension_download',
        operation: 'gdevelop.catalog.artifact.acquire',
        errorId:
          reason === 'behavior'
            ? 'download-behavior-extension-error'
            : 'download-extension-error',
      });
    }
    throw rawError;
  }
};
