#!/usr/bin/env node
// native E2E 用の、偽のブリッジ（live-support の受信口の代わり）。受け取った要求を 1 行 1 件の JSON で --log に書く。
//   node scripts/e2e-bridge.mjs --token <t> --log <file> [--mode ok|notready]
// 標準出力に "PORT <n>" を出す。Host が 127.0.0.1:<port> でない要求は 403、トークンが違えば 401、--mode notready なら 503（live-support の bridge.js と同じ順）。
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const args = process.argv.slice(2);
const option = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
const token = option("--token"), log = option("--log"), mode = option("--mode") ?? "ok";
if (!token || !log) { console.error("usage: e2e-bridge.mjs --token <t> --log <file> [--mode ok|notready]"); process.exit(2); }

const server = createServer((req, res) => {
  const chunks = [];
  req.on("data", chunk => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks).toString("utf8");
    const entry = { method: req.method, path: req.url, host: req.headers.host, authorized: req.headers.authorization === "Bearer " + token, contentType: req.headers["content-type"] ?? null, body: body || null };
    let status = 200;
    if (req.headers.host !== "127.0.0.1:" + server.address().port) status = 403;
    else if (!entry.authorized) status = 401;
    else if (mode === "notready") status = 503;
    else if (req.method === "POST" && !["/captions", "/end"].includes(req.url)) status = 404;
    else if (req.method === "POST") { try { JSON.parse(body); } catch { status = 400; } }
    appendFileSync(log, JSON.stringify({ ...entry, status }) + "\n");
    res.writeHead(status, { "cache-control": "no-store" });
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => { console.log("PORT " + server.address().port); });
process.on("SIGTERM", () => server.close(() => process.exit(0)));
