import { createServer } from 'node:http';
import { loadConfig } from './config.js';
import { handleRequest } from './http.js';

const config = loadConfig();

const server = createServer((request, response) => {
  void handleRequest(config, request, response).catch((error) => {
    console.error('request failed', error);
    response.statusCode = 500;
    response.setHeader('content-type', 'application/json; charset=utf-8');
    response.end(JSON.stringify({ error: 'internal server error' }));
  });
});

server.listen(config.port, config.host, () => {
  console.log(`homepage listening on http://${config.host}:${config.port}`);
});
