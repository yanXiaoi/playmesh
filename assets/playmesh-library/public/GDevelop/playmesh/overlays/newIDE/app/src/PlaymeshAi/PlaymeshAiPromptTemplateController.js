// @flow

import {
  PLAYMESH_AI_PROMPT_TEMPLATE_MAX_BYTES,
  validatePlaymeshAiPromptTemplateContent,
} from './PlaymeshAiClient';

/*::
import type {
  PlaymeshAiClient,
  PlaymeshAiPromptTemplate,
} from './PlaymeshAiClient';
export type PlaymeshAiPromptTemplateMode = 'chat' | 'agent';
export type PlaymeshAiPromptTemplateStatus =
  | 'idle'
  | 'loading'
  | 'ready'
  | 'saving'
  | 'resetting'
  | 'load_failed'
  | 'save_failed'
  | 'reset_failed';
export type PlaymeshAiPromptTemplateValidationError =
  | 'empty'
  | 'too_large';
export type PlaymeshAiPromptTemplateState = {|
  +status: PlaymeshAiPromptTemplateStatus,
  +targetLocale: string,
  +resolvedLocale: string,
  +selectedMode: PlaymeshAiPromptTemplateMode,
  +templates: $ReadOnlyArray<PlaymeshAiPromptTemplate>,
  +content: string,
  +contentBytes: number,
  +maxContentBytes: number,
  +customized: boolean,
  +dirty: boolean,
  +validationError: ?PlaymeshAiPromptTemplateValidationError,
  +errorCode: ?string,
|};

type Options = {|
  client: PlaymeshAiClient,
|};
type Listener = (state: PlaymeshAiPromptTemplateState) => void;
*/

const initialState = () /*: PlaymeshAiPromptTemplateState */ => ({
  status: 'idle',
  targetLocale: '',
  resolvedLocale: '',
  selectedMode: 'chat',
  templates: Object.freeze([]),
  content: '',
  contentBytes: 0,
  maxContentBytes: PLAYMESH_AI_PROMPT_TEMPLATE_MAX_BYTES,
  customized: false,
  dirty: false,
  validationError: null,
  errorCode: null,
});

const safeErrorCode = (error /*: mixed */) /*: string */ =>
  error && typeof error === 'object' && typeof error.code === 'string'
    ? error.code
    : 'prompt_templates_unavailable';

const draftKey = (
  locale /*: string */,
  templateId /*: string */
) /*: string */ =>
  `${locale}\u0000${templateId}`;

const templateForMode = (
  templates /*: $ReadOnlyArray<PlaymeshAiPromptTemplate> */,
  mode /*: PlaymeshAiPromptTemplateMode */
) /*: ?PlaymeshAiPromptTemplate */ =>
  templates.find(template => template.mode === mode);

const contentState = (
  content /*: string */,
  template /*: PlaymeshAiPromptTemplate */
) /*: Partial<PlaymeshAiPromptTemplateState> */ => {
  const validation = validatePlaymeshAiPromptTemplateContent(content);
  return {
    content,
    contentBytes: validation.bytes,
    customized: template.customized,
    dirty: content !== template.content,
    validationError: validation.error,
  };
};

/**
 * 提示词覆盖是全局且按语言隔离的。控制器会在临时语言切换时保留当前内存草稿，
 * 但不会把草稿写入浏览器存储，也不会让提示词网络失败影响工程编辑状态。
 */
export class PlaymeshAiPromptTemplateController {
  /*::
  _client: PlaymeshAiClient;
  _state: PlaymeshAiPromptTemplateState;
  _listeners: Set<Listener>;
  _drafts: Map<string, string>;
  _requestGeneration: number;
  _abortController: ?AbortController;
  _disposed: boolean;
  */

  constructor({ client } /*: Options */) {
    this._client = client;
    this._state = initialState();
    this._listeners = new Set();
    this._drafts = new Map();
    this._requestGeneration = 0;
    this._abortController = null;
    this._disposed = false;
  }

  getState() /*: PlaymeshAiPromptTemplateState */ {
    return this._state;
  }

  subscribe(listener /*: Listener */) /*: () => void */ {
    this._listeners.add(listener);
    listener(this._state);
    return () => {
      this._listeners.delete(listener);
    };
  }

  _setState(next /*: Partial<PlaymeshAiPromptTemplateState> */) /*: void */ {
    if (this._disposed) return;
    this._state = Object.freeze({ ...this._state, ...next });
    this._listeners.forEach(listener => listener(this._state));
  }

  _rememberCurrentDraft() /*: void */ {
    const template = templateForMode(
      this._state.templates,
      this._state.selectedMode
    );
    if (!template || !this._state.resolvedLocale) return;
    const key = draftKey(this._state.resolvedLocale, template.id);
    if (this._state.dirty) this._drafts.set(key, this._state.content);
    else this._drafts.delete(key);
  }

  _selectContent(
    templates /*: $ReadOnlyArray<PlaymeshAiPromptTemplate> */,
    mode /*: PlaymeshAiPromptTemplateMode */,
    locale /*: string */
  ) /*: Partial<PlaymeshAiPromptTemplateState> */ {
    const template = templateForMode(templates, mode);
    if (!template) {
      return {
        content: '',
        contentBytes: 0,
        customized: false,
        dirty: false,
        validationError: null,
      };
    }
    const key = draftKey(locale, template.id);
    return contentState(
      this._drafts.has(key) ? this._drafts.get(key) || '' : template.content,
      template
    );
  }

  async load(
    locale /*: string */
  ) /*: Promise<PlaymeshAiPromptTemplateState> */ {
    this._rememberCurrentDraft();
    const generation = ++this._requestGeneration;
    if (this._abortController) this._abortController.abort();
    const abortController = new AbortController();
    this._abortController = abortController;
    this._setState({
      status: 'loading',
      targetLocale: locale,
      resolvedLocale: '',
      templates: Object.freeze([]),
      content: '',
      contentBytes: 0,
      customized: false,
      dirty: false,
      validationError: null,
      errorCode: null,
    });
    try {
      const templates = await this._client.listPromptTemplates(
        locale,
        abortController.signal
      );
      if (this._disposed || generation !== this._requestGeneration) {
        return this._state;
      }
      const resolvedLocale = templates[0].locale;
      const frozenTemplates = Object.freeze([...templates]);
      this._setState({
        status: 'ready',
        targetLocale: locale,
        resolvedLocale,
        templates: frozenTemplates,
        ...this._selectContent(
          frozenTemplates,
          this._state.selectedMode,
          resolvedLocale
        ),
      });
    } catch (error) {
      if (this._disposed || generation !== this._requestGeneration) {
        return this._state;
      }
      this._setState({
        status: 'load_failed',
        errorCode: safeErrorCode(error),
      });
    } finally {
      if (generation === this._requestGeneration) {
        this._abortController = null;
      }
    }
    return this._state;
  }

  selectMode(mode /*: PlaymeshAiPromptTemplateMode */) /*: void */ {
    if (mode !== 'chat' && mode !== 'agent') return;
    if (['loading', 'saving', 'resetting'].includes(this._state.status)) return;
    this._rememberCurrentDraft();
    this._setState({
      status: 'ready',
      selectedMode: mode,
      errorCode: null,
      ...this._selectContent(
        this._state.templates,
        mode,
        this._state.resolvedLocale
      ),
    });
  }

  updateContent(content /*: string */) /*: void */ {
    const template = templateForMode(
      this._state.templates,
      this._state.selectedMode
    );
    if (!template || typeof content !== 'string') return;
    const next = contentState(content, template);
    this._setState({ ...next, status: 'ready', errorCode: null });
    const key = draftKey(this._state.resolvedLocale, template.id);
    if (next.dirty) this._drafts.set(key, content);
    else this._drafts.delete(key);
  }

  async save() /*: Promise<PlaymeshAiPromptTemplateState> */ {
    const template = templateForMode(
      this._state.templates,
      this._state.selectedMode
    );
    const validation = validatePlaymeshAiPromptTemplateContent(
      this._state.content
    );
    if (
      ['loading', 'saving', 'resetting'].includes(this._state.status) ||
      !template ||
      !this._state.dirty ||
      validation.error
    ) {
      this._setState({ validationError: validation.error });
      return this._state;
    }
    const generation = ++this._requestGeneration;
    if (this._abortController) this._abortController.abort();
    const abortController = new AbortController();
    this._abortController = abortController;
    this._setState({ status: 'saving', errorCode: null });
    try {
      const saved = await this._client.savePromptTemplate(
        template.id,
        this._state.content,
        this._state.resolvedLocale,
        abortController.signal
      );
      if (this._disposed || generation !== this._requestGeneration) {
        return this._state;
      }
      const templates = Object.freeze(
        this._state.templates.map(item =>
          item.id === saved.id ? saved : item
        )
      );
      this._drafts.delete(draftKey(saved.locale, saved.id));
      this._setState({
        status: 'ready',
        resolvedLocale: saved.locale,
        templates,
        errorCode: null,
        ...contentState(saved.content, saved),
      });
    } catch (error) {
      if (!this._disposed && generation === this._requestGeneration) {
        this._setState({
          status: 'save_failed',
          errorCode: safeErrorCode(error),
        });
      }
    } finally {
      if (generation === this._requestGeneration) {
        this._abortController = null;
      }
    }
    return this._state;
  }

  async reset() /*: Promise<PlaymeshAiPromptTemplateState> */ {
    const template = templateForMode(
      this._state.templates,
      this._state.selectedMode
    );
    if (
      ['loading', 'saving', 'resetting'].includes(this._state.status) ||
      !template
    ) {
      return this._state;
    }
    const generation = ++this._requestGeneration;
    if (this._abortController) this._abortController.abort();
    const abortController = new AbortController();
    this._abortController = abortController;
    this._setState({ status: 'resetting', errorCode: null });
    try {
      const restored = await this._client.resetPromptTemplate(
        template.id,
        this._state.resolvedLocale,
        abortController.signal
      );
      if (this._disposed || generation !== this._requestGeneration) {
        return this._state;
      }
      const templates = Object.freeze(
        this._state.templates.map(item =>
          item.id === restored.id ? restored : item
        )
      );
      this._drafts.delete(draftKey(restored.locale, restored.id));
      this._setState({
        status: 'ready',
        resolvedLocale: restored.locale,
        templates,
        errorCode: null,
        ...contentState(restored.content, restored),
      });
    } catch (error) {
      if (!this._disposed && generation === this._requestGeneration) {
        this._setState({
          status: 'reset_failed',
          errorCode: safeErrorCode(error),
        });
      }
    } finally {
      if (generation === this._requestGeneration) {
        this._abortController = null;
      }
    }
    return this._state;
  }

  dispose() /*: void */ {
    this._disposed = true;
    this._requestGeneration++;
    if (this._abortController) this._abortController.abort();
    this._abortController = null;
    this._listeners.clear();
    this._drafts.clear();
  }
}

export default PlaymeshAiPromptTemplateController;
