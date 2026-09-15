await playmesh.ready;
document.querySelector("#status").textContent = "Ready";

if (playmesh.main.session.isAuthority()) {
  const { startAuthoritySync } = await import("../service/index.js");
  startAuthoritySync();
}

playmesh.main.sync.observe((snapshot) => {
  document.querySelector("#status").textContent =
    `Ready · actions ${snapshot.state.actionCount}`;
});
