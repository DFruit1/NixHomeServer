import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { enrollOfflineMediaDevice, getOfflineMediaSetup, removeOfflineMediaDevice } from './offlineMedia.js';
import { installSftpPublicKey, normalisePublicKey } from './sftpKey.js';
import { buildHomepageData } from './homepageData.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

export const handleRequest = async (config: AppConfig, request: IncomingMessage, response: ServerResponse): Promise<void> => {
  if (await handleApiRequest(config, request, response)) {
    return;
  }
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  await serveStatic(config, response, url.pathname);
};

export const handleApiRequest = async (config: AppConfig, request: IncomingMessage, response: ServerResponse): Promise<boolean> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    if (request.method === 'GET' && url.pathname === '/healthz') {
      sendJson(response, 200, { ok: true });
      return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/home') {
      sendJson(response, 200, await buildHomepageData(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/sftp-key') {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      const body = await readJson<{ publicKey?: string }>(request);
      const publicKey = normalisePublicKey(body.publicKey);
      sendJson(response, 200, await installSftpPublicKey(config, user, publicKey));
      return true;
    }

    if (request.method === 'GET' && (url.pathname === '/api/offline-media' || url.pathname === '/api/offline-music')) {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      sendJson(response, 200, await getOfflineMediaSetup(config, user));
      return true;
    }

    if (request.method === 'POST' && (url.pathname === '/api/offline-media/devices' || url.pathname === '/api/offline-music/device')) {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      const body = await readJson<{ deviceId?: string; deviceName?: string }>(request);
      sendJson(response, 200, await enrollOfflineMediaDevice(config, user, body));
      return true;
    }

    if (request.method === 'DELETE' && url.pathname.startsWith('/api/offline-media/devices/')) {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      const deviceId = decodeURIComponent(url.pathname.slice('/api/offline-media/devices/'.length));
      sendJson(response, 200, await removeOfflineMediaDevice(config, user, deviceId));
      return true;
    }

    if (url.pathname.startsWith('/api/')) {
      sendJson(response, 404, { error: 'api route not found' });
      return true;
    }

    return false;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('authenticated user') ? 401 : 500;
    sendJson(response, status, { error: message });
    return true;
  }
};

const readJson = async <T>(request: IncomingMessage): Promise<T> => {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? (JSON.parse(text) as T) : ({} as T);
};

const sendJson = (response: ServerResponse, status: number, value: unknown): void => {
  response.statusCode = status;
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.end(JSON.stringify(value));
};

const serveStatic = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<void> => {
  const requested = rawPath === '/' ? '/index.html' : rawPath;
  const candidate = path.resolve(config.staticDir, `.${decodeURIComponent(requested)}`);
  const root = path.resolve(config.staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    throw new Error('static path not found');
  }
  try {
    const file = await stat(candidate);
    if (!file.isFile()) {
      throw new Error('static path not found');
    }
    response.statusCode = 200;
    response.setHeader('content-type', CONTENT_TYPES[path.extname(candidate)] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
  } catch {
    const index = await readFile(path.join(config.staticDir, 'index.html'));
    response.statusCode = 200;
    response.setHeader('content-type', 'text/html; charset=utf-8');
    response.end(index);
  }
};
