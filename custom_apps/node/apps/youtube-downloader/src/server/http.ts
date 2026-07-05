import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { Database } from './db.js';
import { JobQueue } from './queue.js';
import { probeUrl } from './ytdlp.js';
import { normalizeDownloadUrl } from '../shared/url.js';
import type { CreateJobRequest } from '../shared/types.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
};

export type ServerContext = {
  config: AppConfig;
  db: Database;
  queue: JobQueue;
};

export const handleRequest = async (context: ServerContext, request: IncomingMessage, response: ServerResponse): Promise<void> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    if (request.method === 'GET' && url.pathname === '/healthz') {
      sendJson(response, 200, { ok: true });
      return;
    }
    if (url.pathname.startsWith('/api/')) {
      await handleApi(context, request, response, url);
      return;
    }
    await serveStatic(context.config, response, url.pathname);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('authenticated user') ? 401 : message.includes('not found') ? 404 : 400;
    sendJson(response, status, { error: message });
  }
};

const handleApi = async (
  { config, db, queue }: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
): Promise<void> => {
  const user = currentUserFromHeaders(request.headers, config);

  if (request.method === 'GET' && url.pathname === '/api/me') {
    sendJson(response, 200, user);
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/probe') {
    const body = await readJson<{ url?: string }>(request);
    if (!body.url) {
      throw new Error('url is required');
    }
    sendJson(response, 200, await probeUrl(config, normalizeDownloadUrl(body.url)));
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/jobs') {
    const body = await readJson<CreateJobRequest>(request);
    const jobId = await queue.enqueue(user, body);
    sendJson(response, 201, { jobIds: [jobId] });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/jobs') {
    sendJson(response, 200, await db.listJobs());
    return;
  }

  if (request.method === 'DELETE' && url.pathname === '/api/jobs') {
    await db.clearHistory();
    sendJson(response, 204, {});
    return;
  }

  const jobFileMatch = /^\/api\/jobs\/([^/]+)\/files\/(\d+)$/.exec(url.pathname);
  if (request.method === 'GET' && jobFileMatch) {
    const [, jobId, rawIndex] = jobFileMatch;
    await serveJobFile(db, response, jobId, Number(rawIndex));
    return;
  }

  const jobMatch = /^\/api\/jobs\/([^/]+)(?:\/([^/]+))?$/.exec(url.pathname);
  if (jobMatch) {
    const [, jobId, action] = jobMatch;
    if (request.method === 'GET' && !action) {
      const job = await db.getJob(jobId);
      if (!job) {
        throw new Error('job not found');
      }
      sendJson(response, 200, job);
      return;
    }
    if (request.method === 'POST' && action === 'cancel') {
      await queue.cancel(jobId);
      sendJson(response, 200, { ok: true });
      return;
    }
    if (request.method === 'POST' && action === 'retry') {
      sendJson(response, 201, { jobIds: [await queue.retry(jobId, user)] });
      return;
    }
    if (request.method === 'POST' && action === 'resolve-alert') {
      const body = await readJson<{ action?: string }>(request);
      if (
        body.action !== 'download-again' &&
        body.action !== 'split-chapters' &&
        body.action !== 'single-file' &&
        body.action !== 'cancel'
      ) {
        throw new Error('invalid alert action');
      }
      await queue.resolveAlert(jobId, body.action);
      sendJson(response, 200, { ok: true });
      return;
    }
    if (request.method === 'DELETE' && !action) {
      await db.deleteJob(jobId);
      sendJson(response, 204, {});
      return;
    }
  }

  throw new Error('api route not found');
};

const serveJobFile = async (db: Database, response: ServerResponse, jobId: string, fileIndex: number): Promise<void> => {
  if (!Number.isInteger(fileIndex) || fileIndex < 0) {
    throw new Error('job file not found');
  }
  const job = await db.getJob(jobId);
  const relativePath = job?.files[fileIndex];
  if (!job?.outputFolder || !relativePath || !/\.(?:jpe?g|png|webp)$/i.test(relativePath)) {
    throw new Error('job file not found');
  }

  const root = path.resolve(job.outputFolder);
  const candidate = path.resolve(root, relativePath);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    throw new Error('job file not found');
  }

  const file = await stat(candidate);
  if (!file.isFile()) {
    throw new Error('job file not found');
  }

  response.statusCode = 200;
  response.setHeader('content-type', CONTENT_TYPES[path.extname(candidate).toLowerCase()] ?? 'application/octet-stream');
  response.setHeader('cache-control', 'private, max-age=3600');
  createReadStream(candidate).pipe(response);
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
  if (status === 204) {
    response.end();
    return;
  }
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
