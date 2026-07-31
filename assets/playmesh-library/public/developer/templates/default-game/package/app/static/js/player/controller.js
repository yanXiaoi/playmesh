import { InputTypes } from "../shared/types.js";

await playmesh.ready;
document.querySelector("#status").textContent = "Ready";
document.querySelector("#action").addEventListener("click", () => {
  void playmesh.main.sync.submitAction({ type: InputTypes.primary });
});

playmesh.main.sync.observe((snapshot) => {
  document.querySelector("#status").textContent =
    `Ready · actions ${snapshot.state.actionCount}`;
});
