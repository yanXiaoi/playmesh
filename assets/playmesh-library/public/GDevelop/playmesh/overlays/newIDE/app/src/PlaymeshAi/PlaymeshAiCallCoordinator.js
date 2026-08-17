// @flow

import { validatePlaymeshAiCall } from './PlaymeshAiProtocol';

/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiObject,
} from './PlaymeshAiProtocol';

type PlaymeshAiCallListClient = {
  listCalls: (
    gameId: string,
    sessionId: string,
    afterSequence: number,
    signal: ?AbortSignal
  ) => Promise<Array<PlaymeshAiCall>>,
};

type PlaymeshAiCallCoordinatorOptions = {|
  client: PlaymeshAiCallListClient,
  gameId: string,
  sessionId: string,
  onCallsChanged: Array<PlaymeshAiCall> => mixed,
  onError?: mixed => mixed,
  EventSourceConstructor?: ?typeof EventSource,
  setIntervalImplementation?: (() => mixed, number) => IntervalID,
  clearIntervalImplementation?: IntervalID => mixed,
  pollIntervalMs?: number,
|};
*/

const DEFAULT_POLL_INTERVAL_MS = 1500;
// Chromium/WebView native timer functions can reject a foreign receiver with
// `TypeError: Illegal invocation`. Keep the native call on `global` instead of
// storing it directly and later invoking it as a coordinator instance method.
const defaultSetInterval = (
  callback /*: () => mixed */,
  intervalMs /*: number */
) /*: IntervalID */ =>
  global.setInterval(callback, intervalMs);
const defaultClearInterval = (intervalId /*: IntervalID */) /*: void */ =>
  global.clearInterval(intervalId);
const WAKE_EVENT_TYPES /*: Set<string> */ = new Set([
  'gdevelop.ai.session.updated',
  'gdevelop.ai.turn.created',
  'gdevelop.ai.call.updated',
]);
const WAKE_EVENT_KEYS /*: Set<string> */ = new Set([
  'type',
  'gameId',
  'editorSessionId',
  'sequence',
  'turnId',
  'callId',
  'state',
]);

const eventStreamUrl = (
  gameId /*: string */,
  sessionId /*: string */,
  afterSequence /*: number */
) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    gameId
  )}/ai/editor-sessions/${encodeURIComponent(
    sessionId
  )}/events?afterSequence=${encodeURIComponent(String(afterSequence))}`;

const readWakeIdentity = ({
  expectedType,
  event,
  payload,
  gameId,
  sessionId,
} /*: {|
  expectedType: string,
  event: MessageEvent,
  payload: PlaymeshAiObject,
  gameId: string,
  sessionId: string,
|} */) /*: ?{| key: string, sequence: number, state: string |} */ => {
  if (
    event.type !== expectedType ||
    payload.type !== expectedType ||
    payload.gameId !== gameId ||
    payload.editorSessionId !== sessionId ||
    !Number.isSafeInteger(payload.sequence) ||
    Number(payload.sequence) < 0 ||
    Object.keys(payload).some(key => !WAKE_EVENT_KEYS.has(key))
  ) {
    return null;
  }
  const sequence = Number(payload.sequence);
  if (expectedType === 'gdevelop.ai.call.updated') {
    if (
      typeof payload.callId !== 'string' ||
      payload.callId.length === 0 ||
      typeof payload.state !== 'string' ||
      payload.state.length === 0
    ) {
      return null;
    }
    return {
      key: `call:${payload.callId}`,
      sequence,
      state: payload.state,
    };
  }
  if (expectedType === 'gdevelop.ai.turn.created') {
    if (typeof payload.turnId !== 'string' || payload.turnId.length === 0) {
      return null;
    }
    return { key: `turn:${payload.turnId}`, sequence, state: 'created' };
  }
  const state = payload.state;
  if (state != null && typeof state !== 'string') return null;
  return {
    key: `session:${sessionId}`,
    sequence,
    state: typeof state === 'string' ? state : 'updated',
  };
};

/**
 * SSE is only a low-latency wake-up hint. The incrementally polled call list is
 * the canonical state, so reconnects and dropped events cannot lose changes.
 */
export class PlaymeshAiCallCoordinator {
  /*::
  client: PlaymeshAiCallListClient;
  gameId: string;
  sessionId: string;
  onCallsChanged: Array<PlaymeshAiCall> => mixed;
  onError: mixed => mixed;
  EventSourceConstructor: ?typeof EventSource;
  setIntervalImplementation: (() => mixed, number) => IntervalID;
  clearIntervalImplementation: IntervalID => mixed;
  pollIntervalMs: number;
  callsById: Map<string, PlaymeshAiCall>;
  afterSequence: number;
  pollPromise: ?Promise<Array<PlaymeshAiCall>>;
  pollAgain: boolean;
  intervalId: ?IntervalID;
  eventSource: ?EventSource;
  abortController: ?AbortController;
  eventListeners: Map<string, EventListener>;
  wakeEventsByKey: Map<string, {| sequence: number, state: string |}>;
  wakeAfterSequence: number;
  runEpoch: number;
  stopped: boolean;
  */

  constructor({
    client,
    gameId,
    sessionId,
    onCallsChanged,
    onError = () => {},
    EventSourceConstructor = global.EventSource,
    setIntervalImplementation = defaultSetInterval,
    clearIntervalImplementation = defaultClearInterval,
    pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  } /*: PlaymeshAiCallCoordinatorOptions */) {
    this.client = client;
    this.gameId = gameId;
    this.sessionId = sessionId;
    this.onCallsChanged = onCallsChanged;
    this.onError = onError;
    this.EventSourceConstructor = EventSourceConstructor;
    this.setIntervalImplementation = setIntervalImplementation;
    this.clearIntervalImplementation = clearIntervalImplementation;
    this.pollIntervalMs = pollIntervalMs;
    this.callsById = new Map();
    this.afterSequence = 0;
    this.pollPromise = null;
    this.pollAgain = false;
    this.intervalId = null;
    this.eventSource = null;
    this.abortController = null;
    this.eventListeners = new Map();
    this.wakeEventsByKey = new Map();
    this.wakeAfterSequence = 0;
    this.runEpoch = 0;
    this.stopped = true;
  }

  getCalls() /*: Array<PlaymeshAiCall> */ {
    return [...this.callsById.values()].sort(
      (left, right) => left.sequence - right.sequence
    );
  }

  async pollNow() /*: Promise<Array<PlaymeshAiCall>> */ {
    if (this.stopped) return this.getCalls();
    const currentPoll = this.pollPromise;
    if (currentPoll) {
      this.pollAgain = true;
      return currentPoll;
    }
    const runEpoch = this.runEpoch;
    const signal = this.abortController
      ? this.abortController.signal
      : undefined;
    const pollPromise = (async () /*: Promise<Array<PlaymeshAiCall>> */ => {
      do {
        this.pollAgain = false;
        const calls = await this.client.listCalls(
          this.gameId,
          this.sessionId,
          this.afterSequence,
          signal
        );
        if (this.stopped || runEpoch !== this.runEpoch) {
          return this.getCalls();
        }
        let changed = false;
        calls.forEach(rawCall => {
          let call;
          try {
            call = validatePlaymeshAiCall(rawCall);
          } catch (_) {
            return;
          }
          if (call.editorSessionId !== this.sessionId) return;
          const previous = this.callsById.get(call.callId);
          if (previous && call.sequence <= previous.sequence) return;
          this.callsById.set(call.callId, call);
          this.afterSequence = Math.max(this.afterSequence, call.sequence);
          changed = true;
        });
        if (changed) this.onCallsChanged(this.getCalls());
      } while (this.pollAgain && !this.stopped);
      return this.getCalls();
    })();
    this.pollPromise = pollPromise;
    try {
      return await pollPromise;
    } catch (error) {
      if (
        !this.stopped &&
        runEpoch === this.runEpoch &&
        !(signal && signal.aborted)
      ) {
        this.onError(error);
      }
      return this.getCalls();
    } finally {
      this.pollPromise = null;
    }
  }

  _onEvent = (
    expectedType /*: string */,
    event /*: MessageEvent */
  ) /*: void */ => {
    const data = event.data;
    if (typeof data !== 'string') return;
    let payload /*: mixed */;
    try {
      payload = JSON.parse(data);
    } catch (_) {
      return;
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return;
    }
    const wakePayload /*: PlaymeshAiObject */ = payload;
    if (!WAKE_EVENT_TYPES.has(expectedType)) return;
    const identity = readWakeIdentity({
      expectedType,
      event,
      payload: wakePayload,
      gameId: this.gameId,
      sessionId: this.sessionId,
    });
    if (!identity) return;
    if (identity.sequence <= this.wakeAfterSequence) return;
    const previous = this.wakeEventsByKey.get(identity.key);
    // A canonical state transition always advances sequence. Equal sequence
    // with another state is malformed rather than a second transition.
    if (previous && identity.sequence <= previous.sequence) {
      return;
    }
    this.wakeEventsByKey.set(identity.key, {
      sequence: identity.sequence,
      state: identity.state,
    });
    this.wakeAfterSequence = identity.sequence;
    this.pollNow();
  };

  async start() /*: Promise<void> */ {
    if (!this.stopped) return;
    this.stopped = false;
    this.runEpoch++;
    this.abortController = new AbortController();
    this.wakeEventsByKey.clear();
    this.wakeAfterSequence = this.afterSequence;
    this.intervalId = this.setIntervalImplementation(
      () => this.pollNow(),
      this.pollIntervalMs
    );
    const EventSourceConstructor = this.EventSourceConstructor;
    if (EventSourceConstructor) {
      try {
        const eventSource = new EventSourceConstructor(
          eventStreamUrl(this.gameId, this.sessionId, this.wakeAfterSequence)
        );
        const eventSourceRuntime /*: any */ = eventSource;
        if (typeof eventSourceRuntime.addEventListener === 'function') {
          WAKE_EVENT_TYPES.forEach(eventType => {
            const listener /*: EventListener */ = (event /*: any */) =>
              this._onEvent(eventType, event);
            eventSourceRuntime.addEventListener(eventType, listener);
            this.eventListeners.set(eventType, listener);
          });
        }
        eventSource.onerror = () => {
          // Polling remains authoritative; EventSource reconnect is native.
        };
        this.eventSource = eventSource;
      } catch (_) {
        this.eventSource = null;
      }
    }
    await this.pollNow();
  }

  stop() /*: void */ {
    this.stopped = true;
    this.runEpoch++;
    this.pollAgain = false;
    const abortController = this.abortController;
    if (abortController) {
      abortController.abort();
      this.abortController = null;
    }
    const intervalId = this.intervalId;
    if (intervalId != null) {
      this.clearIntervalImplementation(intervalId);
      this.intervalId = null;
    }
    const eventSource = this.eventSource;
    if (eventSource) {
      const eventSourceRuntime /*: any */ = eventSource;
      if (typeof eventSourceRuntime.removeEventListener === 'function') {
        this.eventListeners.forEach((listener, eventType) =>
          eventSourceRuntime.removeEventListener(eventType, listener)
        );
      }
      this.eventListeners.clear();
      eventSource.close();
      this.eventSource = null;
    }
  }
}

export default PlaymeshAiCallCoordinator;
