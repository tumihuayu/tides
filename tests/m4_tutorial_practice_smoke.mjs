#!/usr/bin/env node
// Node >= 22. Legacy server-practice probe. The final model permits only
// client-side guest tutorial; guests cannot call start_practice.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const protocolPath = path.join(ROOT, 'shared', 'protocol.md');
const args = process.argv.slice(2);
const live = args.includes('--live');
const url = args.find((x) => !x.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const timeoutMs = Number(args.find((x) => x.startsWith('--timeout='))?.split('=')[1] || 10000);
const results = [];
const record = (id, status, detail) => { results.push({ id, status }); console.log(`${status.padEnd(8)} ${id}: ${detail}`); };

function gate() {
  if (!fs.existsSync(protocolPath)) { record('M4-PC', 'BLOCKED', 'shared/protocol.md is missing'); return false; }
  const text = fs.readFileSync(protocolPath, 'utf8');
  const required = ['start_practice', 'practice_started', 'tutorial_practice', 'stats_eligible', 'game_over'];
  const missing = required.filter((x) => !text.includes(`\`${x}\``) && !text.includes(x));
  if (missing.length) { record('M4-PC', 'BLOCKED', `protocol missing: ${missing.join(', ')}`); return false; }
  if (!/1 名真人.*1 名.*easy.*bot/.test(text) || !/4 轮 × 3 回合/.test(text)) {
    record('M4-PC', 'BLOCKED', 'protocol lacks the 1+1/formal 4-round practice contract'); return false;
  }
  const wsImplPath = path.join(ROOT, 'server', 'src', 'tides_ws_conn.erl');
  const roomImplPath = path.join(ROOT, 'server', 'src', 'tides_room.erl');
  if (!fs.existsSync(wsImplPath) || !fs.existsSync(roomImplPath)) {
    record('M4-IMPL', 'BLOCKED', 'practice implementation source is unavailable');
    return false;
  }
  const implementation = `${fs.readFileSync(wsImplPath, 'utf8')}\n${fs.readFileSync(roomImplPath, 'utf8')}`;
  const missingImpl = ['start_practice', 'practice_started', 'tutorial_practice', 'stats_eligible']
    .filter((x) => !implementation.includes(x));
  if (missingImpl.length) {
    record('M4-IMPL', 'BLOCKED', `server source has no practice implementation: ${missingImpl.join(', ')}`);
    return false;
  }
  record('M4-PC', 'PASS', 'practice message, mode, eligibility, composition and formal-round contract documented');
  return true;
}

function waitFor(ws, predicate, label, ms = timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.removeEventListener('message', onMessage); reject(new Error(`timeout: ${label}`)); }, ms);
    function onMessage(event) { let m; try { m = JSON.parse(String(event.data)); } catch { return; } if (!predicate(m)) return; clearTimeout(timer); ws.removeEventListener('message', onMessage); resolve(m); }
    ws.addEventListener('message', onMessage);
  });
}

function send(ws, type, payload, token, extra = {}) {
  ws.send(JSON.stringify({ type, player_token: token, ts: Math.floor(Date.now() / 1000), action_id: randomUUID(), payload, ...extra }));
}

async function connect() {
  const ws = new WebSocket(url);
  await new Promise((resolve, reject) => { const t = setTimeout(() => reject(new Error('open timeout')), timeoutMs); ws.addEventListener('open', () => { clearTimeout(t); resolve(); }, { once: true }); ws.addEventListener('error', () => { clearTimeout(t); reject(new Error('WebSocket connection failed')); }, { once: true }); });
  return ws;
}

async function liveProbe() {
  const completed = process.env.M4_COMPLETED_TOKEN;
  if (!completed) { record('M4-F03', 'BLOCKED', 'M4_COMPLETED_TOKEN is not set; no completed tutorial fixture'); return; }
  let ws;
  try {
    ws = await connect();
    const fresh = randomUUID();
    let w = waitFor(ws, (m) => m.type === 'error' || m.type === 'practice_started', 'incomplete start');
    send(ws, 'start_practice', {}, fresh);
    const denied = await w;
    record('M4-P01', denied.type === 'error' && typeof denied.payload?.code === 'string', `incomplete identity response=${denied.type}/${denied.payload?.code || '-'}`);

    w = waitFor(ws, (m) => ['error', 'practice_started', 'game_started'].includes(m.type), 'practice start');
    send(ws, 'start_practice', {}, completed);
    const started = await w;
    if (started.type === 'error') { record('M4-P02..P04', 'BLOCKED', `completed fixture rejected: ${started.payload?.code || 'error'}`); return; }
    const p = started.payload || {};
    const roomId = p.room_id || p.roomId;
    record('M4-P02', started.type === 'practice_started' && typeof roomId === 'string' && p.room_mode === 'tutorial_practice' && p.stats_eligible === false, `practice_started=${JSON.stringify(p)}`);
    const duplicateWait = waitFor(ws, (m) => ['practice_started', 'error', 'game_started'].includes(m.type), 'duplicate practice');
    send(ws, 'start_practice', {}, completed);
    const duplicate = await duplicateWait;
    const duplicateRoom = duplicate.payload?.room_id || duplicate.payload?.roomId;
    record('M4-P03', duplicate.type === 'error' || duplicateRoom === roomId, `duplicate response=${duplicate.type}, room=${duplicateRoom || '-'}`);

    const updateWait = waitFor(ws, (m) => m.type === 'room_update' || m.type === 'game_started' || m.type === 'error', 'practice room');
    const first = started.type === 'game_started' ? started : await updateWait;
    const players = first.payload?.players || first.payload?.public_state?.players || [];
    const bots = players.filter((x) => x.is_bot);
    record('M4-P04', players.length === 2 && bots.length === 1 && bots[0].difficulty === 'easy', `players=${players.length}, bots=${JSON.stringify(bots)}`);
    record('M4-G01', first.type === 'game_started' && first.payload?.room_mode === 'tutorial_practice' && first.payload?.stats_eligible === false, `game_started mode=${first.payload?.room_mode || '-'} eligible=${first.payload?.stats_eligible}`);
    record('M4-G02/M4-R01/R02', 'BLOCKED', 'full formal-turn and reconnect probe requires server practice routing and a stable live fixture; no unsupported PASS inferred');
    record('M4-G03/M4-S01/M4-N01/M4-B01/M4-B02/M4-I01', 'BLOCKED', 'dependent live assertions not run after incomplete practice implementation/fixture');
  } catch (e) { record('M4-ENV-WS', 'BLOCKED', e.message); }
  finally { try { ws?.close(); } catch {} }
}

record('M4-FINAL-MODEL', 'BLOCKED', 'guest tutorial is client-only; start_practice is forbidden and this server-practice probe is not an acceptance path');
const pass = results.filter((x) => x.status === 'PASS').length;
const fail = results.filter((x) => x.status === 'FAIL').length;
const blocked = results.filter((x) => x.status === 'BLOCKED').length;
console.log(`M4 summary: PASS=${pass} FAIL=${fail} BLOCKED=${blocked} TOTAL=${results.length}`);
process.exitCode = fail ? 1 : blocked ? 2 : 0;
