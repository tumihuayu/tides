import { randomUUID } from 'node:crypto';

const WS_URL = 'ws://127.0.0.1:9500/ws';
const BASE = 'http://127.0.0.1:9500';
const NAME = 'AdmCheck';
let roomId = null;
let myId = null;
let lastRoomUpdate = null;
let lastRoomList = null;
let botAdded = false;
let done = false;

function ts() { return new Date().toISOString(); }
function finish(ok, reason) {
  if (done) return;
  done = true;
  if (!ok) console.log(`[${ts()}] FAIL: ${reason}`);
  console.log(`[${ts()}] ${ok ? 'ADM-03 PASS' : 'ADM-03 FAIL'}`);
  try { ws.close(); } catch { /* ignore */ }
  setTimeout(() => process.exit(ok ? 0 : 1), 200);
  setTimeout(() => process.exit(ok ? 0 : 1), 3000).unref();
}
setTimeout(() => finish(false, 'timeout 30s'), 30000).unref();

function send(type, payload) {
  ws.send(JSON.stringify({
    type,
    room_id: roomId || undefined,
    player_id: myId || undefined,
    action_id: randomUUID(),
    ts: Math.floor(Date.now() / 1000),
    payload,
  }));
}

async function checkAdmin() {
  const res = await fetch(`${BASE}/admin/players`);
  if (res.status !== 200) return finish(false, `admin/players http ${res.status}`);
  const body = await res.json();
  const list = body.players;
  if (!Array.isArray(list)) return finish(false, 'players not array');
  if (list.length !== 2) return finish(false, `expected 2 players, got ${list.length}: ${JSON.stringify(list)}`);
  const reqFields = ['name', 'room_id', 'phase', 'is_bot', 'connected', 'auto_pilot'];
  for (const p of list) {
    for (const f of reqFields) {
      if (!(f in p)) return finish(false, `missing field ${f} in ${JSON.stringify(p)}`);
    }
    if (p.room_id !== roomId) return finish(false, `room_id mismatch: ${p.room_id} vs ${roomId}`);
  }
  const human = list.find((p) => p.name === NAME);
  const bot = list.find((p) => p.is_bot === true);
  if (!human) return finish(false, 'human player not found');
  if (!bot) return finish(false, 'bot not found');
  if (human.is_bot !== false) return finish(false, 'human marked as bot');
  if (human.connected !== true) return finish(false, 'human not connected');
  if (bot.connected !== true) return finish(false, 'bot not connected');
  const wsList = lastRoomList?.rooms?.find((r) => r.room_id === roomId || r.id === roomId);
  const updPlayers = lastRoomUpdate?.players || [];
  const updBot = updPlayers.find((x) => x.is_bot);
  const updMe = updPlayers.find((x) => x.name === NAME);
  if (!updMe) return finish(false, 'room_update missing human');
  if (!updBot) return finish(false, 'room_update missing bot');
  if (updBot.name !== bot.name) return finish(false, `bot name mismatch admin=${bot.name} ws=${updBot.name}`);
  console.log(`[${ts()}] admin players: ${JSON.stringify(list)}`);
  console.log(`[${ts()}] ws room_update players: ${JSON.stringify(updPlayers.map((x) => ({ name: x.name, is_bot: x.is_bot, connected: x.connected })))}`);
  if (wsList) console.log(`[${ts()}] ws list_rooms entry: ${JSON.stringify(wsList)}`);
  finish(true);
}

const ws = new WebSocket(WS_URL);
ws.onopen = () => send('create_room', { player_name: NAME });
ws.onerror = (e) => finish(false, `ws error ${e?.message || ''}`);
ws.onclose = () => { if (!done) finish(false, 'ws closed unexpectedly'); };
ws.onmessage = (ev) => {
  let msg;
  try { msg = JSON.parse(ev.data); } catch { return; }
  if (msg.type === 'error') return finish(false, `server error: ${ev.data}`);
  if (msg.type === 'room_created') {
    roomId = msg.payload?.room_id || msg.room_id;
    myId = msg.payload?.player_id || msg.player_id;
    console.log(`[${ts()}] room created: ${roomId} me=${myId}`);
    send('list_rooms', {});
    return;
  }
  if (msg.type === 'room_list') { lastRoomList = msg.payload || msg; return; }
  if (msg.type === 'room_update') {
    lastRoomUpdate = msg.payload || msg;
    if (!botAdded && myId) {
      botAdded = true;
      send('add_bot', {});
      console.log(`[${ts()}] add_bot sent`);
      return;
    }
    const bots = (lastRoomUpdate.players || []).filter((x) => x.is_bot);
    if (bots.length >= 1) {
      console.log(`[${ts()}] bot present in room_update`);
      checkAdmin();
    }
  }
};
