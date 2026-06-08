import { createServer, type ServerResponse } from 'node:http';
import { createQwikCity } from '@builder.io/qwik-city/middleware/node';
import qwikCityPlan from '@qwik-city-plan';
import render from './entry.ssr';
import { loadConfig } from './server/config.js';
import { handleApiRequest } from './server/http.js';

const config = loadConfig();

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
  void handleApiRequest(config, request, response)
    .then((handled) => {
      if (handled) {
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
    })
    .catch((error) => fail(response, error));
});

server.listen(config.port, config.host, () => {
  console.log(`homepage listening on http://${config.host}:${config.port}`);
});
