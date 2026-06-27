import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import type { AppConfig } from './config.js';
import type { Database } from './db.js';
import { messagesToCsv, messagesToJsonl } from './export.js';
import type { MqttBridge } from './mqttBridge.js';
import { commandPresets } from './presets.js';
import type { Direction, MessageFilters, PublishRequest } from '../shared/types.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

export type ServerContext = {
  config: AppConfig;
  db: Database;
  mqttBridge: MqttBridge;
};

export const handleApiRequest = async (
  context: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
): Promise<boolean> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  if (request.method === 'GET' && url.pathname === '/healthz') {
    sendJson(response, 200, { ok: true });
    return true;
  }
  if (!url.pathname.startsWith('/api/')) {
    return false;
  }

  try {
    await handleApi(context, request, response, url);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    sendJson(response, message.includes('not found') ? 404 : 400, { error: message });
  }
  return true;
};

const handleApi = async (
  { config, db, mqttBridge }: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
): Promise<void> => {
  if (request.method === 'GET' && url.pathname === '/api/status') {
    sendJson(response, 200, await mqttBridge.status());
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/topics') {
    sendJson(response, 200, {
      subscribedTopics: config.mqttSubscribeTopics,
      observedTopics: await db.observedTopics(),
    });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/presets') {
    sendJson(response, 200, commandPresets);
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/messages') {
    sendJson(response, 200, await db.listMessages(filtersFromUrl(url)));
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/messages/export') {
    const filters = filtersFromUrl(url);
    const format = url.searchParams.get('format') === 'jsonl' ? 'jsonl' : 'csv';
    const messages = await db.exportMessages(filters);
    const body = format === 'jsonl' ? messagesToJsonl(messages) : messagesToCsv(messages);
    response.statusCode = 200;
    response.setHeader('content-type', format === 'jsonl' ? 'application/x-ndjson; charset=utf-8' : 'text/csv; charset=utf-8');
    response.setHeader('content-disposition', `attachment; filename="groundwater-mqtt-${new Date().toISOString()}.${format}"`);
    response.end(body);
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/events') {
    response.statusCode = 200;
    response.setHeader('content-type', 'text/event-stream; charset=utf-8');
    response.setHeader('cache-control', 'no-cache, no-transform');
    response.setHeader('connection', 'keep-alive');
    response.flushHeaders?.();
    const send = (value: unknown) => {
      response.write(`data: ${JSON.stringify(value)}\n\n`);
    };
    const unsubscribe = mqttBridge.onEvent(send);
    const heartbeat = setInterval(() => response.write(': heartbeat\n\n'), 30000);
    request.on('close', () => {
      clearInterval(heartbeat);
      unsubscribe();
      response.end();
    });
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/publish') {
    const body = await readJson<PublishRequest>(request);
    const message = await mqttBridge.publish(body);
    sendJson(response, 201, { ok: true, messageId: message.id });
    return;
  }

  throw new Error('api route not found');
};

const filtersFromUrl = (url: URL): MessageFilters => {
  const direction = url.searchParams.get('direction');
  return {
    topic: url.searchParams.get('topic') || undefined,
    direction: direction === 'inbound' || direction === 'outbound' ? (direction as Direction) : undefined,
    from: url.searchParams.get('from') || undefined,
    to: url.searchParams.get('to') || undefined,
    search: url.searchParams.get('search') || undefined,
    limit: numberParam(url, 'limit'),
    offset: numberParam(url, 'offset'),
  };
};

const numberParam = (url: URL, key: string): number | undefined => {
  const raw = url.searchParams.get(key);
  if (!raw) {
    return undefined;
  }
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) ? value : undefined;
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

export const tryServeStaticAsset = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<boolean> => {
  const ext = path.extname(rawPath);
  if (!ext) {
    return false;
  }
  const candidate = path.resolve(config.staticDir, `.${decodeURIComponent(rawPath)}`);
  const root = path.resolve(config.staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    return false;
  }
  try {
    const file = await stat(candidate);
    if (!file.isFile()) {
      return false;
    }
    response.statusCode = 200;
    response.setHeader('content-type', CONTENT_TYPES[ext] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
    return true;
  } catch {
    if (rawPath === '/index.html') {
      const index = await readFile(path.join(config.staticDir, 'index.html'));
      response.statusCode = 200;
      response.setHeader('content-type', 'text/html; charset=utf-8');
      response.end(index);
      return true;
    }
    return false;
  }
};
