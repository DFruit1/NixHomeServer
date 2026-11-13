// The official EYE SDK supplies its native LiteRT pipeline through Node.
// Media Manager's Rust broker owns authentication and every Immich API call;
// this helper accepts image bytes over a private Unix socket only.
import http from "node:http";
import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import { fork } from "node:child_process";
import { fileURLToPath } from "node:url";

const socket = process.env.MEDIA_MANAGER_EYE_SOCKET;
const directory = process.env.MEDIA_MANAGER_EYE_MODELS;
if (!socket?.startsWith("/") || !directory?.startsWith("/")) {
  throw new Error("An absolute EYE socket and model directory are required");
}
const idleSeconds = Number(process.env.MEDIA_MANAGER_EYE_IDLE_SECONDS ?? "300");
if (!Number.isSafeInteger(idleSeconds) || idleSeconds < 1 || idleSeconds > 86400) {
  throw new Error("EYE idle timeout must be between 1 and 86400 seconds");
}
// Health probes must not allocate the model. Only /analyze loads it, while the
// busy guard serializes loading, inference and disposal of the native runtime.
let worker;
let loaded = false;
let idleTimer;
let busy = false;
const release = () => {
  clearTimeout(idleTimer);
  // Native disposal can also block. Kill the isolated process so all native
  // allocations are reclaimed without tying up the HTTP event loop.
  worker?.kill("SIGKILL");
  worker = undefined;
  loaded = false;
};
const releaseWhenIdle = () => {
  idleTimer = setTimeout(() => {
    if (!busy) release();
  }, idleSeconds * 1000);
  idleTimer.unref();
};
const reply = (response, status, body) => {
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  response.end(JSON.stringify(body));
};

// Native SDK calls and disposal can block synchronously even behind an async
// API. A separate process lets this parent enforce the existing hard deadline.
const analyze = (bytes, response) => new Promise((resolve) => {
  let child = worker;
  if (!child) {
    child = fork(fileURLToPath(new URL("./analyze.mjs", import.meta.url)), {
      stdio: ["ignore", "ignore", "inherit", "ipc"],
      serialization: "advanced",
    });
    worker = child;
    const forget = () => {
      if (worker === child) {
        worker = undefined;
        loaded = false;
      }
    };
    child.once("exit", forget);
    child.on("error", forget);
  }
  let settled = false;
  const finish = (status, body) => {
    if (settled) return;
    settled = true;
    clearTimeout(deadline);
    child.off("message", onMessage);
    child.off("error", onError);
    child.off("exit", onExit);
    if (status >= 500 && worker === child) release();
    reply(response, status, body);
    resolve();
  };
  const onMessage = (message) => {
    if (message.ok) {
      loaded = true;
      finish(200, message.analysis);
    } else {
      finish(422, { error: "analysis_failed" });
    }
  };
  const onError = () => finish(503, { error: "analysis_unavailable" });
  const onExit = () => finish(503, { error: "analysis_unavailable" });
  const deadline = setTimeout(() => {
    console.error(JSON.stringify({ service: "media-manager-eye", event: "analysis_timeout" }));
    finish(504, { error: "analysis_timeout" });
  }, 25_000);
  child.on("message", onMessage);
  child.once("error", onError);
  child.once("exit", onExit);
  child.send(bytes, (error) => { if (error) onError(); });
});

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    reply(response, 200, { ready: true, loaded });
    return;
  }
  if (request.method !== "POST" || request.url !== "/analyze") {
    reply(response, 404, { error: "not_found" });
    return;
  }
  if (busy) {
    reply(response, 503, { error: "busy" });
    request.resume();
    return;
  }
  busy = true;
  clearTimeout(idleTimer);
  try {
    const declaredLength = request.headers["content-length"];
    if (declaredLength && (!/^\d+$/.test(declaredLength) || Number(declaredLength) > 16 * 1024 * 1024)) {
      reply(response, 413, { error: "image_too_large" });
      request.resume();
      return;
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > 16 * 1024 * 1024) {
        reply(response, 413, { error: "image_too_large" });
        request.resume();
        return;
      }
      chunks.push(chunk);
    }
    await analyze(Buffer.concat(chunks), response);
  } catch {
    request.resume();
    // Neither image contents, filenames, nor upstream errors belong in logs.
    reply(response, 422, { error: "analysis_failed" });
  } finally {
    busy = false;
    releaseWhenIdle();
  }
});
server.requestTimeout = 15_000;
server.headersTimeout = 10_000;
server.maxConnections = 4;
try {
  if (!lstatSync(socket).isSocket()) throw new Error("EYE socket path is occupied");
  unlinkSync(socket);
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
server.listen(socket, () => chmodSync(socket, 0o660));
process.on("SIGTERM", () => {
  clearTimeout(idleTimer);
  release();
  server.close(() => process.exit(0));
});
