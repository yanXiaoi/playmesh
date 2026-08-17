// @flow

import {
  supportsPlaymeshStreamingUpload,
  uploadPlaymeshPackageBlob,
  uploadPlaymeshPackageStream,
} from '../ExportAndShare/PlaymeshPackageUploader';
import {
  assertPlaymeshPreviewResponse,
  buildPlaymeshPreviewUploadUrl,
  PlaymeshPreviewRunError,
} from './PlaymeshPreviewRunClient';

/*::
import type {
  PlaymeshPackageEntryProducer,
} from '../PlaymeshManifest/PlaymeshGDevelopManifestController';
import type {
  PlaymeshPackageProgress,
  PlaymeshStreamUploadOptions,
  PlaymeshUploadCommonOptions,
} from '../ExportAndShare/PlaymeshPackageUploader';
import type { PlaymeshPreviewResponse } from './PlaymeshPreviewRunClient';

type PlaymeshMixedRecord = { +[string]: mixed };
type PlaymeshGatewayPreviewUploadOptions = {|
  producer: PlaymeshPackageEntryProducer,
  gameId: string,
  signal?: ?AbortSignal,
  onProgress?: PlaymeshPackageProgress => void,
  confirmBlobFallback?: () => boolean | Promise<boolean>,
  supportsStreaming?: typeof supportsPlaymeshStreamingUpload,
  streamUploader?: typeof uploadPlaymeshPackageStream,
  blobUploader?: typeof uploadPlaymeshPackageBlob,
|};
*/

const mixedRecord = (
  value /*: mixed */
) /*: ?PlaymeshMixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value
    : null;

export const uploadPlaymeshGatewayPreview = async ({
  producer,
  gameId,
  signal,
  onProgress,
  confirmBlobFallback,
  supportsStreaming = supportsPlaymeshStreamingUpload,
  streamUploader = uploadPlaymeshPackageStream,
  blobUploader = uploadPlaymeshPackageBlob,
} /*: PlaymeshGatewayPreviewUploadOptions */) /*: Promise<PlaymeshPreviewResponse> */ => {
  const requestUrl = buildPlaymeshPreviewUploadUrl({ gameId });
  const responseValidator = (value /*: mixed */) /*: PlaymeshPreviewResponse */ =>
    assertPlaymeshPreviewResponse(value, gameId);
  const streamRequest /*: PlaymeshStreamUploadOptions<
    PlaymeshPreviewResponse
  > */ = {
    producer,
    expectedGameId: gameId,
    requestUrl,
    responseValidator,
    signal,
    onProgress,
  };
  const blobRequest /*: PlaymeshUploadCommonOptions<
    PlaymeshPreviewResponse
  > */ = {
    producer,
    expectedGameId: gameId,
    requestUrl,
    responseValidator,
    signal,
    onProgress,
  };

  if (supportsStreaming()) {
    try {
      const response = await streamUploader(streamRequest);
      return assertPlaymeshPreviewResponse(response, gameId);
    } catch (error) {
      const failure = mixedRecord(error);
      if (
        !(
          failure &&
          failure.safeToRetry === true &&
          failure.bytesProduced === 0
        )
      ) {
        throw error;
      }
    }
  }
  const accepted = confirmBlobFallback
    ? await confirmBlobFallback()
    : false;
  if (!accepted) {
    throw new PlaymeshPreviewRunError(
      'preview_blob_fallback_declined',
      '当前环境不支持流式传输预览数据，且未允许使用内存 ZIP。'
    );
  }
  const response = await blobUploader(blobRequest);
  return assertPlaymeshPreviewResponse(response, gameId);
};
