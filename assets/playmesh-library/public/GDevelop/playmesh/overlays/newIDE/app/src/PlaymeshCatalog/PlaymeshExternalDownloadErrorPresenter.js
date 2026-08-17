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
