import { randomUUID } from 'node:crypto';

const ARGS = process.argv.slice(2);
const WS_URL = ARGS.find((arg) => !arg.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const clients = new Set();
const results = [];

function log(message) {
  console.log(`[${new Date().toISOString()}] ${message}`);
}

function record(id, ok, detail) {
  results.push(ok);
  log(`${id} ${ok ? 'PASS' : 'FAIL'}: ${detail}`);
}

function makeClient(name) {
  const c = { name, ws: null, id: null, token: null, roomId: null, closed: false, events: new Set() };
  clients.add(c);
  c.connect = () => new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    c.ws = ws;
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', () => reject(new Error(`${name}: websocket connection failed`)), { once: true });
    ws.addEventListener('close', () => { c.closed = true; });
    ws.addEventListener('message', (event) => {
      let message;
      try {
        message = JSON.parse(typeof event.data === 'string' ? event.data : event.data.toString());
      } catch {
        return;
      }
      const payload = message.payload || {};
      if (message.type === 'room_created' || message.type === 'room_joined') {
        c.id = payload.player_id || c.id;
        c.token = payload.token || c.token;
        c.roomId = payload.room_id || c.roomId;
      }
      for (const handler of [...c.events]) handler(message);
    });
  });
  c.waitFor = (type, timeout = 5000, predicate = () => true) => new Promise((resolve, reject) => {
    const onMessage = (message) => {
      if (message.type !== type || !predicate(message)) return;
      clearTimeout(timer);
      c.events.delete(onMessage);
      resolve(message);
    };
    const timer = setTimeout(() => {
      c.events.delete(onMessage);
      reject(new Error(`${name}: timeout waiting for ${type}`));
    }, timeout);
    c.events.add(onMessage);
  });
  c.send = (type, payload = {}) => c.ws.send(JSON.stringify({
    type,
    room_id: c.roomId || undefined,
    player_id: c.id || undefined,
    action_id: randomUUID(),
    ts: Math.floor(Date.now() / 1000),
    payload,
  }));
  c.close = () => {
    try { c.ws?.close(); } catch { /* cleanup is best effort */ }
  };
  return c;
}

async function create(c, name) {
  const created = c.waitFor('room_created');
  c.send('create_room', { player_name: name });
  await created;
}

async function staleReconnectCanCreate() {
  const retry = makeClient('stale-retry');
  await retry.connect();
  const credentials = { roomId: `missing-${randomUUID().slice(0, 8)}`, id: `missing-${randomUUID().slice(0, 8)}` };
  retry.roomId = credentials.roomId;
  retry.id = credentials.id;
  const failed = retry.waitFor('error', 5000, (message) => message.payload?.code === 'error');
  retry.send('reconnect', { room_id: credentials.roomId, player_id: credentials.id, token: credentials.token });
  await failed;
  const created = retry.waitFor('room_created');
  retry.send('create_room', { player_name: 'Issue1Fresh' });
  await created;
  record('ISSUE1-01', retry.roomId !== credentials.roomId,
    `failed reconnect did not block create_room (new room=${retry.roomId})`);
}

async function validRoomRejectsDuplicateCreate() {
  const c = makeClient('duplicate');
  await c.connect();
  await create(c, 'Issue1Duplicate');
  const roomId = c.roomId;
  const rejected = c.waitFor('error', 5000, (message) => message.payload?.code === 'already_in_room');
  c.send('create_room', { player_name: 'ShouldNotCreate' });
  await rejected;
  record('ISSUE1-02', c.roomId === roomId, `duplicate create_room rejected; room=${roomId}`);
}

async function reconnectWithinGraceRestoresState() {
  const host = makeClient('grace-host');
  const guest = makeClient('grace-guest');
  await host.connect();
  await create(host, 'Issue1Host');
  await guest.connect();
  const joined = guest.waitFor('room_joined');
  guest.roomId = host.roomId;
  guest.send('join_room', { room_id: host.roomId, player_name: 'Issue1Guest' });
  await joined;

  for (const player of [host, guest]) {
    const update = player.waitFor('room_update', 5000, (message) =>
      (message.payload?.players || []).some((entry) => entry.id === player.id));
    player.send('ready', { ready: true });
    await update;
  }
  const started = host.waitFor('game_started');
  host.send('start_game', {});
  await started;

  const credentials = { roomId: guest.roomId, id: guest.id, token: guest.token };
  const disconnected = host.waitFor('room_update', 10000, (message) =>
    (message.payload?.players || []).some((entry) => entry.id === guest.id && entry.connected === false));
  guest.close();
  await disconnected;

  const retry = makeClient('grace-retry');
  await retry.connect();
  retry.roomId = credentials.roomId;
  retry.id = credentials.id;
  const restored = retry.waitFor('game_started', 10000);
  const joinedAgain = retry.waitFor('room_joined', 10000);
  retry.send('reconnect', { room_id: credentials.roomId, player_id: credentials.id, token: credentials.token });
  await joinedAgain;
  const snapshot = await restored;
  record('ISSUE1-03', Boolean(snapshot.payload?.private_state),
    'disconnect followed by reconnect within grace restored private_state');
}

async function main() {
  log(`issue1 regression against ${WS_URL}`);
  await staleReconnectCanCreate();
  await validRoomRejectsDuplicateCreate();
  await reconnectWithinGraceRestoresState();
  const passed = results.filter(Boolean).length;
  log(`=== SUMMARY: ${passed}/${results.length} PASS ===`);
  console.log(passed === results.length ? 'ISSUE1_REGRESSION PASS' : 'ISSUE1_REGRESSION FAIL');
  process.exitCode = passed === results.length ? 0 : 1;
}

main().catch((error) => {
  log(`fatal: ${error.stack || error.message}`);
  console.log('ISSUE1_REGRESSION FAIL');
  process.exitCode = 1;
}).finally(() => {
  for (const client of clients) client.close();
});
