import { createServer } from 'node:http';
import { loadConfig } from './config.js';
import { Database } from './db.js';
import { handleRequest } from './http.js';
import { JobQueue } from './queue.js';

const config = loadConfig();
const db = new Database(config.databasePath);
await db.migrate();
await db.pruneEvents(config.eventRetentionDays);
const pruneTimer = setInterval(() => {
  void db.pruneEvents(config.eventRetentionDays).catch((error) => console.error('event retention failed', error));
}, 24 * 60 * 60 * 1000);
pruneTimer.unref();
const queue = new JobQueue(config, db);
await queue.start();

const server = createServer((request, response) => {
  void handleRequest({ config, db, queue }, request, response).catch((error) => {
    console.error('request failed', error);
    response.statusCode = 500;
    response.setHeader('content-type', 'application/json; charset=utf-8');
    response.end(JSON.stringify({ error: 'internal server error' }));
  });
});

server.listen(config.port, config.host, () => {
  console.log(`youtube-downloader listening on http://${config.host}:${config.port}`);
});

let shuttingDown = false;
const shutdown = (): void => {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(pruneTimer);
  const serverClosed = new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
  void (async () => {
    await queue.stop();
    server.closeAllConnections();
    await serverClosed;
    db.close();
  })().catch((error) => {
    console.error('graceful shutdown failed', error);
    process.exitCode = 1;
  });
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
