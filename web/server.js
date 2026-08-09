'use strict';
/*
 * Control panel for the LDAC receiver.
 *
 * Serves a single page and a small JSON API for toggling room correction and
 * Bluetooth discoverability, and for managing paired clients.
 *
 * This process is unprivileged.  Every privileged action goes through
 * /usr/local/sbin/ldac-ctl, which is the only thing sudo will let it run, and
 * which validates its own arguments.  Requests are mapped onto a fixed verb
 * table here as well, so an unexpected value is rejected before it reaches
 * sudo.  execFile is used throughout: no shell ever sees any of this.
 *
 * No external dependencies, deliberately — nothing to install or keep patched
 * on an appliance that is meant to sit there and work.
 *
 * SPDX-License-Identifier: MIT
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

const PORT = Number(process.env.LDAC_WEB_PORT || 8080);
const BIND = process.env.LDAC_WEB_BIND || '0.0.0.0';
const CTL = process.env.LDAC_CTL || '/usr/local/sbin/ldac-ctl';
// Optional shared secret.  Unset (the default) means anyone who can reach the
// port can control the receiver — fine on a trusted home network, and the
// reason the unit binds nothing wider than the LAN.  See README.
const TOKEN = process.env.LDAC_WEB_TOKEN || '';

const INDEX = path.join(__dirname, 'public', 'index.html');
const MAX_BODY = 4096;
const MAC_RE = /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/;
const DEVICE_ACTIONS = new Set(['connect', 'disconnect', 'trust', 'untrust', 'remove']);

/** Run ldac-ctl with a fixed argument list and parse its JSON reply. */
function ctl(args) {
  return new Promise((resolve, reject) => {
    execFile('sudo', ['-n', CTL, ...args], { timeout: 60000 }, (err, stdout) => {
      let parsed = null;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        /* fall through to the error below */
      }
      if (parsed) return resolve(parsed);
      reject(new Error(
        err ? `${CTL} ${args.join(' ')}: ${err.message}`
            : `${CTL} ${args.join(' ')}: unparseable output`));
    });
  });
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    'cache-control': 'no-store',
  });
  res.end(text);
}

/** Anything the client got wrong, so the handler can answer 400 rather than 500. */
class BadRequest extends Error {}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
        reject(new BadRequest('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new BadRequest('body is not valid JSON'));
      }
    });
    req.on('error', reject);
  });
}

/** Constant-time-ish comparison, so the token cannot be guessed byte by byte. */
function tokenOk(given) {
  if (!TOKEN) return true;
  const a = Buffer.from(String(given || ''));
  const b = Buffer.from(TOKEN);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

function onOff(value) {
  if (value === true) return 'on';
  if (value === false) return 'off';
  return null;
}

async function handleApi(req, res, url) {
  if (!tokenOk(req.headers['x-auth-token'] || url.searchParams.get('token'))) {
    return sendJson(res, 401, { ok: false, error: 'bad or missing token' });
  }

  if (req.method === 'GET' && url.pathname === '/api/status') {
    return sendJson(res, 200, await ctl(['status']));
  }

  if (req.method !== 'POST') {
    return sendJson(res, 405, { ok: false, error: 'method not allowed' });
  }

  const body = await readBody(req);

  if (url.pathname === '/api/convolution' || url.pathname === '/api/discoverable') {
    const state = onOff(body.enabled);
    if (state === null) {
      return sendJson(res, 400, { ok: false, error: '"enabled" must be true or false' });
    }
    const verb = url.pathname === '/api/convolution' ? 'convolution' : 'discoverable';
    return sendJson(res, 200, await ctl([verb, state]));
  }

  if (url.pathname === '/api/volume') {
    // Source, mute and level are separate requests; a body with several would
    // be ambiguous about which one was meant.
    if ('source' in body) {
      if (body.source !== 'panel' && body.source !== 'device') {
        return sendJson(res, 400, {
          ok: false, error: '"source" must be "panel" or "device"',
        });
      }
      return sendJson(res, 200, await ctl(['volume', 'source', body.source]));
    }
    if ('muted' in body) {
      const state = onOff(body.muted);
      if (state === null) {
        return sendJson(res, 400, { ok: false, error: '"muted" must be true or false' });
      }
      return sendJson(res, 200, await ctl(['volume', 'mute', state]));
    }
    // Deliberately not Number(body.db): that turns null, "" and [] into 0,
    // which would read as "set full volume" for a request that said no such
    // thing.  Only an actual JSON number is accepted.
    const db = body.db;
    if (typeof db !== 'number' || !Number.isFinite(db) || db > 0 || db < -127) {
      return sendJson(res, 400, {
        ok: false, error: '"db" must be a number between -127 and 0',
      });
    }
    return sendJson(res, 200, await ctl(['volume', 'set', String(Math.round(db))]));
  }

  if (url.pathname === '/api/device') {
    const action = String(body.action || '');
    const mac = String(body.mac || '').toUpperCase();
    if (!DEVICE_ACTIONS.has(action)) {
      return sendJson(res, 400, { ok: false, error: `unknown action: ${action}` });
    }
    if (!MAC_RE.test(mac)) {
      return sendJson(res, 400, { ok: false, error: 'not a Bluetooth address' });
    }
    return sendJson(res, 200, await ctl(['device', action, mac]));
  }

  return sendJson(res, 404, { ok: false, error: 'no such endpoint' });
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, 'http://localhost');
  } catch {
    return sendJson(res, 400, { ok: false, error: 'bad request' });
  }

  if (url.pathname.startsWith('/api/')) {
    handleApi(req, res, url).catch((err) => {
      sendJson(res, err instanceof BadRequest ? 400 : 500,
               { ok: false, error: err.message });
    });
    return;
  }

  // Exactly one static file, looked up by name rather than by path, so there is
  // no traversal to get wrong.
  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
    fs.readFile(INDEX, (err, data) => {
      if (err) {
        res.writeHead(500, { 'content-type': 'text/plain' });
        return res.end('control panel page is missing\n');
      }
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'content-length': data.length,
        'cache-control': 'no-store',
      });
      res.end(data);
    });
    return;
  }

  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found\n');
});

server.listen(PORT, BIND, () => {
  console.log(`LDAC receiver control panel on http://${BIND}:${PORT}` +
              (TOKEN ? ' (token required)' : ' (no authentication)'));
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
