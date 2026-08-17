// @flow

/*::
import type {
  PlaymeshAiCall,
  PlaymeshAiCallState,
} from './PlaymeshAiProtocol';
export type PlaymeshAiRunLoopAction =
  | {| type: 'blocked_multiple_active' |}
  | {| type: 'lease' |}
  | {| type: 'execute', call: PlaymeshAiCall |}
  | {| type: 'wait', call: PlaymeshAiCall |};

type PlaymeshAiAgentRunLoopOptions = {|
  step: () => Promise<boolean>,
  onError?: mixed => void,
|};
*/

const ACTIVE_STATES /*: Set<PlaymeshAiCallState> */ = new Set([
  'running',
]);

export const selectPlaymeshAiRunLoopAction = (
  calls /*: $ReadOnlyArray<PlaymeshAiCall> */
) /*: PlaymeshAiRunLoopAction */ => {
  const active = calls.filter(call => ACTIVE_STATES.has(call.state));
  if (active.length > 1) return { type: 'blocked_multiple_active' };
  const first = active[0];
  if (!first) return { type: 'lease' };
  return first.state === 'running'
    ? { type: 'execute', call: first }
    : { type: 'wait', call: first };
};

/**
 * 所有触发源（SSE、poll、按钮）汇入同一个原子 run-loop。运行中再次 pump
 * 复用同一 Promise，绝不会并行或追加 lease 第二个调用。
 */
export class PlaymeshAiAgentRunLoop {
  /*:: step: () => Promise<boolean>; */
  /*:: onError: mixed => void; */
  /*:: operation: ?Promise<void>; */
  /*:: stopped: boolean; */

  constructor({
    step,
    onError = () => {},
  } /*: PlaymeshAiAgentRunLoopOptions */) {
    this.step = step;
    this.onError = onError;
    this.operation = null;
    this.stopped = true;
  }

  resume() /*: void */ {
    this.stopped = false;
  }

  pump() /*: Promise<void> */ {
    if (this.stopped) return Promise.resolve();
    if (this.operation) return this.operation;
    this.operation = (async () => {
      while (!this.stopped && (await this.step()) === true) {}
    })()
      .catch((error /*: mixed */) => {
        if (!this.stopped) this.onError(error);
      })
      .finally(() => {
        this.operation = null;
      });
    return this.operation;
  }

  stop() /*: void */ {
    this.stopped = true;
  }
}

export default PlaymeshAiAgentRunLoop;
