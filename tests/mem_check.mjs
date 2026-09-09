import net from 'node:net';
import { randomUUID } from 'node:crypto';

const WS_URL = process.argv[2] || 'ws://127.0.0.1:9500/ws';
const URL_OBJ = new URL(WS_URL);
const HOST = URL_OBJ.hostname;
const PORT = Number(URL_OBJ.port || 9500);
const TCP_STORM_COUNT = 200;
const REPEAT_CREATE = 50;
const GLOBAL_TIMEOUT_MS = 120000;

let done = false;
const results = [];

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${ts()}] ${msg}`);
}

function record(id, ok, detail) {
  results.push({ id, ok, detail });
  log(`${id} ${ok ? 'PASS' : 'FAIL'}: ${detail}`);
}

function finish() {
  if (done) return;
  done = true;
  const fails = results.filter((r) => !r.ok);
  log(`=== SUMMARY: ${results.length - fails.length}/${results.length} PASS ===`);
  console.log(fails.length === 0 ? 'MEM_CHECK PASS' : 'MEM_CHECK FAIL');
  setTimeout(() => process.exit(fails.length === 0 ? 0 : 1), 200);
}

setTimeout(() => {
  if (!done) {
    log(`global timeout ${GLOBAL_TIMEOUT_MS}ms`);
    finish();
  }
}, GLOBAL_TIMEOUT_MS).unref();

function makeClient(name) {
  const c = {
    name,
    ws: null,
    id: null,
    token: null,
    roomId: null,
    handlers: [],
    closed: false,
  };
  c.on = (type, fn) => c.handlers.push({ type, fn });
  c.off = (type, fn) => {
    c.handlers = c.handlers.filter((h) => !(h.type === type && h.fn === fn));
  };
  c.send = (type, payload, roomId) => {
    const msg = {
      type,
      room_id: roomId || c.roomId || undefined,
      player_id: c.id || undefined,
      action_id: randomUUID(),
      ts: Math.floor(Date.now() / 1000),
      payload,
    };
    c.ws.send(JSON.stringify(msg));
  };
  c.waitFor = (type, timeoutMs, pred) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      c.off(type, fn);
      reject(new Error(`${name}: timeout waiting ${type} (${timeoutMs}ms)`));
    }, timeoutMs);
    const fn = (msg) => {
      if (pred && !pred(msg)) return;
      clearTimeout(timer);
      c.off(type, fn);
      resolve(msg);
    };
    c.on(type, fn);
  });
  c.connect = () => new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    c.ws = ws;
    ws.addEventListener('open', () => resolve());
    ws.addEventListener('error', (e) => reject(new Error(`${name}: ws error ${e.message || ''}`)));
    ws.addEventListener('close', () => {
      c.closed = true;
    });
    ws.addEventListener('message', (ev) => {
      let msg;
      try {
        msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      } catch {
        return;
      }
      const pl = msg.payload || {};
      if (msg.type === 'room_created' || msg.type === 'room_joined') {
        c.id = pl.player_id;
        c.token = pl.token;
        c.roomId = pl.room_id || c.roomId;
      }
      for (const h of [...c.handlers]) {
        if (h.type === msg.type) h.fn(msg);
      }
    });
  });
  c.close = () => {
    try { c.ws?.close(); } catch { /* ignore */ }
  };
  return c;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function listRooms(c) {
  const p = c.waitFor('room_list', 5000);
  c.send('list_rooms', {});
  const msg = await p;
  return msg.payload?.rooms || [];
}

async function mem05TcpStorm() {
  const half = Math.floor(TCP_STORM_COUNT / 2);
  await Promise.all(Array.from({ length: TCP_STORM_COUNT }, (_, i) => new Promise((resolve) => {
    const s = net.connect(PORT, HOST, () => {
      if (i < half) {
        s.write('GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n');
        setTimeout(() => { s.destroy(); resolve(); }, 10);
      } else {
        s.destroy();
        resolve();
      }
    });
    s.on('error', () => resolve());
  })));
  await sleep(1500);
  const probe = makeClient('probe');
  try {
    await probe.connect();
    const pongP = probe.waitFor('pong', 5000);
    probe.send('ping', {});
    await pongP;
    const createdP = probe.waitFor('room_created', 5000);
    probe.send('create_room', { player_name: 'MemProbe' });
    await createdP;
    record('MEM-05', true, `${TCP_STORM_COUNT} abnormal TCP conns (half mid-handshake) then ping+create_room ok, room=${probe.roomId}`);
    return probe;
  } catch (e) {
    record('MEM-05', false, `after TCP storm: ${e.message}`);
    probe.close();
    return null;
  }
}

async function mem02RepeatCreate(c) {
  if (!c) return;
  const roomId = c.roomId;
  const errors = [];
  const collector = (msg) => errors.push(msg);
  c.on('error', collector);
  for (let i = 0; i < REPEAT_CREATE; i += 1) {
    c.send('create_room', { player_name: 'Again' });
  }
  const deadline = Date.now() + 10000;
  while (errors.length < REPEAT_CREATE && Date.now() < deadline) await sleep(100);
  c.off('error', collector);
  const codes = errors.map((m) => m.payload?.code);
  const allAlready = errors.length === REPEAT_CREATE && codes.every((x) => x === 'already_in_room');
  if (!allAlready) {
    record('MEM-02', false, `expected ${REPEAT_CREATE}x error code=already_in_room, got ${errors.length} errors, codes=${JSON.stringify([...new Set(codes)])}`);
    return;
  }
  await sleep(500);
  const rooms = await listRooms(c);
  const mine = rooms.filter((r) => r.room_id === roomId);
  const ok = mine.length === 1;
  record('MEM-02', ok, ok
    ? `50x create_room -> 50x already_in_room; list_rooms has exactly 1 instance of room ${roomId} (total rooms=${rooms.length})`
    : `list_rooms duplicates: room ${roomId} appears ${mine.length} times (total rooms=${rooms.length})`);
}

async function mem08HostAloneLeaves(c, roomId) {
  if (!c) return;
  c.close();
  const watcher = makeClient('watcher');
  await watcher.connect();
  const deadline = Date.now() + 10000;
  let rooms = [];
  let gone = false;
  while (Date.now() < deadline) {
    rooms = await listRooms(watcher);
    if (!rooms.some((r) => r.room_id === roomId)) { gone = true; break; }
    await sleep(500);
  }
  watcher.close();
  record('MEM-08', gone, gone
    ? `lobby host (alone) disconnected -> room ${roomId} vanished from list_rooms`
    : `room ${roomId} still in list_rooms 10s after host disconnect (rooms=${JSON.stringify(rooms.map((r) => r.room_id))})`);
}

async function mem08HostTransfer() {
  const host = makeClient('hostB');
  const guest = makeClient('guestB');
  try {
    await host.connect();
    const createdP = host.waitFor('room_created', 5000);
    host.send('create_room', { player_name: 'HostB' });
    await createdP;
    const roomId = host.roomId;
    await guest.connect();
    const joinedP = guest.waitFor('room_joined', 5000);
    guest.send('join_room', { room_id: roomId, player_name: 'GuestB' });
    await joinedP;
    host.close();
    const upd = await guest.waitFor('room_update', 10000, (m) => {
      const list = m.payload?.players || [];
      return list.some((x) => x.id === guest.id && x.host === true);
    });
    const brief = (upd.payload?.players || []).find((x) => x.id === guest.id);
    record('MEM-08', true, `2-player lobby, host disconnected -> host transferred to guest (host=${brief.host}, players=${upd.payload.players.length})`);
    guest.close();
    return roomId;
  } catch (e) {
    record('MEM-08', false, `host transfer scenario failed: ${e.message}`);
    guest.close();
    host.close();
    return null;
  }
}

async function mem04OrphanCheck(baselineRooms, extraRoomIds) {
  await sleep(3000);
  const c = makeClient('sweeper');
  await c.connect();
  const rooms = await listRooms(c);
  c.close();
  const leftovers = rooms.filter((r) => !baselineRooms.includes(r.room_id) || extraRoomIds.includes(r.room_id));
  const created = rooms.filter((r) => !baselineRooms.includes(r.room_id));
  const ok = created.length === 0 && leftovers.every((r) => !extraRoomIds.includes(r.room_id));
  record('MEM-04', ok, ok
    ? `list_rooms back to baseline (${baselineRooms.length} room(s): [${baselineRooms.join(',') || '-'}]); no orphan rooms from this script`
    : `orphan rooms remain: ${JSON.stringify(rooms.map((r) => `${r.room_id}/${r.phase}`))}`);
}

async function main() {
  log(`mem_check against ${WS_URL}`);
  const base = makeClient('baseline');
  await base.connect();
  const baselineRooms = (await listRooms(base)).map((r) => r.room_id);
  base.close();
  log(`baseline rooms: [${baselineRooms.join(',') || '-'}]`);

  const probe = await mem05TcpStorm();
  const probeRoom = probe?.roomId;
  await mem02RepeatCreate(probe);
  await mem08HostAloneLeaves(probe, probeRoom);
  const transferRoom = await mem08HostTransfer();
  await mem04OrphanCheck(baselineRooms, [probeRoom, transferRoom].filter(Boolean));
  finish();
}

main().catch((e) => {
  log(`fatal: ${e.stack || e.message}`);
  finish();
});
