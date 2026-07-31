"use strict";

const fs = require("fs");
const path = require("path");

const cliLogRelativePath = path.join("temp", "logs", "playmesh-cli.log");

function prepareCLILog(root, args) {
  const logPath = path.join(path.resolve(root), cliLogRelativePath);
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const command = Array.isArray(args) && args.length > 0
    ? String(args[0])
    : "unknown";
  fs.writeFileSync(
    logPath,
    `[Playmesh CLI] command=${command}\n`,
    "utf8",
  );
  return logPath;
}

function appendCLILog(logPath, data) {
  if (!logPath || data === undefined || data === null) {
    return;
  }
  const text = String(data);
  if (!text) {
    return;
  }
  fs.appendFileSync(logPath, text, "utf8");
}

module.exports = {
  appendCLILog,
  cliLogRelativePath,
  prepareCLILog,
};
