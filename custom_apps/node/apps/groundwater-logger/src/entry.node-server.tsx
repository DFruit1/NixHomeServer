import { createServer, type ServerResponse } from 'node:http';
import { createQwikCity } from '@builder.io/qwik-city/middleware/node';
import qwikCityPlan from '@qwik-city-plan';
import render from './entry.ssr.js';
import { loadConfig } from './server/config.js';
import { Database } from './server/db.js';
import { handleApiRequest, tryServeStaticAsset } from './server/http.js';
import { MqttBridge } from './server/mqttBridge.js';

const config = loadConfig();
const db = new Database(config.databasePath);
await db.migrate();

const mqttBridge = new MqttBridge(config, db);
mqttBridge.start();

const { router, notFound, staticFile } = createQwikCity({
  render,
  qwikCityPlan,
  static: {
    root: config.staticDir,
    cacheControl: 'public, max-age=31536000, immutable',
  },
});

const fail = (response: ServerResponse, error: unknown): void => {
  console.error('request failed', error);
  if (!response.headersSent) {
    response.statusCode = 500;
    response.setHeader('content-type', 'application/json; charset=utf-8');
  }
  response.end(JSON.stringify({ error: 'internal server error' }));
};

const server = createServer((request, response) => {
  void (async () => {
    if (await handleApiRequest({ config, db, mqttBridge }, request, response)) {
      return;
    }

    const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
    if (await tryServeStaticAsset(config, response, url.pathname)) {
      return;
    }

    staticFile(request, response, (staticError) => {
      if (staticError) {
        fail(response, staticError);
        return;
      }
      router(request, response, (routerError) => {
        if (routerError) {
          fail(response, routerError);
          return;
        }
        notFound(request, response, (notFoundError) => {
          if (notFoundError) {
            fail(response, notFoundError);
          }
        });
      });
    });
  })().catch((error) => fail(response, error));
});

const shutdown = () => {
  mqttBridge.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

server.listen(config.port, config.host, () => {
  console.log(`groundwater-logger listening on http://${config.host}:${config.port}`);
});
