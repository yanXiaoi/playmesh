// @flow

const VALID_GAME_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const MUTATION_EVENT = 'playmesh-gdevelop-project-mutation';

/*::
export type PlaymeshProjectMutationLease = $ReadOnly<{|
  gameId: string,
  owner: string,
  epoch: number,
|}>;

type PlaymeshProjectMutationWaiter = {|
  owner: string,
  resolve: PlaymeshProjectMutationLease => void,
|};

type PlaymeshProjectMutationState = {|
  gameId: string,
  epoch: number,
  activeLease: ?PlaymeshProjectMutationLease,
  queue: Array<PlaymeshProjectMutationWaiter>,
|};

export type PlaymeshProjectAutosaveResult<Result> =
  | {| skipped: 'project_mutation_locked' |}
  | {| value: Result |};
*/

const projectStates /*: Map<string, PlaymeshProjectMutationState> */ = new Map();

export class PlaymeshProjectMutationError extends Error {
  /*:: code: string; */

  constructor(code /*: string */) {
    super('The Playmesh GDevelop project mutation is unavailable.');
    this.name = 'PlaymeshProjectMutationError';
    this.code = code;
  }
}

const requireGameId = (gameId /*: ?string */) /*: string */ => {
  if (typeof gameId !== 'string' || !VALID_GAME_ID.test(gameId)) {
    throw new PlaymeshProjectMutationError('invalid_project_id');
  }
  return gameId;
};

const stateFor = (
  gameId /*: string */
) /*: PlaymeshProjectMutationState */ => {
  const validated = requireGameId(gameId);
  let state = projectStates.get(validated);
  if (!state) {
    state = {
      gameId: validated,
      epoch: 0,
      activeLease: null,
      queue: [],
    };
    projectStates.set(validated, state);
  }
  return state;
};

const dispatchMutationState = (
  state /*: PlaymeshProjectMutationState */
) /*: void */ => {
  if (!global.dispatchEvent || typeof global.CustomEvent !== 'function') return;
  global.dispatchEvent(
    new global.CustomEvent(MUTATION_EVENT, {
      detail: {
        gameId: state.gameId,
        locked: !!state.activeLease,
        owner: state.activeLease ? state.activeLease.owner : null,
        epoch: state.activeLease ? state.activeLease.epoch : state.epoch,
      },
    })
  );
};

const activateNext = (
  state /*: PlaymeshProjectMutationState */
) /*: void */ => {
  if (state.activeLease || state.queue.length === 0) return;
  const waiter = state.queue.shift();
  if (!waiter) return;
  const lease = Object.freeze({
    gameId: state.gameId,
    owner: waiter.owner,
    epoch: ++state.epoch,
  });
  state.activeLease = lease;
  dispatchMutationState(state);
  waiter.resolve(lease);
};

export const acquirePlaymeshProjectMutation = ({
  gameId,
  owner,
} /*: {|
  gameId: string,
  owner: string,
|} */) /*: Promise<PlaymeshProjectMutationLease> */ => {
  if (typeof owner !== 'string' || !owner) {
    return Promise.reject(
      new PlaymeshProjectMutationError('invalid_mutation_owner')
    );
  }
  const state = stateFor(gameId);
  return new Promise/*::<PlaymeshProjectMutationLease>*/(resolve => {
    state.queue.push({ owner, resolve });
    activateNext(state);
  });
};

export const releasePlaymeshProjectMutation = (
  lease /*: ?PlaymeshProjectMutationLease */
) /*: void */ => {
  const state = lease && projectStates.get(lease.gameId);
  if (!state || state.activeLease !== lease) {
    throw new PlaymeshProjectMutationError('mutation_lease_mismatch');
  }
  state.activeLease = null;
  dispatchMutationState(state);
  activateNext(state);
};

export const assertPlaymeshProjectMutationLease = (
  lease /*: ?PlaymeshProjectMutationLease */
) /*: PlaymeshProjectMutationLease */ => {
  if (!lease) {
    throw new PlaymeshProjectMutationError('mutation_lease_expired');
  }
  const state = projectStates.get(lease.gameId);
  if (!state || state.activeLease !== lease) {
    throw new PlaymeshProjectMutationError('mutation_lease_expired');
  }
  return lease;
};

export const isPlaymeshProjectMutationLocked = (
  gameId /*: string */
) /*: boolean */ =>
  !!stateFor(gameId).activeLease;

export const runPlaymeshProjectMutation /*: <Result>(options: {|
  gameId: string,
  owner: string,
  operation: (
    lease: PlaymeshProjectMutationLease
  ) => Promise<Result>,
|}) => Promise<Result> */ = async ({
  gameId,
  owner,
  operation,
}) => {
  if (typeof operation !== 'function') {
    throw new PlaymeshProjectMutationError('invalid_mutation_operation');
  }
  const lease = await acquirePlaymeshProjectMutation({ gameId, owner });
  try {
    return await operation(lease);
  } finally {
    releasePlaymeshProjectMutation(lease);
  }
};

/** 自动保存不排队，避免一个旧快照在 AI commit 后继续覆盖 exact-after。 */
export const tryRunPlaymeshProjectAutosave /*: <Result>(options: {|
  gameId: string,
  operation: (
    lease: PlaymeshProjectMutationLease
  ) => Promise<Result>,
|}) => Promise<PlaymeshProjectAutosaveResult<Result>> */ = async ({
  gameId,
  operation,
}) => {
  const state = stateFor(gameId);
  if (state.activeLease || state.queue.length > 0) {
    return { skipped: 'project_mutation_locked' };
  }
  const value = await runPlaymeshProjectMutation({
    gameId,
    owner: 'autosave',
    operation,
  });
  return { value };
};

export const PLAYMESH_PROJECT_MUTATION_EVENT = MUTATION_EVENT;
