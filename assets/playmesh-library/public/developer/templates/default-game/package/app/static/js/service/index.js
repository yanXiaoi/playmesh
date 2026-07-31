import { InputTypes } from "../shared/types.js";

export function startAuthoritySync() {
  return playmesh.main.sync.startAuthority({
    initialState: { actionCount: 0, lastPlayerId: null },
    tickRate: 10,
    onInput(input, context) {
      if (input?.type !== InputTypes.primary) return context.state;
      return {
        actionCount: context.state.actionCount + 1,
        lastPlayerId: context.senderPlayerId,
      };
    },
  });
}
