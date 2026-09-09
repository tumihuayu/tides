// v0.5 退出对战（leave_game）端到端验收脚本（零依赖，Node >= 22 全局 WebSocket）。
// 场景 A（4 人局）：第 2 回合 1 人主动退出 →
//   退出者收 ack+returned_to_lobby、可立即 list_rooms/create_room、reconnect 原房间被拒；
//   其余 3 人收 player_left(reason=quit) 并打完收 game_over；
//   退出者 rank=4、rage_quit=true、ladder_delta=-20；get_my_stats games+1、win_streak=0。
// 场景 B（2 人局）：lobby 阶段 leave_game 被拒 not_in_game；开局后 1 人退出 →
//   只剩 1 名真人立即按当前比分终局（退出者 rank=2、rage_quit=true、ladder_delta=-10）。
//
// 用法：
//   node tests\quit_game_check.mjs                      # 全部场景（需账号 fixture 或 --register）
//   node tests\quit_game_check.mjs --scenario=a         # 仅 4 人局
//   node tests\quit_game_check.mjs --scenario=b         # 仅 2 人局
//   node tests\quit_game_check.mjs --register           # 自动注册隔离账号（4+2）
//   set TEST_ACCOUNT_FIXTURE=fixture.json               # 场景 A 用前 4 个账号
//   set TEST_ACCOUNT_FIXTURE_B=fixture_b.json           # 场景 B 专用 2 账号（缺省复用注册池）
// 退出码：0 PASS / 1 FAIL / 2 BLOCKED。
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';

const ARGS = process.argv.slice(2);
const WS_URL = ARGS.find((a) => !a.startsWith('--')) || 'ws://127.0.0.1:9500/ws';
const SC_ARG = ARGS.find((a) => a.startsWith('--scenario='));
const SCENARIO = SC_ARG ? SC_ARG.split('=')[1].toLowerCase() : 'all';
const SELF_REGISTER = ARGS.includes('--register');
const GLOBAL_TIMEOUT_MS = 300000;

if (!['a', 'b', 'all'].includes(SCENARIO)) {
  console.log(`FAIL: --scenario must be a|b|all (got ${SC_ARG})`);
  process.exit(1);
}

function ts() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${ts()}] ${msg}`);
}

function readAccounts(envText, envFile) {
  const text = process.env[envText] || (process.env[envFile] ? fs.readFileSync(process.env[envFile], 'utf8') : '');
  if (!text.trim()) return [];
  let value;
  try { value = JSON.parse(text); } catch (e) {
    console.log(`FAIL: ${envText}/${envFile} must be JSON (${e.message})`);
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

function registerAccount(name, password) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    const timer = setTimeout(() => reject(new Error(`register timeout ${name}`)), 15000);
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'register', action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload: { account_name: name, password } }));
    });
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      if (m.type === 'account_registered') {
        clearTimeout(timer);
        ws.close();
        resolve({ account_name: name, password, session: m.payload.session });
      } else if (m.type === 'error') {
        clearTimeout(timer);
        reject(new Error(`register ${name}: ${JSON.stringify(m.payload)}`));
      }
    });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`connect failed ${name}`)); });
  });
}

async function provision(count, envText, envFile, tag) {
  const fixed = readAccounts(envText, envFile);
  if (fixed.length >= count) return fixed.slice(0, count);
  if (!SELF_REGISTER) return null;
  const suffix = Date.now().toString(36);
  const password = `quitPass#${suffix}`;
  const out = [];
  for (let i = 0; i < count; i += 1) {
    out.push(await registerAccount(`qg_${tag}_${i + 1}_${suffix}`, password));
  }
  log(`registered ${out.length} fresh account(s) for scenario ${tag}`);
  return out;
}

// ---------------------------------------------------------------------------
// 对局驱动（参考 robot.mjs 的候选行动逻辑）
// ---------------------------------------------------------------------------

const ADJ = {
  east: ['reef', 'white'],
  reef: ['east', 'fog'],
  fog: ['reef', 'white'],
  white: ['fog', 'east'],
};

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
      Array.isArray(c.requires) && c.requires.every((r) => countGood(cargo, r.good) >= r.count));
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
    cands.push({ card_uid: sailCard.uid, mode: 'action', target: { to_port: ADJ[myPort][0] }, desc: `sail ${myPort}->${ADJ[myPort][0]}` });
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

class Game {
  constructor(label) {
    this.label = label;
    this.players = [];
    this.roomId = null;
    this.done = false;
    this.consecErrors = 0;
    this.hooks = { onMessage: null };
  }

  fail(reason) {
    if (this.done) return;
    this.done = true;
    this.cleanup();
    console.log(`[${ts()}] FAIL: [${this.label}] ${reason}`);
    console.log(`[${ts()}] QUIT_CHECK FAIL`);
    process.exit(1);
  }

  cleanup() {
    for (const p of this.players) {
      try { p.ws?.close(); } catch { /* ignore */ }
    }
  }

  send(p, type, payload) {
    const msg = {
      type,
      room_id: this.roomId || undefined,
      player_id: p.id || undefined,
      action_id: randomUUID(),
      ts: Math.floor(Date.now() / 1000),
      payload,
    };
    p.lastActionId = msg.action_id;
    p.ws.send(JSON.stringify(msg));
    return msg.action_id;
  }

  waitFor(p, type, timeoutMs, pred) {
    return new Promise((resolve, reject) => {
      const waiter = { type, pred, resolve };
      p.waiters.push(waiter);
      setTimeout(() => {
        const i = p.waiters.indexOf(waiter);
        if (i >= 0) {
          p.waiters.splice(i, 1);
          reject(new Error(`[${this.label}] waitFor ${type} timeout (${p.name})`));
        }
      }, timeoutMs).unref();
    });
  }

  maybeSubmit(p) {
    if (this.done || !p.id || !p.pub || p.pub.phase !== 'select' || p.inFlight || !p.autoPlay) return;
    const me = p.pub.players?.find((x) => x.id === p.id);
    if (!me || me.submitted) return;
    if (p.submitGate && p.submitGate(p)) return;
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
    this.send(p, 'submit_card', { card_uid: c.card_uid, mode: c.mode, target: c.target });
    log(`[${this.label}] ${p.id} submit R${p.pub.round}T${p.pub.turn}: ${c.desc}`);
  }

  onRejected(p, msg) {
    this.consecErrors += 1;
    if (p.inFlight) {
      p.inFlight = false;
      p.lastSubmittedTurn = null;
      if (msg.payload?.action_id === p.lastActionId) p.candIdx += 1;
      const cands = buildCandidates(p);
      if (p.candIdx < cands.length && p.pub?.phase === 'select') {
        this.maybeSubmit(p);
      } else if (p.priv?.hand?.length) {
        p.candIdx = 0;
        p.inFlight = true;
        p.lastSubmittedTurn = `${p.pub?.round}:${p.pub?.turn}`;
        this.send(p, 'submit_card', { card_uid: p.priv.hand[0].uid, mode: 'tide' });
        log(`[${this.label}] ${p.id} fallback tide after reject (${msg.payload?.reason ?? '?'})`);
      }
    }
    if (this.consecErrors > 20) {
      this.fail(`consecutive errors/rejects > 20 (last: ${msg.payload?.reason ?? '-'})`);
    }
  }

  onMessage(p, raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch { return; }
    const pl = msg.payload || {};
    const waiter = p.waiters?.find((w) => w.type === msg.type && (!w.pred || w.pred(msg)));
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
          p.ws.send(JSON.stringify({ type: 'login', action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload: { account_name: p.account.account_name, password: p.account.password } }));
        } else p.authReject?.(new Error(`authentication rejected (${msg.type})`));
        break;
      case 'game_started':
        p.pub = pl.public_state;
        p.priv = pl.private_state;
        this.maybeSubmit(p);
        break;
      case 'phase_changed':
        if (p.pub) p.pub.phase = pl.phase;
        if (pl.phase === 'select') this.maybeSubmit(p);
        break;
      case 'reveal_cards':
        this.consecErrors = 0;
        p.inFlight = false;
        break;
      case 'state_sync': {
        this.consecErrors = 0;
        p.pub = pl.public_state;
        p.priv = pl.private_state;
        const meNow = p.pub?.players?.find((x) => x.id === p.id);
        if (meNow?.submitted) p.inFlight = false;
        this.maybeSubmit(p);
        break;
      }
      case 'ack':
        this.consecErrors = 0;
        if (pl.action_id === p.lastActionId) p.inFlight = false;
        break;
      case 'action_rejected':
        this.onRejected(p, msg);
        break;
      case 'error':
        this.consecErrors += 1;
        if (this.consecErrors > 20) this.fail(`consecutive errors > 20 (last: ${pl.code})`);
        break;
      default:
        break;
    }
    try { this.hooks.onMessage?.(p, msg); } catch (e) { this.fail(e.message); }
  }

  connect(account, name) {
    const p = {
      name, account, id: null, token: null, roleId: null, ws: null,
      pub: null, priv: null, waiters: [], inFlight: false, candIdx: 0,
      turnKey: null, lastActionId: null, autoPlay: false,
    };
    this.players.push(p);
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(WS_URL);
      p.ws = ws;
      ws.addEventListener('open', () => {
        p.authResolve = () => resolve(p);
        p.authReject = reject;
        const a = p.account;
        const auth = {
          type: a.session ? 'session' : 'login',
          action_id: randomUUID(),
          ts: Math.floor(Date.now() / 1000),
          payload: a.session ? { session: a.session } : { account_name: a.account_name, password: a.password },
        };
        ws.send(JSON.stringify(auth));
        setTimeout(() => reject(new Error(`[${this.label}] auth timeout (${name})`)), 10000).unref();
      });
      ws.addEventListener('message', (ev) => {
        try {
          this.onMessage(p, typeof ev.data === 'string' ? ev.data : ev.data.toString());
        } catch (e) {
          this.fail(`handler exception: ${e.message}`);
        }
      });
      ws.addEventListener('close', () => { if (!this.done) reject(new Error(`[${this.label}] ws closed unexpectedly (${name})`)); });
      ws.addEventListener('error', (e) => { if (!this.done) reject(new Error(`[${this.label}] ws error (${name}): ${e.message || 'connect failed'}`)); });
    });
  }
}

function assert(cond, label, detail) {
  if (!cond) throw new Error(`assert failed: ${label}${detail !== undefined ? ` (got ${JSON.stringify(detail)})` : ''}`);
  log(`ok: ${label}`);
}

async function setupRoom(game, players) {
  const host = players[0];
  const created = game.waitFor(host, 'room_created', 10000);
  game.send(host, 'create_room', { player_name: host.name });
  const createdMsg = await created;
  game.roomId = createdMsg.payload.room_id;
  host.id = createdMsg.payload.player_id;
  host.token = createdMsg.payload.token;
  log(`[${game.label}] room created: ${game.roomId} host=${host.id}`);
  for (let i = 1; i < players.length; i += 1) {
    const p = players[i];
    const joined = game.waitFor(p, 'room_joined', 10000);
    game.send(p, 'join_room', { room_id: game.roomId, player_name: p.name });
    const jm = await joined;
    p.id = jm.payload.player_id;
    p.token = jm.payload.token;
  }
  for (const p of players) game.send(p, 'ready', { ready: true });
  await game.waitFor(host, 'room_update', 10000, (m) =>
    (m.payload?.players || []).length === players.length && m.payload.players.every((x) => x.ready));
  const startedMsgs = players.map((p) => game.waitFor(p, 'game_started', 15000));
  game.send(host, 'start_game', {});
  await Promise.all(startedMsgs);
  log(`[${game.label}] game started (${players.length} players)`);
}

async function getStats(game, p) {
  const w = game.waitFor(p, 'my_stats', 10000);
  game.send(p, 'get_my_stats', {});
  const m = await w;
  return m.payload?.stats ?? null;
}

// ---------------------------------------------------------------------------
// 场景 A：4 人局，第 2 回合 1 人主动退出
// ---------------------------------------------------------------------------

async function scenarioA(accounts) {
  const game = new Game('A');
  const players = [];
  for (let i = 0; i < 4; i += 1) players.push(await game.connect(accounts[i], `QA${i}`));
  const quitter = players[1];
  const baseline = (await getStats(game, quitter)) || { games: 0, wins: 0 };
  log(`[A] quitter baseline stats: games=${baseline.games} wins=${baseline.wins}`);

  await setupRoom(game, players);
  for (const p of players) p.autoPlay = true;
  quitter.submitGate = (p) => (p.pub?.round ?? 0) >= 2;
  for (const p of players) game.maybeSubmit(p);

  const others = players.filter((p) => p !== quitter);
  const leftPromises = others.map((p) => game.waitFor(p, 'player_left', 120000));
  const seatUpdateP = game.waitFor(players[0], 'room_update', 120000, (m) => {
    const s = (m.payload?.players || []).find((x) => x.id === quitter.id);
    return s && s.connected === false;
  });

  let quitAid = null;
  let quitSent = false;
  const ackP = game.waitFor(quitter, 'ack', 120000, (m) => quitAid !== null && m.payload?.action_id === quitAid);
  const returnedP = game.waitFor(quitter, 'returned_to_lobby', 120000);
  const backP = game.waitFor(players[0], 'returned_to_lobby', 240000);
  const quitSentP = new Promise((resolve) => {
    game.hooks.onMessage = (p) => {
      if (quitSent || p !== quitter || !p.pub) return;
      if (p.pub.phase === 'select' && (p.pub.round ?? 0) >= 2) {
        const me = p.pub.players?.find((x) => x.id === p.id);
        if (me && !me.submitted) {
          quitSent = true;
          p.autoPlay = false;
          quitAid = game.send(p, 'leave_game', {});
          log(`[A] quitter ${p.id} sent leave_game at round=${p.pub.round}`);
          resolve();
        }
      }
    };
  });
  await quitSentP;
  game.hooks.onMessage = null;

  const ack = await ackP;
  assert(ack.payload.action_id === quitAid, 'A1 quitter received ack for leave_game');

  const returned = await returnedP;
  assert(returned.payload?.room_id === game.roomId, 'A2 quitter received returned_to_lobby with original room_id', returned.payload);

  const leftMsgs = await Promise.all(leftPromises);
  for (const m of leftMsgs) {
    assert(m.payload?.player_id === quitter.id, 'A3 others received player_left with quitter player_id', m.payload);
    assert(m.payload?.name === quitter.name, 'A3 player_left name matches', m.payload?.name);
    assert(m.payload?.reason === 'quit', 'A3 player_left reason=quit', m.payload?.reason);
  }

  const seatUpdate = await seatUpdateP;
  const seat = seatUpdate.payload.players.find((x) => x.id === quitter.id);
  assert(seat.connected === false && seat.auto_pilot === true, 'A4 quitter seat connected=false auto_pilot=true', seat);

  const recon = game.waitFor(quitter, 'error', 10000);
  game.send(quitter, 'reconnect', { room_id: game.roomId, player_id: quitter.id, token: quitter.token });
  const reconErr = await recon;
  assert(reconErr.payload?.code === 'error' && /left the game/.test(reconErr.payload?.message ?? ''),
    'A5 quitter reconnect original room rejected', reconErr.payload);

  const listW = game.waitFor(quitter, 'room_list', 10000);
  game.send(quitter, 'list_rooms', {});
  const listMsg = await listW;
  assert(Array.isArray(listMsg.payload?.rooms), 'A6 quitter can list_rooms immediately after quit');

  const newRoomW = game.waitFor(quitter, 'room_created', 10000);
  game.send(quitter, 'create_room', { player_name: quitter.name });
  const newRoom = await newRoomW;
  assert(newRoom.payload?.room_id && newRoom.payload.room_id !== game.roomId,
    'A7 quitter role binding released: create_room succeeds immediately', newRoom.payload);

  const overMsgs = await Promise.all(players.filter((p) => p !== quitter).map((p) =>
    game.waitFor(p, 'game_over', 240000)));
  const over = overMsgs[0];
  const scores = over.payload?.scores;
  assert(Array.isArray(scores) && scores.length === 4, 'A8 game_over scores count == 4', Array.isArray(scores) ? scores.length : typeof scores);
  for (const s of scores) {
    assert(typeof s.total === 'number' && s.total >= 0, `A8 score total valid for ${s.player_id}`, s.total);
  }
  const qs = scores.find((s) => s.player_id === quitter.id);
  assert(qs && qs.rage_quit === true, 'A9 quitter rage_quit=true', qs);
  assert(qs.rank === 4, 'A9 quitter rank=4 (forced last)', qs?.rank);
  assert(qs.ladder_delta === -20, 'A9 quitter ladder_delta=-20', qs?.ladder_delta);
  for (const s of scores.filter((x) => x.player_id !== quitter.id)) {
    assert(s.rage_quit === false, `A9 ${s.player_id} rage_quit=false`, s.rage_quit);
    assert(s.rank >= 1 && s.rank <= 3, `A9 ${s.player_id} rank within 1..3`, s.rank);
  }
  log(`[A] game_over ranking: ${[...scores].sort((a, b) => a.rank - b.rank).map((s) => `#${s.rank} ${s.player_id} total=${s.total} delta=${s.ladder_delta}`).join(' | ')}`);

  const back = await backP;
  assert(back.payload?.room_id === game.roomId, 'A10 remaining player returned_to_lobby after game_over', back.payload);

  const after = await getStats(game, quitter);
  assert(after && after.games === baseline.games + 1, 'A11 quitter stats games+1', after?.games);
  assert(after.win_streak === 0, 'A11 quitter win_streak=0', after?.win_streak);
  assert(after.wins === baseline.wins, 'A11 quitter wins unchanged', after?.wins);
  const recent0 = Array.isArray(after.recent) ? after.recent[0] : null;
  assert(recent0 && recent0.rank === 4 && recent0.ladder_delta === -20,
    'A11 quitter recent[0] rank=4 ladder_delta=-20', recent0);

  game.done = true;
  game.cleanup();
  log('[A] scenario A PASS');
}

// ---------------------------------------------------------------------------
// 场景 B：2 人局，lobby 拒绝 + 退出后立即终局
// ---------------------------------------------------------------------------

async function scenarioB(accounts) {
  const game = new Game('B');
  const players = [];
  for (let i = 0; i < 2; i += 1) players.push(await game.connect(accounts[i], `QB${i}`));
  const quitter = players[1];

  const host = players[0];
  const created = game.waitFor(host, 'room_created', 10000);
  game.send(host, 'create_room', { player_name: host.name });
  const createdMsg = await created;
  game.roomId = createdMsg.payload.room_id;
  host.id = createdMsg.payload.player_id;
  host.token = createdMsg.payload.token;
  const joined = game.waitFor(quitter, 'room_joined', 10000);
  game.send(quitter, 'join_room', { room_id: game.roomId, player_name: quitter.name });
  const jm = await joined;
  quitter.id = jm.payload.player_id;
  quitter.token = jm.payload.token;

  const lobbyErrW = game.waitFor(quitter, 'error', 10000);
  game.send(quitter, 'leave_game', {});
  const lobbyErr = await lobbyErrW;
  assert(lobbyErr.payload?.code === 'not_in_game', 'B1 lobby phase leave_game rejected not_in_game', lobbyErr.payload);

  for (const p of players) game.send(p, 'ready', { ready: true });
  await game.waitFor(host, 'room_update', 10000, (m) =>
    (m.payload?.players || []).length === 2 && m.payload.players.every((x) => x.ready));
  const startedMsgs = players.map((p) => game.waitFor(p, 'game_started', 15000));
  game.send(host, 'start_game', {});
  await Promise.all(startedMsgs);
  log('[B] game started (2 players)');

  if (quitter.pub?.phase !== 'select') {
    await game.waitFor(quitter, 'state_sync', 15000, () => quitter.pub?.phase === 'select');
  }
  const leftW = game.waitFor(host, 'player_left', 10000);
  const overP = game.waitFor(host, 'game_over', 30000);
  const backP2 = game.waitFor(host, 'returned_to_lobby', 30000);
  let quitAid = null;
  const ackP = game.waitFor(quitter, 'ack', 10000, (m) => quitAid !== null && m.payload?.action_id === quitAid);
  const returnedP = game.waitFor(quitter, 'returned_to_lobby', 10000);
  quitAid = game.send(quitter, 'leave_game', {});
  const ack = await ackP;
  assert(ack.payload.action_id === quitAid, 'B2 quitter received ack for leave_game');
  const returned = await returnedP;
  assert(returned.payload?.room_id === game.roomId, 'B2 quitter returned_to_lobby', returned.payload);

  const left = await leftW;
  assert(left.payload?.player_id === quitter.id && left.payload?.reason === 'quit',
    'B3 remaining player received player_left reason=quit', left.payload);

  const over = await overP;
  const scores = over.payload?.scores;
  assert(Array.isArray(scores) && scores.length === 2, 'B4 last-human-quit finishes game immediately, scores count == 2', scores);
  const qs = scores.find((s) => s.player_id === quitter.id);
  const hs = scores.find((s) => s.player_id === host.id);
  assert(qs && qs.rage_quit === true && qs.rank === 2, 'B4 quitter rank=2 rage_quit=true', qs);
  assert(qs.ladder_delta === -10, 'B4 quitter ladder_delta=-10 (2p last)', qs?.ladder_delta);
  assert(hs && hs.rage_quit === false && hs.rank === 1, 'B4 remaining player rank=1 rage_quit=false', hs);
  assert(typeof hs.ladder_delta === 'number' && hs.ladder_delta > 0, 'B4 remaining player positive ladder_delta', hs?.ladder_delta);

  const back = await backP2;
  assert(back.payload?.room_id === game.roomId, 'B5 remaining player returned_to_lobby', back.payload);

  game.done = true;
  game.cleanup();
  log('[B] scenario B PASS');
}

// ---------------------------------------------------------------------------

async function main() {
  let ran = 0;
  if (SCENARIO === 'a' || SCENARIO === 'all') {
    const acc = await provision(4, 'TEST_ACCOUNTS', 'TEST_ACCOUNT_FIXTURE', 'a');
    if (!acc) {
      console.log('BLOCKED: scenario A needs 4 accounts (TEST_ACCOUNTS/TEST_ACCOUNT_FIXTURE or --register)');
      process.exit(2);
    }
    await scenarioA(acc);
    ran += 1;
  }
  if (SCENARIO === 'b' || SCENARIO === 'all') {
    let acc = readAccounts('TEST_ACCOUNTS_B', 'TEST_ACCOUNT_FIXTURE_B');
    if (acc.length < 2) acc = await provision(2, 'TEST_ACCOUNTS_B', 'TEST_ACCOUNT_FIXTURE_B', 'b');
    if (!acc) {
      console.log('BLOCKED: scenario B needs 2 accounts (TEST_ACCOUNTS_B/TEST_ACCOUNT_FIXTURE_B or --register)');
      process.exit(2);
    }
    await scenarioB(acc.slice(0, 2));
    ran += 1;
  }
  console.log(`[${ts()}] QUIT_CHECK PASS (${ran} scenario(s))`);
  process.exit(0);
}

const killer = setTimeout(() => {
  console.log(`[${ts()}] FAIL: global timeout ${GLOBAL_TIMEOUT_MS}ms`);
  console.log(`[${ts()}] QUIT_CHECK FAIL`);
  process.exit(1);
}, GLOBAL_TIMEOUT_MS);
killer.unref();

main().catch((e) => {
  console.log(`[${ts()}] FAIL: ${e.message}`);
  console.log(`[${ts()}] QUIT_CHECK FAIL`);
  process.exit(1);
});
