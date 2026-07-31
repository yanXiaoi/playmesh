await playmesh.ready;

const status = document.querySelector("#status");
status.textContent = "Ready";

// TODO: 在这里初始化单机游戏状态、输入与渲染。
// 需要持久化时使用 playmesh.main.storage.getBucket()，不要直接写 localStorage。
