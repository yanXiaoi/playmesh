// @flow

export type PlaymeshHistoryRequestKind = "list" | "compare";

export type PlaymeshHistoryRequestHandle = {|
  kind: PlaymeshHistoryRequestKind,
  gameId: string,
  token: number,
  controller: AbortController,
  signal: AbortSignal
|};

/**
 * Owns the two read-only history request lanes. Starting or cancelling a lane
 * advances its token, so even a transport that resolves after abort cannot
 * publish a stale result.
 */
export class PlaymeshHistoryRequestCoordinator {
  _tokens: { list: number, compare: number } = { list: 0, compare: 0 };
  _active: {
    list: ?PlaymeshHistoryRequestHandle,
    compare: ?PlaymeshHistoryRequestHandle
  } = { list: null, compare: null };

  begin(
    kind: PlaymeshHistoryRequestKind,
    gameId: string
  ): PlaymeshHistoryRequestHandle {
    this.cancel(kind);
    const token = this._tokens[kind] + 1;
    this._tokens[kind] = token;
    const controller = new AbortController();
    const handle = {
      kind,
      gameId,
      token,
      controller,
      signal: controller.signal
    };
    this._active[kind] = handle;
    return handle;
  }

  isCurrent(
    handle: PlaymeshHistoryRequestHandle,
    currentGameId: ?string
  ): boolean {
    return (
      !handle.signal.aborted &&
      handle.gameId === currentGameId &&
      this._tokens[handle.kind] === handle.token &&
      this._active[handle.kind] === handle
    );
  }

  finish(handle: PlaymeshHistoryRequestHandle): void {
    if (this._active[handle.kind] === handle) {
      this._active[handle.kind] = null;
    }
  }

  hasActive(kind: PlaymeshHistoryRequestKind): boolean {
    return !!this._active[kind];
  }

  cancel(kind: PlaymeshHistoryRequestKind): void {
    const active = this._active[kind];
    this._tokens[kind] += 1;
    this._active[kind] = null;
    if (active) active.controller.abort();
  }

  cancelAll(): void {
    this.cancel("list");
    this.cancel("compare");
  }
}
