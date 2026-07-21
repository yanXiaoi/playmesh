import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const port = Number(process.argv[2] || 8123);
const root = path.resolve(new URL("..", import.meta.url).pathname.replace(/^\/(.:)/, "$1"));
const mimeTypes = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".json": "application/json" };

http.createServer((request, response) => {
  const requestPath = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  const filePath = path.resolve(root, `.${requestPath}`);
  if (!filePath.startsWith(root) || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    response.writeHead(404).end("Not found");
    return;
  }
  response.setHeader("Content-Type", `${mimeTypes[path.extname(filePath)] || "application/octet-stream"}; charset=utf-8`);
  fs.createReadStream(filePath).pipe(response);
}).listen(port, "127.0.0.1", () => console.log(`http://127.0.0.1:${port}`));
