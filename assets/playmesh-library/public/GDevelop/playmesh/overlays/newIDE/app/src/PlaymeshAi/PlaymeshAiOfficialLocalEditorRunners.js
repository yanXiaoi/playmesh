// @flow

/*::
export type PlaymeshAiJfxrOutput = {|
  serializedSound: string,
  wavBytes: Uint8Array,
|};

type LoadedOfficialEditor<T> = {|
  editor: T,
  dispose: () => void,
|};
*/

const OFFICIAL_EDITOR_LOAD_TIMEOUT_MS = 10000;

export class PlaymeshAiOfficialLocalEditorError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The bundled GDevelop local editor could not be executed.');
    this.name = 'PlaymeshAiOfficialLocalEditorError';
    this.code = code;
  }
}

const loadOfficialEditor = /*:: <T> */ ({
  eventName,
  editorPath,
  matchesEditor,
  prepareEditor,
} /*: {|
  eventName: string,
  editorPath: string,
  matchesEditor: (any, HTMLIFrameElement) => boolean,
  prepareEditor: (any, HTMLIFrameElement) => T,
|} */) /*: Promise<LoadedOfficialEditor<T>> */ =>
  new Promise((resolve, reject) => {
    const body = document.body;
    if (!body) {
      reject(
        new PlaymeshAiOfficialLocalEditorError(
          'official_local_editor_document_unavailable'
        )
      );
      return;
    }
    const editorFrame = document.createElement('iframe');
    editorFrame.hidden = true;
    editorFrame.tabIndex = -1;
    editorFrame.setAttribute('aria-hidden', 'true');

    let settled = false;
    const dispose = () => {
      if (editorFrame.parentNode) editorFrame.parentNode.removeChild(editorFrame);
    };
    const timeoutId = setTimeout(() => {
      if (settled) return;
      settled = true;
      window.removeEventListener(eventName, onReady);
      dispose();
      reject(
        new PlaymeshAiOfficialLocalEditorError(
          'official_local_editor_load_failed'
        )
      );
    }, OFFICIAL_EDITOR_LOAD_TIMEOUT_MS);
    const onReady = (event /*: any */) => {
      if (settled || !matchesEditor(event, editorFrame)) return;
      settled = true;
      clearTimeout(timeoutId);
      window.removeEventListener(eventName, onReady);
      try {
        // Run the official input method synchronously while the embedded
        // editor is dispatching its ready signal. In Jfxr this lets the
        // initial Angular digest build the official synth from this sound.
        const editor = prepareEditor(event, editorFrame);
        resolve({ editor, dispose });
      } catch (error) {
        dispose();
        reject(error);
      }
    };

    window.addEventListener(eventName, onReady);
    editorFrame.src = editorPath;
    body.appendChild(editorFrame);
  });

/**
 * Invoke the same Jfxr controller calls used by GDevelop 5.6.276's bundled
 * jfxr-main.js bridge: Sound.parse, Sound.serialize and synth.run.
 */
export const runOfficialJfxrSound = async (
  serializedSound /*: string */
) /*: Promise<PlaymeshAiJfxrOutput> */ => {
  const loaded = await loadOfficialEditor({
    eventName: 'jfxrReady',
    editorPath: 'external/jfxr/jfxr-editor/index.html',
    matchesEditor: (event, editorFrame) =>
      !!(
        event.mainCtrl &&
        typeof event.mainCtrl.getSound === 'function' &&
        editorFrame.contentWindow &&
        event.mainCtrl.getSound instanceof editorFrame.contentWindow.Function
      ),
    prepareEditor: event => {
      const jfxr = event.mainCtrl;
      jfxr.autoplay = false;
      // The ready event is dispatched before Angular's first digest. On a
      // cold editor, run the exact action used by the pinned MainCtrl watcher
      // so the input sound exists before that digest builds the synth.
      if (!jfxr.getSound()) {
        jfxr.applyPreset(jfxr.presets[0]);
      }
      jfxr.getSound().parse(serializedSound);
      return jfxr;
    },
  });
  try {
    const clip = await loaded.editor.synth.run();
    return {
      serializedSound: loaded.editor.getSound().serialize(),
      wavBytes: clip.toWavBytes(),
    };
  } finally {
    loaded.dispose();
  }
};

/**
 * Invoke the same Yarn data API calls used by GDevelop 5.6.276's bundled
 * yarn-main.js bridge: loadData and getSaveData with the JSON format.
 */
export const runOfficialYarnDialogue = async (
  yarnJson /*: Array<Object> */
) /*: Promise<string> */ => {
  const loaded = await loadOfficialEditor({
    eventName: 'yarnReady',
    editorPath: 'external/yarn/yarn-editor/index.html',
    matchesEditor: (event, editorFrame) =>
      event.document === editorFrame.contentDocument,
    prepareEditor: event => {
      const yarnData = event.data;
      yarnData.restoreFromLocalStorage(false);
      yarnData.editingPath('');
      yarnData.editingType('json');
      yarnData.loadData(JSON.stringify(yarnJson), 'json', true);
      return yarnData;
    },
  });
  try {
    return loaded.editor.getSaveData('json');
  } finally {
    loaded.dispose();
  }
};
