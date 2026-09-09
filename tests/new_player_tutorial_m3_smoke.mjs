#!/usr/bin/env node
// Node >= 22: historical server-tutorial probe. The final model is client-only
// guest tutorial, so this probe is retained only as a legacy contract gate.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PROTOCOL = path.join(ROOT, 'shared', 'protocol.md');
const WS_IMPL = path.join(ROOT, 'server', 'src', 'tides_ws_conn.erl');
const TUTORIAL_IMPL = path.join(ROOT, 'server', 'src', 'tides_tutorial.erl');
const args = process.argv.slice(2);
const live = args.includes('--live');
const url = args.find((arg) => !arg.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const timeoutMs = Number(args.find((arg) => arg.startsWith('--timeout='))?.split('=')[1] || 5000);
const results = [];

if (live) {
  result('M3-FINAL-MODEL', 'BLOCKED', 'final guest tutorial is client-only; server tutorial WebSocket probe is not an acceptance path');
  process.exitCode = 2;
}

function result(id, status, detail) {
  results.push({ id, status, detail });
  console.log(`${status.padEnd(8)} ${id}: ${detail}`);
}

function protocolGate() {
  if (!fs.existsSync(PROTOCOL)) {
    result('PC-00', 'BLOCKED', `missing protocol: ${path.relative(ROOT, PROTOCOL)}`);
    return false;
  }
  const text = fs.readFileSync(PROTOCOL, 'utf8');
  const names = [
    'start_tutorial', 'tutorial_status', 'tutorial_reconnect', 'tutorial_replay',
    'tutorial_state', 'tutorial_ack', 'tutorial_rejected', 'tutorial_completed',
    'tutorial_exited', 'tutorial_reconnected', 'tutorial_replay_started',
  ];
  const missing = names.filter((name) => !text.includes(`\`${name}\``));
  if (missing.length) {
    result('PC-01..PC-02', 'BLOCKED', `protocol missing message(s): ${missing.join(', ')}`);
    return false;
  }
  const state = text.match(/\| `tutorial_state` \|([^\n]+)/)?.[1] || '';
  const reconnect = text.match(/\| `tutorial_reconnected` \|([^\n]+)/)?.[1] || '';
  const hasSession = /session_id/.test(state) && /session_id/.test(reconnect);
  const hasVersion = /snapshot_version/.test(state);
  if (!hasSession || !hasVersion) {
    result('PC-03..PC-06', 'BLOCKED', 'tutorial state contract lacks session ownership and monotonic snapshot/version observability');
    return false;
  }
  if (!fs.existsSync(WS_IMPL) || !fs.existsSync(TUTORIAL_IMPL)) {
    result('IMPL-00', 'BLOCKED', 'tutorial WebSocket implementation source is unavailable');
    return false;
  }
  const wsText = fs.readFileSync(WS_IMPL, 'utf8');
  const tutorialText = fs.readFileSync(TUTORIAL_IMPL, 'utf8');
  const implementationChecks = [
    ['tutorial_state session_id', /<<"session_id">>\s*=>\s*maps:get\(session_id/],
    ['tutorial_state snapshot_version', /<<"snapshot_version">>\s*=>/],
    ['tutorial_reconnected response', /<<"tutorial_reconnected">>/],
    ['tutorial replay response', /<<"tutorial_replay_started">>/],
    ['recovery grace window', /-define\(GRACE_MS,\s*\d+\)/],
    ['monotonic snapshot state', /snapshot_version|state_version/],
  ];
  const missingImpl = implementationChecks
    .filter(([, pattern]) => !pattern.test(`${wsText}\n${tutorialText}`))
    .map(([name]) => name);
  if (missingImpl.length) {
    result('IMPL-01..IMPL-06', 'BLOCKED', `server implementation does not expose required behavior: ${missingImpl.join(', ')}`);
    return false;
  }
  result('PC-01..PC-06', 'PASS', 'M3 message names and observable identity/version fields are documented');
  result('IMPL-01..IMPL-06', 'PASS', 'server source exposes the documented tutorial fields and recovery hooks');
  return true;
}

function waitFor(ws, predicate, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.removeEventListener('message', onMessage);
      reject(new Error(`timeout waiting for ${label}`));
    }, timeoutMs);
    function onMessage(event) {
      let msg;
      try { msg = JSON.parse(String(event.data)); } catch { return; }
      if (!predicate(msg)) return;
      clearTimeout(timer);
      ws.removeEventListener('message', onMessage);
      resolve(msg);
    }
    ws.addEventListener('message', onMessage);
  });
}

function send(ws, type, payload, playerToken) {
  ws.send(JSON.stringify({ type, ts: Math.floor(Date.now() / 1000), player_token: playerToken, payload }));
}

async function connect(token) {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WebSocket open timeout')), timeoutMs);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('WebSocket connection failed')); }, { once: true });
  });
  return { ws, token };
}

function close(connection) { try { connection?.ws.close(); } catch { /* already closed */ } }

async function liveProbe() {
  let a;
  let b;
  try {
    a = await connect(`m3-a-${randomUUID()}`);
    b = await connect(`m3-b-${randomUUID()}`);

    let response = waitFor(a.ws, (m) => m.type === 'tutorial_status' || m.type === 'error', 'A tutorial_status');
    send(a.ws, 'tutorial_status', {}, a.token);
    const first = await response;
    if (first.type !== 'tutorial_status' || typeof first.payload?.completed !== 'boolean') {
      result('M3-P01', 'FAIL', `invalid status response: ${JSON.stringify(first)}`);
    } else result('M3-P01', 'PASS', `A status completed=${first.payload.completed}`);

    response = waitFor(a.ws, (m) => m.type === 'tutorial_status' || m.type === 'error', 'duplicate status');
    send(a.ws, 'tutorial_status', {}, a.token);
    const duplicate = await response;
    if (duplicate.type === 'tutorial_status' && JSON.stringify(duplicate.payload) === JSON.stringify(first.payload)) {
      result('M3-A06', 'PASS', 'repeated status returned an equivalent snapshot');
    } else result('M3-A06', 'FAIL', `repeated status changed: ${JSON.stringify(duplicate)}`);

    response = waitFor(a.ws, (m) => m.type === 'tutorial_state' || m.type === 'error', 'start_tutorial');
    send(a.ws, 'start_tutorial', {}, a.token);
    const started = await response;
    const startedVersion = started.payload?.snapshot_version;
    if (started.type === 'tutorial_state' && typeof started.payload?.session_id === 'string' &&
        typeof startedVersion === 'number' && started.payload?.stage === 'T1') {
      result('M3-R01', 'PASS', `start returned ${started.payload.session_id} stage=T1 version=${startedVersion}`);
    }
    else result('M3-R01', 'FAIL', `start failed: ${JSON.stringify(started)}`);

    response = waitFor(a.ws, (m) => m.type === 'error' || m.type === 'tutorial_reconnected', 'invalid reconnect');
    send(a.ws, 'tutorial_reconnect', { session_id: 'invalid-session-for-m3-smoke' }, a.token);
    const rejected = await response;
    if (rejected.type === 'error' && typeof rejected.payload?.code === 'string' &&
        typeof rejected.payload?.message === 'string') result('M3-R07', 'PASS', `invalid recovery rejected: ${rejected.payload.code}`);
    else result('M3-R07', 'FAIL', `invalid recovery response: ${JSON.stringify(rejected)}`);

    response = waitFor(a.ws, (m) => m.type === 'error' || m.type === 'tutorial_replay_started', 'replay');
    send(a.ws, 'tutorial_replay', {}, a.token);
    const replay = await response;
    if (replay.type === 'error') result('M3-W01', 'BLOCKED', `completed replay fixture unavailable: ${replay.payload?.code || 'error'}`);
    else result('M3-W01', 'NOT RUN', 'replay fixture was not completed; response is not an acceptance PASS');

    response = waitFor(b.ws, (m) => m.type === 'tutorial_status' || m.type === 'error', 'B tutorial_status');
    send(b.ws, 'tutorial_status', {}, b.token);
    const bStatus = await response;
    if (bStatus.type === 'tutorial_status' && typeof bStatus.payload?.completed === 'boolean') result('M3-I04', 'PASS', 'independent guest received an independent status response');
    else result('M3-I04', 'FAIL', `B status invalid: ${JSON.stringify(bStatus)}`);
  } catch (error) {
    result('ENV-WS', 'BLOCKED', `${error.message}; start the server and rerun with --live`);
  } finally { close(a); close(b); }
}

const gateOk = live ? false : protocolGate();
if (gateOk) result('ENV-WS', 'BLOCKED', 'server tutorial probe is legacy-only; use client tutorial acceptance');
const blocked = results.filter((r) => r.status === 'BLOCKED').length;
const failed = results.filter((r) => r.status === 'FAIL').length;
console.log(`M3 summary: PASS=${results.filter((r) => r.status === 'PASS').length} FAIL=${failed} BLOCKED=${blocked}`);
process.exitCode = failed ? 1 : blocked ? 2 : 0;
