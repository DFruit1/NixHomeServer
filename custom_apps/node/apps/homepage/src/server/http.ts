import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { installSftpPublicKey, normalisePublicKey } from './sftpKey.js';
import { getSyncthingDeviceId } from './syncthing.js';
import type { HomepageData } from '../shared/types.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

export const handleRequest = async (config: AppConfig, request: IncomingMessage, response: ServerResponse): Promise<void> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    if (request.method === 'GET' && url.pathname === '/healthz') {
      sendJson(response, 200, { ok: true });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/home') {
      const body: HomepageData = {
        ...config.homepage,
        user: currentUserFromHeaders(request.headers, config.devUser),
      };
      if (body.phoneBackup?.enabled) {
        try {
          body.phoneBackup = {
            ...body.phoneBackup,
            serverDeviceId: await getSyncthingDeviceId(config),
          };
        } catch (caught) {
          body.phoneBackup = {
            ...body.phoneBackup,
            serverDeviceIdError: caught instanceof Error ? caught.message : String(caught),
          };
        }
      }
      sendJson(response, 200, body);
      return;
    }

    if (request.method === 'POST' && url.pathname === '/api/sftp-key') {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      const body = await readJson<{ publicKey?: string }>(request);
      const publicKey = normalisePublicKey(body.publicKey);
      sendJson(response, 200, await installSftpPublicKey(config, user, publicKey));
      return;
    }

    if (url.pathname.startsWith('/api/')) {
      sendJson(response, 404, { error: 'api route not found' });
      return;
    }

    await serveStatic(config, response, url.pathname);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('authenticated user') ? 401 : 500;
    sendJson(response, status, { error: message });
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
