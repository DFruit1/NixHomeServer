import { createServer } from 'node:http';
import { loadConfig } from './config.js';
import { Database } from './db.js';
import { handleRequest } from './http.js';
import { JobQueue } from './queue.js';

const config = loadConfig();
const db = new Database(config.databasePath);
await db.migrate();
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
