"use strict";

function options() {
  return {
    enabled: {
      label: "启用 Playmesh 发布",
      description:
        "将本次 Web 构建同步到 playmesh-cli.json 指定的发布目录。",
      default: true,
      render: {
        ui: "ui-checkbox",
      },
    },
    runAfterBuild: {
      label: "构建后上传并运行到 App",
      description:
        "构建成功后执行 playmesh-cli run；关闭时只更新最近构建。",
      default: true,
      render: {
        ui: "ui-checkbox",
      },
    },
  };
}

exports.configs = {
  "web-mobile": {
    hooks: "./hooks",
    options: options(),
  },
  "web-desktop": {
    hooks: "./hooks",
    options: options(),
  },
};
