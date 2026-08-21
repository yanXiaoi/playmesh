// @flow

/*::
import type { ExternalEditorBase64Resource } from '../ResourcesList/ResourceExternalEditor';

export type PlaymeshAiPiskelImportKind = 'spritesheet' | 'gif';

export type PlaymeshAiPiskelImportOptions = {|
  kind: PlaymeshAiPiskelImportKind,
  dataUrl: string,
  name: string,
  frameWidth?: number,
  frameHeight?: number,
  frameOffsetX?: number,
  frameOffsetY?: number,
|};

export type PlaymeshAiPiskelOutput = {|
  resources: Array<ExternalEditorBase64Resource>,
  externalEditorData: Object,
  baseNameForNewResources: string,
  fps: number,
|};
*/

const PISKEL_EDITOR_URL = 'external/piskel/piskel-editor/index.html';
const PISKEL_EDITOR_LOAD_TIMEOUT = 10000;

export class PlaymeshAiPiskelRunnerError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The bundled Piskel editor could not import the staged image.');
    this.name = 'PlaymeshAiPiskelRunnerError';
    this.code = code;
  }
}

const loadPiskelImage = (
  piskelWindow /*: any */,
  dataUrl /*: string */
) /*: Promise<any> */ =>
  new Promise((resolve, reject) => {
    const image = new piskelWindow.Image();
    image.onload = () => resolve(image);
    image.onerror = () =>
      reject(new PlaymeshAiPiskelRunnerError('piskel_image_load_failed'));
    image.src = dataUrl;
  });

/**
 * Use the exact import service and frame renderer shipped by the locked
 * Piskel 5.5.228 bundle. In particular, spritesheet slicing and GIF decoding
 * stay inside Piskel instead of being reimplemented by Playmesh.
 */
export const importPiskelImageWithWindow = async (
  piskelWindow /*: any */,
  options /*: PlaymeshAiPiskelImportOptions */
) /*: Promise<PlaymeshAiPiskelOutput> */ => {
  const pskl = piskelWindow.pskl;
  const image = await loadPiskelImage(piskelWindow, options.dataUrl);
  const isGif = options.kind === 'gif';
  const piskel = await new Promise(resolve => {
    pskl.app.importService.newPiskelFromImage(
      image,
      {
        importType: isGif ? 'single' : 'sheet',
        name: options.name,
        smoothing: false,
        frameSizeX: isGif ? image.width : options.frameWidth,
        frameSizeY: isGif ? image.height : options.frameHeight,
        frameOffsetX: isGif ? 0 : options.frameOffsetX,
        frameOffsetY: isGif ? 0 : options.frameOffsetY,
      },
      resolve
    );
  });

  const piskelController = pskl.app.piskelController;
  piskelController.setPiskel(piskel, {});
  const layer = piskelController.getLayerAt(0);
  const resources /*: Array<ExternalEditorBase64Resource> */ = [];
  for (let index = 0; index < piskelController.getFrameCount(); index++) {
    // Keep the official Piskel/GDevelop output format: every flattened frame
    // is returned as a PNG data URL and is unnamed so GDevelop allocates it.
    const frame = layer.getFrameAt(index);
    const canvas = piskelController.renderFrameAt(index, true);
    resources.push({
      // This AI operation imports a new animation, matching the official
      // Piskel header's non-overwrite output branch.
      name: undefined,
      dataUrl: canvas.toDataURL('image/png'),
      localFilePath: undefined,
      originalIndex: frame.originalIndex,
      extension: '.png',
    });
  }

  let externalEditorData /*: any */ = {};
  const piskelData = piskelController.getPiskel();
  if (piskelData.layers.length > 1) {
    externalEditorData = {
      data: pskl.utils.serialization.Serializer.serialize(piskelData),
      resourceNames: resources.map(({ name }) => name),
      name: options.name,
    };
  }

  return {
    resources,
    externalEditorData,
    baseNameForNewResources: options.name,
    fps: piskelController.getFPS(),
  };
};

const waitForPiskelWindow = (
  frame /*: HTMLIFrameElement */
) /*: Promise<any> */ =>
  new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const readPiskelWindow = () => {
      const piskelWindow = frame.contentWindow;
      if (
        piskelWindow &&
        piskelWindow.pskl &&
        piskelWindow.pskl.app &&
        piskelWindow.pskl.app.importService &&
        piskelWindow.pskl.app.piskelController
      ) {
        resolve(piskelWindow);
        return;
      }
      if (Date.now() - startedAt >= PISKEL_EDITOR_LOAD_TIMEOUT) {
        reject(new PlaymeshAiPiskelRunnerError('piskel_editor_load_failed'));
        return;
      }
      setTimeout(readPiskelWindow, 100);
    };
    frame.addEventListener('load', readPiskelWindow, { once: true });
    frame.addEventListener(
      'error',
      () =>
        reject(
          new PlaymeshAiPiskelRunnerError('piskel_editor_load_failed')
        ),
      { once: true }
    );
    frame.src = PISKEL_EDITOR_URL;
  });

/** Run the bundled editor in a hidden same-origin frame without changing the
 * normal interactive Piskel entry point or popup lifecycle. */
export const runPlaymeshAiPiskelImport = async (
  options /*: PlaymeshAiPiskelImportOptions */
) /*: Promise<PlaymeshAiPiskelOutput> */ => {
  const body = document.body;
  if (!body) {
    throw new PlaymeshAiPiskelRunnerError(
      'piskel_editor_document_unavailable'
    );
  }
  const frame = document.createElement('iframe');
  frame.setAttribute('aria-hidden', 'true');
  frame.style.display = 'none';
  body.appendChild(frame);
  try {
    const piskelWindow = await waitForPiskelWindow(frame);
    return await importPiskelImageWithWindow(piskelWindow, options);
  } finally {
    frame.remove();
  }
};

export default runPlaymeshAiPiskelImport;
