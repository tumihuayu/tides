import { randomUUID } from 'node:crypto';
import fs from 'node:fs';

const ARGS = process.argv.slice(2);
const BOT_ARG = ARGS.find((a) => a.startsWith('--bots='));
const BOT_COUNT = BOT_ARG ? Number.parseInt(BOT_ARG.split('=')[1], 10) : 0;
const WS_URL = ARGS.find((a) => !a.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const TOKEN_ARG = ARGS.find((a) => a.startsWith('--player-token='));
// TEST_PLAYER_TOKENS is retained for compatibility, but these are session tokens,
// not account names or room/player tokens.
const CONFIGURED_TOKENS = (TOKEN_ARG ? TOKEN_ARG.split('=').slice(1).join('=') : process.env.TEST_PLAYER_TOKENS || '')
  .split(',').map((token) => token.trim()).filter(Boolean);
function readAccounts() {
  const text = process.env.TEST_ACCOUNTS || (process.env.TEST_ACCOUNT_FIXTURE
    ? fs.readFileSync(process.env.TEST_ACCOUNT_FIXTURE, 'utf8') : '');
  if (!text.trim()) return CONFIGURED_TOKENS.map((session) => ({ session }));
  let value;
  try { value = JSON.parse(text); } catch (e) {
    console.log(`FAIL: TEST_ACCOUNTS/TEST_ACCOUNT_FIXTURE must be JSON (${e.message})`);
    process.exit(1);
  }
  if (!Array.isArray(value)) value = value.accounts;
  if (!Array.isArray(value)) {
    console.log('FAIL: account fixture must be a JSON array of {account_name,password} or {session}');
    process.exit(1);
  }
  return value.map((a) => ({ account_name: a.account_name, password: a.password, session: a.session }))
    .filter((a) => a.session || (a.account_name && a.password));
}
const ACCOUNTS = readAccounts();
if (ACCOUNTS.length === 0) {
  console.log('BLOCKED: provide TEST_ACCOUNTS=<JSON> or TEST_ACCOUNT_FIXTURE=<JSON file>; TEST_PLAYER_TOKENS are session tokens');
  process.exit(2);
}
if (BOT_COUNT === 0 && ACCOUNTS.length < 4) {
  console.log('BLOCKED: a 4-account formal battle requires four account fixtures');
  process.exit(2);
}
if (BOT_ARG && (!Number.isInteger(BOT_COUNT) || BOT_COUNT < 1 || BOT_COUNT > 3)) {
  console.log(`FAIL: --bots must be 1..3 (got ${BOT_ARG})`);
  process.exit(1);
}
const TOTAL_PLAYERS = BOT_COUNT > 0 ? 1 + BOT_COUNT : 4;
const GLOBAL_TIMEOUT_MS = 300000;
const MAX_CONSEC_ERRORS = 20;
const MAX_LOG_LINES = 100;
const NAMES = ['RoboA', 'RoboB', 'RoboC', 'RoboD'];

const ADJ = {
  east: ['reef', 'white'],
  reef: ['east', 'fog'],
  fog: ['reef', 'white'],
  white: ['fog', 'east'],
};

let logLines = 0;
let done = false;
let consecErrors = 0;
let rejectedCount = 0;
let errorCount = 0;
let roomId = null;
let joinedCount = 0;
let startedCount = 0;
let startSent = false;
let readySent = false;
let botsRequested = 0;
let roomListOk = false;
const players = [];

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  if (logLines >= MAX_LOG_LINES) return;
  logLines += 1;
  console.log(`[${ts()}] ${msg}`);
}

function stateSummary() {
  const lines = [`room=${roomId || '-'} errStreak=${consecErrors} rejected=${rejectedCount} errors=${errorCount}`];
  for (const p of players) {
    const me = p.pub?.players?.find((x) => x.id === p.id);
    lines.push(
      `${p.id || p.name}: phase=${p.pub?.phase ?? '-'} round=${p.pub?.round ?? '-'} turn=${p.pub?.turn ?? '-'} ` +
      `submitted=${me?.submitted ?? '-'} coins=${me?.coins ?? '-'} vp=${me?.vp ?? '-'} hand=${p.priv?.hand?.length ?? '-'} connected=${me?.connected ?? '-'}`
    );
  }
  return lines.join(' | ');
}

function finish(ok, reason) {
  if (done) return;
  done = true;
  if (ok) {
    console.log(`[${ts()}] SMOKE PASS`);
  } else {
    console.log(`[${ts()}] FAIL: ${reason}`);
    console.log(`[${ts()}] last state: ${stateSummary()}`);
    console.log(`[${ts()}] SMOKE FAIL`);
  }
  const code = ok ? 0 : 1;
  for (const p of players) {
    try { p.ws?.close(); } catch { /* ignore */ }
  }
  setTimeout(() => process.exit(code), 200);
  setTimeout(() => process.exit(code), 3000).unref();
}

setTimeout(() => finish(false, `global timeout ${GLOBAL_TIMEOUT_MS}ms`), GLOBAL_TIMEOUT_MS).unref();

function send(p, type, payload) {
  const msg = {
    type,
    room_id: roomId || undefined,
    player_id: p.id || undefined,
    action_id: randomUUID(),
    ts: Math.floor(Date.now() / 1000),
    payload,
  };
  p.lastActionId = msg.action_id;
  p.ws.send(JSON.stringify(msg));
  return msg.action_id;
}

function waitFor(p, type, timeoutMs) {
  return new Promise((resolve, reject) => {
    const waiter = { type, resolve };
    p.waiters.push(waiter);
    setTimeout(() => {
      const i = p.waiters.indexOf(waiter);
      if (i >= 0) { p.waiters.splice(i, 1); reject(new Error(`waitFor ${type} timeout (${p.name})`)); }
    }, timeoutMs).unref();
  });
}

function authenticate(p) {
  return new Promise((resolve, reject) => {
    p.authResolve = resolve;
    p.authReject = reject;
    const a = p.account;
    const msg = { type: a.session ? 'session' : 'login', action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload: a.session ? { session: a.session } : { account_name: a.account_name, password: a.password } };
    p.ws.send(JSON.stringify(msg));
    setTimeout(() => reject(new Error(`authentication timeout (${p.name})`)), 10000);
  });
}

function countGood(cargo, good) {
  return cargo.filter((g) => g === good).length;
}

function buildCandidates(p) {
  const hand = p.priv?.hand || [];
  const cargo = p.priv?.cargo || [];
  const pub = p.pub;
  const cands = [];
  const me = pub?.players?.find((x) => x.id === p.id);
  const myPort = pub?.ports?.find((pt) => pt.ships?.includes(p.id))?.id;
  const byAction = (a) => hand.find((c) => c.action === a);

  const deliverCard = byAction('deliver');
  if (deliverCard && Array.isArray(pub?.public_contracts)) {
    const ct = pub.public_contracts.find((c) =>
      Array.isArray(c.requires) && c.requires.every((r) => countGood(cargo, r.good) >= r.count)
    );
    if (ct) cands.push({ card_uid: deliverCard.uid, mode: 'action', target: { contract_id: ct.id }, desc: `deliver ${ct.id}` });
  }

  const tide = pub?.tide;
  const coins = me?.coins ?? 0;
  const saltPrice = Math.max(1, (pub?.market?.salt ?? 3) - (tide === 'low' ? 1 : 0));
  const sailCost = Math.max(0, 1 + (tide === 'low' || tide === 'ebb' ? 1 : 0) - (tide === 'full' ? 1 : 0));

  const tradeCard = byAction('trade');
  if (tradeCard && coins >= saltPrice) {
    cands.push({ card_uid: tradeCard.uid, mode: 'action', target: { kind: 'buy', good: 'salt', count: 1 }, desc: 'trade buy salt*1' });
  }

  const sailCard = byAction('sail');
  if (sailCard && myPort && ADJ[myPort]?.length && coins >= sailCost) {
    const to = ADJ[myPort][0];
    cands.push({ card_uid: sailCard.uid, mode: 'action', target: { to_port: to }, desc: `sail ${myPort}->${to}` });
  }

  const postCard = byAction('post');
  if (postCard && myPort && coins >= 2) {
    cands.push({ card_uid: postCard.uid, mode: 'action', target: { port: myPort }, desc: `post ${myPort}` });
  }

  if (hand.length > 0) {
    cands.push({ card_uid: hand[0].uid, mode: 'tide', desc: 'tide discard hand[0]' });
  }
  return cands;
}

function maybeSubmit(p) {
  if (done || !p.id || !p.pub || p.pub.phase !== 'select' || p.inFlight) return;
  const me = p.pub.players?.find((x) => x.id === p.id);
  if (!me || me.submitted) return;
  const turnKey = `${p.pub.round}:${p.pub.turn}`;
  if (p.turnKey !== turnKey) {
    p.turnKey = turnKey;
    p.candIdx = 0;
    p.lastSubmittedTurn = null;
  }
  if (p.lastSubmittedTurn === turnKey) return;
  const cands = buildCandidates(p);
  if (p.candIdx >= cands.length) p.candIdx = cands.length - 1;
  const c = cands[p.candIdx];
  if (!c) return;
  p.inFlight = true;
  p.lastSubmittedTurn = turnKey;
  p.lastDesc = c.desc;
  send(p, 'submit_card', { card_uid: c.card_uid, mode: c.mode, target: c.target });
  log(`${p.id} submit R${p.pub.round}T${p.pub.turn}: ${c.desc}`);
}

function onRejected(p, msg) {
  rejectedCount += 1;
  consecErrors += 1;
  if (p.inFlight) {
    p.inFlight = false;
    p.lastSubmittedTurn = null;
    if (msg.payload?.action_id === p.lastActionId) {
      p.candIdx += 1;
    }
    const cands = buildCandidates(p);
    if (p.candIdx < cands.length && p.pub?.phase === 'select') {
      maybeSubmit(p);
    } else if (p.priv?.hand?.length) {
      p.candIdx = 0;
      p.inFlight = true;
      p.lastSubmittedTurn = `${p.pub?.round}:${p.pub?.turn}`;
      p.lastDesc = 'tide fallback hand[0]';
      send(p, 'submit_card', { card_uid: p.priv.hand[0].uid, mode: 'tide' });
      log(`${p.id} fallback tide after reject (${msg.payload?.reason ?? '?'})`);
    }
  }
  if (consecErrors > MAX_CONSEC_ERRORS) {
    finish(false, `consecutive errors/rejects > ${MAX_CONSEC_ERRORS} (last reason: ${msg.payload?.reason ?? '-'})`);
  }
}

function validateGameOver(msg) {
  if (!roomListOk) {
    return finish(false, 'room_list was not verified during the game');
  }
  const scores = msg.payload?.scores;
  if (!Array.isArray(scores) || scores.length !== TOTAL_PLAYERS) {
    return finish(false, `game_over scores count != ${TOTAL_PLAYERS} (got ${Array.isArray(scores) ? scores.length : typeof scores})`);
  }
  for (const s of scores) {
    if (typeof s.total !== 'number' || s.total < 0) {
      return finish(false, `invalid total for ${s.player_id}: ${s.total}`);
    }
  }
  const ranked = [...scores].sort((a, b) => b.total - a.total);
  console.log(`[${ts()}] === GAME OVER ranking ===`);
  ranked.forEach((s, i) => {
    console.log(`  #${i + 1} ${s.player_id} total=${s.total} breakdown=${JSON.stringify(s.breakdown)}`);
  });
  const w = players[0].waitForReturnedLobby;
  if (!w) return finish(false, 'game_over received without returned_to_lobby waiter');
  w.then(() => {
    const listWait = waitFor(players[0], 'room_list', 10000);
    send(players[0], 'list_rooms', {});
    return listWait;
  }).then((list) => {
    const rooms = list.payload?.rooms || [];
    finish(true, `returned_to_lobby observed; list_rooms succeeded (${rooms.length} rooms)`);
  }).catch((e) => finish(false, `returned_to_lobby/lobby re-entry failed: ${e.message}`));
}

function onMessage(p, raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  const pl = msg.payload || {};
  const waiter = p.waiters?.find((w) => w.type === msg.type);
  if (waiter) { p.waiters.splice(p.waiters.indexOf(waiter), 1); waiter.resolve(msg); }
  switch (msg.type) {
    case 'logged_in':
    case 'session':
      if (pl.authenticated === true || (msg.type === 'logged_in' && pl.session && pl.role_id)) {
        p.accountSession = pl.session || p.account.session;
        p.roleId = pl.role_id;
        p.authResolve?.();
      } else if (msg.type === 'session' && p.account.account_name && p.account.password) {
        p.account.session = null;
        const login = { type: 'login', action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload: { account_name: p.account.account_name, password: p.account.password } };
        p.ws.send(JSON.stringify(login));
      } else p.authReject?.(new Error(`authentication rejected (${msg.type})`));
      break;
    case 'room_created':
      roomId = pl.room_id;
      p.id = pl.player_id;
      p.token = pl.token;
      log(`room created: ${roomId}, host=${p.id}`);
      send(p, 'list_rooms', {});
      if (BOT_COUNT === 0) for (let i = 1; i < 4; i += 1) connectPlayer(i);
      break;
    case 'room_list': {
      if (roomListOk) break;
      const rooms = pl.rooms || [];
      const hit = rooms.find((r) => r.room_id === roomId);
      if (!hit) {
        finish(false, `room_list missing room ${roomId} (got ${rooms.length} rooms)`);
        return;
      }
      if (hit.phase !== 'lobby' || hit.player_count < 1 || hit.max_players !== 4) {
        finish(false, `room_list brief invalid: ${JSON.stringify(hit)}`);
        return;
      }
      roomListOk = true;
      log(`room_list ok: ${rooms.length} room(s), host=${hit.host_name}`);
      break;
    }
    case 'room_joined':
      p.id = pl.player_id;
      p.token = pl.token;
      joinedCount += 1;
      log(`${p.id} joined (${joinedCount}/3 guests)`);
      if (joinedCount === 3) {
        for (const q of players) send(q, 'ready', { ready: true });
        log('all players ready sent');
      }
      break;
    case 'room_update': {
      const list = pl.players || [];
      if (BOT_COUNT > 0) {
        if (!players[0].id || startSent) break;
        const me = list.find((x) => x.id === players[0].id);
        if (botsRequested < BOT_COUNT && list.length === 1 + botsRequested) {
          botsRequested += 1;
          send(players[0], 'add_bot', {});
          log(`add_bot sent (${botsRequested}/${BOT_COUNT})`);
          break;
        }
        if (list.length === TOTAL_PLAYERS) {
          const bots = list.filter((x) => x.is_bot);
          if (bots.length !== BOT_COUNT) {
            finish(false, `room_update bot count mismatch: is_bot=${bots.length}, expected ${BOT_COUNT}`);
            return;
          }
          if (bots.some((x) => !x.ready || !x.connected || x.host)) {
            finish(false, `bot PlayerBrief invalid: ${JSON.stringify(bots)}`);
            return;
          }
          if (me && !me.ready && !readySent) {
            readySent = true;
            send(players[0], 'ready', { ready: true });
            log('host ready sent');
            break;
          }
        }
        if (list.length === TOTAL_PLAYERS && list.every((x) => x.ready)) {
          startSent = true;
          send(players[0], 'start_game', {});
          log('host start_game sent');
        }
        break;
      }
      if (!startSent && list.length === 4 && list.every((x) => x.ready) && players[0].id) {
        startSent = true;
        send(players[0], 'start_game', {});
        log('host start_game sent');
      }
      break;
    }
    case 'game_started':
      p.pub = pl.public_state;
      p.priv = pl.private_state;
      startedCount += 1;
      if (startedCount === 1) log(`game started: hand=${p.priv?.hand?.length} publicContracts=${p.pub?.public_contracts?.length}`);
      maybeSubmit(p);
      break;
    case 'phase_changed':
      if (p.pub) p.pub.phase = pl.phase;
      if (pl.phase === 'select') maybeSubmit(p);
      break;
    case 'reveal_cards': {
      consecErrors = 0;
      p.inFlight = false;
      const summary = (pl.plays || []).map((x) => `${x.player_id}:${x.card_id}/${x.mode}`).join(' ');
      log(`reveal R${p.pub?.round ?? '?'}T${p.pub?.turn ?? '?'}: ${summary}`);
      break;
    }
    case 'state_sync': {
      consecErrors = 0;
      p.pub = pl.public_state;
      p.priv = pl.private_state;
      const meNow = p.pub?.players?.find((x) => x.id === p.id);
      if (meNow?.submitted) p.inFlight = false;
      maybeSubmit(p);
      break;
    }
    case 'ack':
      consecErrors = 0;
      if (pl.action_id === p.lastActionId) p.inFlight = false;
      break;
    case 'action_rejected':
      onRejected(p, msg);
      break;
    case 'error':
      errorCount += 1;
      consecErrors += 1;
      log(`error: ${pl.code} ${pl.message ?? ''}`);
      if (consecErrors > MAX_CONSEC_ERRORS) finish(false, `consecutive errors > ${MAX_CONSEC_ERRORS} (last: ${pl.code})`);
      break;
    case 'game_over':
      p.waitForReturnedLobby = waitFor(p, 'returned_to_lobby', 30000);
      if (p === players[0]) validateGameOver(msg);
      break;
    case 'action_log':
    case 'pong':
      break;
    default:
      break;
  }
}

function connectPlayer(idx) {
  const name = NAMES[idx];
  const p = { name, id: null, token: null, account: ACCOUNTS[idx], accountSession: null, roleId: null, ws: null, pub: null, priv: null, waiters: [], inFlight: false, candIdx: 0, turnKey: null, lastActionId: null, lastDesc: null };
  players[idx] = p;
  const ws = new WebSocket(WS_URL);
  p.ws = ws;
  ws.addEventListener('open', async () => {
    try {
      await authenticate(p);
      log(`${name} authenticated role_id=${p.roleId}`);
      if (idx === 0) send(p, 'create_room', { player_name: name });
      else send(p, 'join_room', { room_id: roomId, player_name: name });
    } catch (e) { finish(false, e.message); }
  });
  ws.addEventListener('message', (ev) => {
    try {
      onMessage(p, typeof ev.data === 'string' ? ev.data : ev.data.toString());
    } catch (e) {
      finish(false, `handler exception: ${e.message}`);
    }
  });
  ws.addEventListener('close', () => {
    if (!done) finish(false, `ws closed unexpectedly (${name})`);
  });
  ws.addEventListener('error', (e) => {
    if (!done) finish(false, `ws error (${name}): ${e.message || 'connect failed'}`);
  });
}

log(BOT_COUNT > 0 ? `connecting 1 authenticated account + ${BOT_COUNT} temporary room bot(s) to ${WS_URL}` : `connecting 4 authenticated account fixtures to ${WS_URL}`);
connectPlayer(0);
