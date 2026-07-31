import { startAuthoritySync } from "../service/index.js";

await playmesh.ready;
document.querySelector("#status").textContent = "Ready";

if (playmesh.main.session.isAuthority()) {
  startAuthoritySync();
}

playmesh.main.sync.observe((snapshot) => {
  document.querySelector("#status").textContent =
    `Ready · actions ${snapshot.state.actionCount}`;
});
