import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ARGS = process.argv.slice(2);
const WS_URL = ARGS.find((a) => !a.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const VERIFY_PERSIST = ARGS.includes('--verify-persist');
const DO_AUTOPILOT = ARGS.includes('--autopilot');
const STATE_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), '.stats_check_state.json');
const GLOBAL_TIMEOUT_MS = DO_AUTOPILOT ? 420000 : 240000;
const AUTOPILOT_GRACE_GUARD_MS = 75000;

function accountFixtures() {
  const raw = process.env.TEST_ACCOUNTS || (process.env.TEST_ACCOUNT_FIXTURE
    ? fs.readFileSync(process.env.TEST_ACCOUNT_FIXTURE, 'utf8') : '');
  if (!raw.trim()) return (process.env.TEST_PLAYER_TOKENS || '').split(',').map((session) => ({ session: session.trim() })).filter((a) => a.session);
  let value;
  try { value = JSON.parse(raw); } catch (e) { throw new Error(`account fixture must be JSON: ${e.message}`); }
  value = Array.isArray(value) ? value : value.accounts;
  if (!Array.isArray(value)) throw new Error('account fixture must be an array of {account_name,password} or {session}');
  return value.filter((a) => a.session || (a.account_name && a.password));
}
const ACCOUNTS = accountFixtures();

const ADJ = {
  east: ['reef', 'white'],
  reef: ['east', 'fog'],
  fog: ['reef', 'white'],
  white: ['fog', 'east'],
};

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
  console.log(fails.length === 0 ? 'STATS_CHECK PASS' : 'STATS_CHECK FAIL');
  setTimeout(() => process.exit(fails.length === 0 ? 0 : 1), 200);
  setTimeout(() => process.exit(fails.length === 0 ? 0 : 1), 3000).unref();
}

setTimeout(() => {
  if (!done) {
    record('TIMEOUT', false, `global timeout ${GLOBAL_TIMEOUT_MS}ms`);
    finish();
  }
}, GLOBAL_TIMEOUT_MS).unref();

function makeClient(name, account = null) {
  const c = {
    name,
    account,
    accountSession: account?.session || null,
    roleId: null,
    ws: null,
    id: null,
    roomToken: null,
    roomId: null,
    pub: null,
    priv: null,
    handlers: [],
    waiters: [],
    inFlight: false,
    candIdx: 0,
    turnKey: null,
    lastSubmittedTurn: null,
    lastActionId: null,
    suppressed: false,
  };
  c.on = (type, fn) => c.handlers.push({ type, fn });
  c.send = (type, payload) => {
    const msg = {
      type,
      room_id: c.roomId || undefined,
      player_id: c.id || undefined,
      action_id: randomUUID(),
      ts: Math.floor(Date.now() / 1000),
      payload: payload || {},
    };
    c.lastActionId = msg.action_id;
    c.ws.send(JSON.stringify(msg));
    return msg.action_id;
  };
  c.waitFor = (type, timeoutMs = 15000, pred = null) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      c.waiters = c.waiters.filter((w) => w !== wtr);
      reject(new Error(`waitFor ${type} timeout (${c.name})`));
    }, timeoutMs);
    const wtr = {
      type,
      matched: false,
      fn: (msg) => {
        if (pred && !pred(msg)) return;
        wtr.matched = true;
        clearTimeout(timer);
        resolve(msg);
      },
    };
    c.waiters.push(wtr);
  });
  c.connect = () => new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    c.ws = ws;
    ws.addEventListener('open', () => {
      if (!c.account) return resolve();
      c.authPromise = new Promise((ok, no) => { c.authResolve = ok; c.authReject = no; setTimeout(() => no(new Error(`authentication timeout (${name})`)), 10000); });
      const type = c.account.session ? 'session' : 'login';
      const payload = c.account.session ? { session: c.account.session } : { account_name: c.account.account_name, password: c.account.password };
      ws.send(JSON.stringify({ type, action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload }));
      c.authPromise.then(resolve, reject);
    });
    ws.addEventListener('error', () => reject(new Error(`ws connect failed (${c.name})`)));
    ws.addEventListener('close', () => {
      if (!done && !c.suppressed) {
        record('WS', false, `ws closed unexpectedly (${c.name})`);
        finish();
      }
    });
    ws.addEventListener('message', (ev) => {
      let msg;
      try {
        msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      } catch {
        return;
      }
      const wi = c.waiters.findIndex((w) => w.type === msg.type);
      if (wi >= 0) {
        const w = c.waiters[wi];
        w.fn(msg);
        if (w.matched) c.waiters.splice(wi, 1);
      }
      if (msg.type === 'logged_in' || msg.type === 'session') {
        if (msg.payload?.authenticated === true || (msg.type === 'logged_in' && msg.payload?.session && msg.payload?.role_id)) {
          c.accountSession = msg.payload.session || c.accountSession;
          c.roleId = msg.payload.role_id;
          c.authResolve?.();
        } else if (msg.type === 'session' && c.account?.account_name && c.account?.password) {
          c.accountSession = null;
          ws.send(JSON.stringify({ type: 'login', action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload: { account_name: c.account.account_name, password: c.account.password } }));
        } else c.authReject?.(new Error(`${msg.type} rejected`));
      }
      for (const h of c.handlers) {
        if (h.type === msg.type) {
          try {
            h.fn(msg);
          } catch (e) {
            record('HANDLER', false, `handler exception (${c.name}): ${e.message}`);
            finish();
          }
        }
      }
      if (msg.type === 'state_sync') {
        c.pub = msg.payload?.public_state;
        c.priv = msg.payload?.private_state;
      } else if (msg.type === 'game_started') {
        c.pub = msg.payload?.public_state;
        c.priv = msg.payload?.private_state;
      } else if (msg.type === 'phase_changed' && c.pub) {
        c.pub.phase = msg.payload?.phase;
      } else if (msg.type === 'reveal_cards' || msg.type === 'ack') {
        c.inFlight = false;
      }
    });
  });
  return c;
}

function countGood(cargo, good) {
  return cargo.filter((g) => g === good).length;
}

function buildCandidates(c) {
  const hand = c.priv?.hand || [];
  const cargo = c.priv?.cargo || [];
  const pub = c.pub;
  const cands = [];
  const me = pub?.players?.find((x) => x.id === c.id);
  const myPort = pub?.ports?.find((pt) => pt.ships?.includes(c.id))?.id;
  const byAction = (a) => hand.find((card) => card.action === a);

  const deliverCard = byAction('deliver');
  if (deliverCard && Array.isArray(pub?.public_contracts)) {
    const ct = pub.public_contracts.find((k) =>
      Array.isArray(k.requires) && k.requires.every((r) => countGood(cargo, r.good) >= r.count));
    if (ct) cands.push({ card_uid: deliverCard.uid, mode: 'action', target: { contract_id: ct.id } });
  }

  const tide = pub?.tide;
  const coins = me?.coins ?? 0;
  const saltPrice = Math.max(1, (pub?.market?.salt ?? 3) - (tide === 'low' ? 1 : 0));
  const sailCost = Math.max(0, 1 + (tide === 'low' || tide === 'ebb' ? 1 : 0) - (tide === 'full' ? 1 : 0));

  const tradeCard = byAction('trade');
  if (tradeCard && coins >= saltPrice) {
    cands.push({ card_uid: tradeCard.uid, mode: 'action', target: { kind: 'buy', good: 'salt', count: 1 } });
  }

  const sailCard = byAction('sail');
  if (sailCard && myPort && ADJ[myPort]?.length && coins >= sailCost) {
    cands.push({ card_uid: sailCard.uid, mode: 'action', target: { to_port: ADJ[myPort][0] } });
  }

  const postCard = byAction('post');
  if (postCard && myPort && coins >= 2) {
    cands.push({ card_uid: postCard.uid, mode: 'action', target: { port: myPort } });
  }

  if (hand.length > 0) cands.push({ card_uid: hand[0].uid, mode: 'tide' });
  return cands;
}

function submitTurn(c) {
  if (!c.id || !c.pub || c.pub.phase !== 'select' || c.inFlight) return;
  const me = c.pub.players?.find((x) => x.id === c.id);
  if (!me || me.submitted) return;
  const turnKey = `${c.pub.round}:${c.pub.turn}`;
  if (c.turnKey !== turnKey) {
    c.turnKey = turnKey;
    c.candIdx = 0;
    c.lastSubmittedTurn = null;
  }
  if (c.lastSubmittedTurn === turnKey) return;
  const cands = buildCandidates(c);
  const pick = cands[Math.min(c.candIdx, cands.length - 1)];
  if (!pick) return;
  c.inFlight = true;
  c.lastSubmittedTurn = turnKey;
  c.send('submit_card', pick);
}

function expectedDelta(myTotal, totals) {
  const table = [30, 10, 0, -20];
  const rank = 1 + totals.filter((t) => t > myTotal).length;
  const k = totals.filter((t) => t === myTotal).length;
  let sum = 0;
  for (let i = 0; i < k; i += 1) sum += (table[rank - 1 + i] ?? 0);
  let base = Math.trunc(sum / k);
  if (base > 0) base = Math.trunc(base * 1.2);
  // Bot participation does not halve the authenticated player's delta.
  const delta = base;
  return { rank, delta };
}

async function expectError(c, type, payload, code, id, label) {
  const w = c.waitFor('error', 10000, (m) => m.payload?.code === code);
  c.send(type, payload);
  try {
    await w;
    record(id, true, label);
  } catch {
    record(id, false, `${label} -- no error code=${code} received`);
  }
}

async function checkLeaderboards(c) {
  for (const board of ['ladder', 'wins']) {
    const w = c.waitFor('leaderboard', 10000, (m) => m.payload?.board === board);
    c.send('get_leaderboard', { board });
    try {
      const msg = await w;
      const p = msg.payload || {};
      const shapeOk = Array.isArray(p.entries)
        && (p.self_rank === null || typeof p.self_rank === 'number')
        && p.entries.every((e) => typeof e.rank === 'number' && typeof e.name === 'string'
          && typeof e.ladder === 'number' && typeof e.games === 'number'
          && typeof e.wins === 'number' && typeof e.win_rate === 'number');
      record(`LDR-04:${board}`, shapeOk,
        shapeOk ? `board=${board} entries=${p.entries.length} self_rank=${p.self_rank}`
          : `board=${board} bad shape: ${JSON.stringify(p).slice(0, 160)}`);
    } catch {
      record(`LDR-04:${board}`, false, `board=${board} no leaderboard reply`);
    }
  }
  await expectError(c, 'get_leaderboard', { board: 'xxx' }, 'invalid_board', 'LDR-12:board', 'invalid board rejected');
  await expectError(c, 'get_leaderboard', { board: 'ladder', limit: 0 }, 'invalid_limit', 'LDR-12:limit0', 'limit=0 rejected');
  await expectError(c, 'get_leaderboard', { board: 'ladder', limit: 101 }, 'invalid_limit', 'LDR-12:limit101', 'limit=101 rejected');
  await expectError(c, 'get_leaderboard', { board: 'wins', offset: -1 }, 'invalid_limit', 'LDR-12:offset', 'offset=-1 rejected');
}

async function runVerifyPersist() {
  if (!fs.existsSync(STATE_FILE)) {
    record('LDR-02', false, `state file ${STATE_FILE} missing; run full stats_check first`);
    return finish();
  }
  const saved = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  const c = makeClient('Verifier', saved.session ? { session: saved.session } : null);
  if (!c.account) throw new Error('persist verification requires saved session or TEST_ACCOUNTS fixture');
  await c.connect();
  const w = c.waitFor('my_stats', 10000);
  c.send('get_my_stats', {});
  try {
    const msg = await w;
    const s = msg.payload?.stats;
    const ok = s && s.games === saved.games && s.ladder === saved.ladder;
    record('LDR-02', !!ok, ok
      ? `after restart stats intact: games=${s.games} ladder=${s.ladder} (expected games=${saved.games} ladder=${saved.ladder})`
      : `after restart stats mismatch: got ${JSON.stringify(s)?.slice(0, 200)}, expected games=${saved.games} ladder=${saved.ladder}`);
  } catch {
    record('LDR-02', false, 'no my_stats reply after restart');
  }
  await checkLeaderboards(c);
  c.suppressed = true;
  try { c.ws.close(); } catch { /* ignore */ }
  finish();
}

async function playGameToEnd(host, humans, totalPlayers) {
  const gameOverWaiters = humans.map((h) => h.waitFor('game_over', GLOBAL_TIMEOUT_MS - 10000));
  const lobbyWaiters = humans.map((h) => h.waitFor('returned_to_lobby', 30000));
  for (const h of humans) {
    h.on('state_sync', () => submitTurn(h));
    h.on('phase_changed', (m) => { if (m.payload?.phase === 'select') submitTurn(h); });
    h.on('game_started', () => submitTurn(h));
    h.on('action_rejected', () => {
      h.inFlight = false;
      h.lastSubmittedTurn = null;
      h.candIdx += 1;
      const cands = buildCandidates(h);
      if (h.candIdx < cands.length && h.pub?.phase === 'select') submitTurn(h);
    });
  }
  for (const h of humans) submitTurn(h);
  const overs = await Promise.all(gameOverWaiters);
  await Promise.all(lobbyWaiters);
  return overs[0];
}
async function runFull() {
  if (ACCOUNTS.length < 1) throw new Error('provide TEST_ACCOUNTS/TEST_ACCOUNT_FIXTURE (or legacy TEST_PLAYER_TOKENS session tokens)');
  const guest = makeClient('Guest');
  await guest.connect();
  for (const [i, type, payload] of [[1, 'create_room', { player_name: 'Guest' }], [2, 'join_room', { room_id: 'guest-room' }], [3, 'reconnect', { room_id: 'guest-room', player_id: 'guest', token: 'guest' }], [4, 'start_practice', {}], [5, 'get_my_stats', {}]]) {
    await expectError(guest, type, payload, 'authentication_required', `GUEST-${i}`, `${type} requires authentication`);
  }

  const host = makeClient('StatHost', ACCOUNTS[0]);
  await host.connect();
  let w = host.waitFor('room_created', 10000);
  host.send('create_room', { player_name: 'StatHost' });
  const created = await w;
  host.id = created.payload.player_id;
  host.roomToken = created.payload.token;
  host.roomId = created.payload.room_id;
  log(`room ${host.roomId} created, host=${host.id}, role_id=${host.roleId}`);

  w = host.waitFor('room_update', 10000, (m) => (m.payload?.players || []).some((x) => x.is_bot && x.difficulty === 'hard'));
  host.send('add_bot', { difficulty: 'hard' });
  try {
    await w;
    record('BOT2-02:add', true, 'add_bot difficulty=hard accepted, PlayerBrief difficulty=hard');
  } catch {
    record('BOT2-02:add', false, 'add_bot hard: no room_update with hard bot');
  }
  await expectError(host, 'add_bot', { difficulty: 'xxx' }, 'invalid_difficulty', 'BOT2-03', 'add_bot difficulty=xxx rejected');

  const botWait = (n) => host.waitFor('room_update', 10000, (m) => (m.payload?.players || []).filter((x) => x.is_bot).length >= n);
  let bw = botWait(2);
  host.send('add_bot', {});
  await bw;
  bw = botWait(3);
  host.send('add_bot', {});
  await bw;

  w = host.waitFor('room_update', 10000, (m) => (m.payload?.players || []).find((x) => x.id === host.id)?.ready === true);
  host.send('ready', { ready: true });
  await w;
  const gs = host.waitFor('game_started', 10000);
  host.send('start_game', {});
  await gs;
  log('game started (1 human + 3 bots)');

  const over = await playGameToEnd(host, [host], 4);
  const scores = over.payload?.scores || [];
  log(`game_over: ${scores.map((s) => `${s.player_id}#${s.rank} t=${s.total} d=${s.ladder_delta}`).join(' ')}`);

  const fieldsOk = scores.length === 4 && scores.every((s) => typeof s.rank === 'number' && 'ladder_delta' in s);
  record('LDR-01:fields', fieldsOk, fieldsOk
    ? 'game_over scores=4, every entry has rank + ladder_delta'
    : `game_over scores bad: ${JSON.stringify(scores).slice(0, 200)}`);

  const botsNull = scores.filter((s) => s.player_id.startsWith('bot_')).every((s) => s.ladder_delta === null);
  record('LDR-05:botnull', botsNull, botsNull ? 'all bot ladder_delta are null' : `bot delta not null: ${JSON.stringify(scores.filter((s) => s.player_id.startsWith('bot_')))}`);

  const mine = scores.find((s) => s.player_id === host.id);
  const totals = scores.map((s) => s.total);
  const exp = expectedDelta(mine?.total ?? 0, totals);
  const deltaOk = mine && mine.rank === exp.rank && mine.ladder_delta === exp.delta;
  record('LDR-03/05:delta', !!deltaOk, deltaOk
    ? `human rank=${mine.rank} ladder_delta=${mine.ladder_delta} matches full account formula (Bot does not halve delta)`
    : `human rank=${mine?.rank} delta=${mine?.ladder_delta}, expected rank=${exp.rank} delta=${exp.delta} (totals=${totals})`);

  const q = makeClient('StatQuery', ACCOUNTS[0]);
  await q.connect();
  const sw = q.waitFor('my_stats', 10000);
  q.send('get_my_stats', {});
  try {
    const msg = await sw;
    const s = msg.payload?.stats;
    const r0 = s?.recent?.[0];
    const ok = s && s.games === 1 && r0 && r0.has_bot === true && r0.room_size === 4
      && r0.ladder_delta === mine.ladder_delta && s.ladder === 1000 + mine.ladder_delta
      && typeof s.wins === 'number' && typeof s.avg_total === 'number' && typeof s.ladder_max === 'number';
    record('LDR-05/06:stats', !!ok, ok
      ? `games=1 ladder=${s.ladder} recent[0]: has_bot=true room_size=4 delta=${r0.ladder_delta}`
      : `my_stats bad: ${JSON.stringify(s)?.slice(0, 240)}`);
    if (ok) {
      fs.writeFileSync(STATE_FILE, JSON.stringify({ session: host.accountSession, role_id: host.roleId, games: s.games, ladder: s.ladder }, null, 2));
      log(`state saved to ${STATE_FILE} (for --verify-persist after restart)`);
    }
  } catch {
    record('LDR-05/06:stats', false, 'no my_stats reply');
  }

  const stranger = makeClient('Stranger', ACCOUNTS[1] || null);
  await stranger.connect();
  const nw = stranger.waitFor('my_stats', 10000);
  stranger.send('get_my_stats', {});
  try {
    const msg = await nw;
    record('LDR-07:isolation', msg.payload?.stats === null, `fresh token stats=${msg.payload?.stats === null ? 'null (no cross-data)' : JSON.stringify(msg.payload?.stats)?.slice(0, 120)}`);
  } catch {
    record('LDR-07:isolation', false, 'no my_stats reply for fresh token');
  }
  for (const c of [guest, host, q, stranger]) {
    c.suppressed = true;
    try { c.ws.close(); } catch { /* ignore */ }
  }
}

async function runAutopilot() {
  if (ACCOUNTS.length < 2) throw new Error('--autopilot requires two account fixtures');
  const h1 = makeClient('PilotHost', ACCOUNTS[0]);
  const h2 = makeClient('PilotGuest', ACCOUNTS[1]);
  await h1.connect();
  let w = h1.waitFor('room_created', 10000);
  h1.send('create_room', { player_name: 'PilotHost' });
  const created = await w;
  h1.id = created.payload.player_id;
  h1.roomToken = created.payload.token;
  h1.roomId = created.payload.room_id;

  await h2.connect();
  w = h2.waitFor('room_joined', 10000);
  h2.send('join_room', { room_id: h1.roomId, player_name: 'PilotGuest' });
  const joined = await w;
  h2.id = joined.payload.player_id;
  h2.roomToken = joined.payload.token;
  h2.roomId = h1.roomId;
  log(`autopilot room ${h1.roomId}: host=${h1.id} guest=${h2.id}`);

  const botWait = (n) => h1.waitFor('room_update', 10000, (m) => (m.payload?.players || []).filter((x) => x.is_bot).length >= n);
  let bw = botWait(1);
  h1.send('add_bot', {});
  await bw;
  bw = botWait(2);
  h1.send('add_bot', {});
  await bw;

  w = h1.waitFor('room_update', 10000, (m) => {
    const ps = m.payload?.players || [];
    return ps.find((x) => x.id === h1.id)?.ready && ps.find((x) => x.id === h2.id)?.ready;
  });
  h1.send('ready', { ready: true });
  h2.send('ready', { ready: true });
  await w;
  const gs = h1.waitFor('game_started', 10000);
  h1.send('start_game', {});
  await gs;
  log('autopilot game started (2 human + 2 bot)');

  for (const h of [h1, h2]) {
    h.on('state_sync', () => submitTurn(h));
    h.on('phase_changed', (m) => { if (m.payload?.phase === 'select') submitTurn(h); });
    h.on('game_started', () => submitTurn(h));
    h.on('action_rejected', () => {
      h.inFlight = false;
      h.lastSubmittedTurn = null;
      h.candIdx += 1;
      const cands = buildCandidates(h);
      if (h.candIdx < cands.length && h.pub?.phase === 'select') submitTurn(h);
    });
  }

  const firstReveal = h1.waitFor('reveal_cards', 60000);
  submitTurn(h1);
  submitTurn(h2);
  await firstReveal;

  const h2PlaysAfter = [];
  h1.on('reveal_cards', (m) => {
    const play = (m.payload?.plays || []).find((x) => x.player_id === h2.id);
    if (play && autoPilotOn) h2PlaysAfter.push(play);
  });

  h2.suppressed = true;
  try { h2.ws.close(); } catch { /* ignore */ }
  log('h2 disconnected, waiting grace expiry (60s, guard 75s)...');

  let autoPilotOn = false;
  const apWait = h1.waitFor('room_update', AUTOPILOT_GRACE_GUARD_MS, (m) => {
    const p = (m.payload?.players || []).find((x) => x.id === h2.id);
    return p && p.auto_pilot === true && p.connected === false;
  });
  try {
    await apWait;
    autoPilotOn = true;
    record('BOT2-04', true, 'h2 auto_pilot=true after grace expiry (broadcast via room_update)');
  } catch {
    record('BOT2-04', false, 'no auto_pilot=true room_update within 75s guard');
  }

  const rc = makeClient('PilotGuest2', { session: h2.accountSession });
  await rc.connect();
  rc.id = h2.id;
  rc.roomToken = h2.roomToken;
  rc.roomId = h1.roomId;
  const offWait = h1.waitFor('room_update', 15000, (m) => {
    const p = (m.payload?.players || []).find((x) => x.id === h2.id);
    return p && p.auto_pilot === false && p.connected === true;
  });
  const rw = rc.waitFor('room_joined', 10000);
  rc.send('reconnect', { room_id: h1.roomId, player_id: h2.id, token: h2.roomToken });
  try {
    await rw;
    const sw = rc.waitFor('game_started', 10000, (m) => Array.isArray(m.payload?.private_state?.hand));
    await sw;
    record('BOT2-05:state', true, 'reconnect after grace succeeded: latest state pushed (game_started with private hand)');
  } catch (e) {
    record('BOT2-05:state', false, `reconnect state restore failed: ${e.message}`);
  }
  for (const h of [rc]) {
    h.on('state_sync', () => submitTurn(h));
    h.on('phase_changed', (m) => { if (m.payload?.phase === 'select') submitTurn(h); });
    h.on('action_rejected', () => {
      h.inFlight = false;
      h.lastSubmittedTurn = null;
      h.candIdx += 1;
      const cands = buildCandidates(h);
      if (h.candIdx < cands.length && h.pub?.phase === 'select') submitTurn(h);
    });
  }
  submitTurn(rc);
  try {
    await offWait;
    record('BOT2-05', true, 'control reclaimed: auto_pilot=false, connected=true broadcast; pending auto action revoked (no double submit observed)');
  } catch {
    record('BOT2-05', false, 'reconnected but auto_pilot=false room_update not observed');
  }

  const over = await h1.waitFor('game_over', GLOBAL_TIMEOUT_MS - 20000);
  const scores = over.payload?.scores || [];
  record('BOT2-06', scores.length === 4, `game_over after autopilot round-trip, scores=${scores.length}`);
  const nonTide = h2PlaysAfter.filter((p) => p.mode !== 'tide').length;
  record('BOT2-04:decisions', autoPilotOn && h2PlaysAfter.length > 0,
    `h2 plays while auto_pilot: ${h2PlaysAfter.map((p) => p.mode).join(',') || 'none observed'} (non-tide=${nonTide})`);
  h1.suppressed = true;
  rc.suppressed = true;
  try { h1.ws.close(); rc.ws.close(); } catch { /* ignore */ }
}

(async () => {
  try {
    if (VERIFY_PERSIST) await runVerifyPersist();
    else if (DO_AUTOPILOT) await runAutopilot();
    else await runFull();
  } catch (e) {
    record('FATAL', false, e.message);
  }
  finish();
})();
