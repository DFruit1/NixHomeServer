#!/usr/bin/env node
import { createServer } from 'node:http';
import { randomBytes, randomUUID } from 'node:crypto';
import process from 'node:process';

const port = Number.parseInt(process.env.FAKE_KANIDM_PORT ?? '18190', 10);

// Kanidm 1.11 issues the auth session id as a signed JWS: mixed-case
// base64url. Clients must forward it byte-for-byte.
const makeSessionToken = () =>
  `eyJhbGciOiJFUzI1NiJ9.${Buffer.from(JSON.stringify({ id: randomUUID() })).toString('base64url')}.${randomBytes(24).toString('base64url')}`;

const accounts = new Map([
  ['dsaw', { password: 'vault-pass', totp: null }],
  ['mfa', { password: 'vault-pass', totp: '654321' }],
  ['basic', { password: 'vault-pass', totp: null }],
]);

const flows = new Map();

const sendJson = (response, status, body) => {
  response.statusCode = status;
  response.setHeader('content-type', 'application/json');
  response.end(JSON.stringify(body));
};

const readBody = (request) =>
  new Promise((resolve, reject) => {
    let text = '';
    request.on('data', (chunk) => {
      text += chunk;
    });
    request.on('end', () => resolve(text));
    request.on('error', reject);
  });

const server = createServer(async (request, response) => {
  if (request.method === 'POST' && request.url === '/v1/logout') {
    await readBody(request);
    sendJson(response, 200, {});
    return;
  }
  if (request.method !== 'POST' || request.url !== '/v1/auth') {
    sendJson(response, 404, { error: 'not found' });
    return;
  }

  let body;
  try {
    body = JSON.parse((await readBody(request)) || '{}');
  } catch {
    sendJson(response, 400, { error: 'invalid json' });
    return;
  }

  const cookies = Object.fromEntries(
    (request.headers.cookie ?? '')
      .split(';')
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const separator = part.indexOf('=');
        return [part.slice(0, separator), part.slice(separator + 1)];
      }),
  );
  // Mirror the real server's session resolution: the signed header wins and
  // must be a known session; the cookie is only consulted without a header.
  const headerSession = request.headers['x-kanidm-auth-session-id'];
  if (headerSession !== undefined && !flows.has(headerSession)) {
    sendJson(response, 400, { error: 'invalid auth session' });
    return;
  }
  const flowId = headerSession ?? cookies['auth-session-id'];
  const flow = flowId ? flows.get(flowId) : undefined;
  const respond = (state, extraHeaders = []) => {
    for (const header of extraHeaders) {
      response.setHeader('set-cookie', header);
    }
    sendJson(response, 200, { sessionid: flowId ?? randomUUID(), state });
  };

  const step = body.step ?? {};
  if (step.init2) {
    const username = String(step.init2.username ?? '');
    const account = accounts.get(username);
    if (!account) {
      respond({ denied: 'Unknown username' });
      return;
    }
    const id = makeSessionToken();
    flows.set(id, { username, totpOk: false });
    response.setHeader('x-kanidm-auth-session-id', id);
    respond({ choose: account.totp ? ['passwordmfa', 'passkey'] : ['password'] }, [
      `auth-session-id=${id}; Path=/; HttpOnly`,
    ]);
    return;
  }
  if (!flow) {
    respond({ denied: 'No authentication session' });
    return;
  }
  if (step.begin) {
    const mech = step.begin;
    if (mech !== 'password' && mech !== 'passwordmfa') {
      respond({ denied: 'Unsupported mechanism' });
      return;
    }
    // Kanidm verifies MFA before accepting the password.
    respond({ continue: mech === 'passwordmfa' ? ['totp'] : ['password'] });
    return;
  }
  if (step.cred?.password !== undefined) {
    const account = accounts.get(flow.username);
    if (!account || (account.totp && !flow.totpOk) || step.cred.password !== account.password) {
      flows.delete(flowId);
      respond({ denied: 'Incorrect password' });
      return;
    }
    flows.delete(flowId);
    respond({ success: `bearer-${flow.username}` });
    return;
  }
  if (step.cred?.totp !== undefined) {
    const account = accounts.get(flow.username);
    if (flow.totpOk || !account || String(step.cred.totp) !== account.totp) {
      flows.delete(flowId);
      respond({ denied: 'Incorrect code' });
      return;
    }
    flow.totpOk = true;
    respond({ continue: ['password'] });
    return;
  }
  sendJson(response, 400, { error: 'unsupported step' });
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`fake kanidm listening on http://127.0.0.1:${port}\n`);
});
