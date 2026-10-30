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
const eye = await Eye.load({ directory });
let busy = false;
const reply = (response, status, body) => {
  response.writeHead(status, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  response.end(JSON.stringify(body));
};

const server = http.createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    reply(response, 200, { ready: true });
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
  // A stuck native call is recovered by systemd restarting this helper.
  const deadline = setTimeout(() => process.exit(1), 25_000);
  try {
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
    const photo = await eye.analyze({ data, width: info.width, height: info.height });
    const suggestions = photo.tags()
      .filter((tag) => /^[a-z0-9_]{1,96}$/.test(tag))
      .slice(0, 64)
      .map((tag) => ({ tag, confidence: photo.confidence(tag) }));
    reply(response, 200, { model: photo.model, suggestions, scores: photo.scores });
  } catch {
    // Neither image contents, filenames, nor upstream errors belong in logs.
    reply(response, 422, { error: "analysis_failed" });
  } finally {
    clearTimeout(deadline);
    busy = false;
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
  server.close(() => { eye.dispose(); process.exit(0); });
});
