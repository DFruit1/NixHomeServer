// The official EYE SDK supplies its native LiteRT pipeline through Node.
// Media Manager's Rust broker owns authentication and every Immich API call;
// this helper accepts image bytes over a private Unix socket only.
import http from "node:http";
import { chmodSync, lstatSync, unlinkSync } from "node:fs";
import sharp from "sharp";
import { Eye } from "@desert-ant-labs/eye/native";

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
let eye;
let idleTimer;
let busy = false;
const release = () => {
  clearTimeout(idleTimer);
  if (eye) eye.dispose();
  eye = undefined;
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

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    reply(response, 200, { ready: true, loaded: !!eye });
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
  // A stuck native call is recovered by systemd restarting this helper.
  const deadline = setTimeout(() => process.exit(1), 25_000);
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
    const { data, info } = await sharp(Buffer.concat(chunks), {
      limitInputPixels: 40_000_000,
      failOn: "error",
    })
      .rotate()
      .resize({ width: 2048, height: 2048, fit: "inside", withoutEnlargement: true })
      .removeAlpha()
      .toColourspace("srgb")
      .raw()
      .toBuffer({ resolveWithObject: true });
    eye ??= await Eye.load({ directory });
    const photo = await eye.analyze({ data, width: info.width, height: info.height });
    const suggestions = photo.tags()
      .filter((tag) => /^[a-z0-9_]{1,96}$/.test(tag))
      .slice(0, 64)
      .map((tag) => ({ tag, confidence: photo.confidence(tag) }));
    reply(response, 200, { model: photo.model, suggestions, scores: photo.scores });
  } catch {
    request.resume();
    // Neither image contents, filenames, nor upstream errors belong in logs.
    reply(response, 422, { error: "analysis_failed" });
  } finally {
    clearTimeout(deadline);
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
  server.close(() => { release(); process.exit(0); });
});
