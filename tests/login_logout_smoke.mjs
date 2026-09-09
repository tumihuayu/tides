// 登录/登出协议冒烟（LG-01~LG-18 可执行部分）
// 运行前提：服务端已启动且 MySQL 可用（config/database.env 凭据）。
// 退出码：0 全部 PASS；1 存在 FAIL；2 无 FAIL 但存在 BLOCKED。
import { randomUUID, randomBytes } from 'node:crypto';

const WS_URL = process.env.WS_URL || 'ws://127.0.0.1:9500/ws';
const REQ_TIMEOUT_MS = 20000;
const SUFFIX = randomBytes(4).toString('hex');
const name = (tag) => `lg_${tag}_${SUFFIX}`.slice(0, 64);
const PASSWORD = 'smokePass#123';

const results = [];
function record(id, desc, status, note = '') {
  results.push({ id, desc, status, note });
  console.log(`[${status}] ${id} ${desc}${note ? ` -- ${note}` : ''}`);
}

class Conn {
  constructor(label) {
    this.label = label;
    this.waiters = [];
    this.closed = false;
    this.ws = new WebSocket(WS_URL);
    this.opened = new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true });
      this.ws.addEventListener('error', () => reject(new Error(`ws connect failed (${label})`)), { once: true });
    });
    this.ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString()); } catch { return; }
      const i = this.waiters.findIndex((w) => w.pred(msg));
      if (i >= 0) { const [w] = this.waiters.splice(i, 1); w.resolve(msg); }
    });
    this.ws.addEventListener('close', () => {
      this.closed = true;
      for (const w of this.waiters.splice(0)) w.reject(new Error(`ws closed (${label})`));
    });
  }
  send(type, payload = {}) {
    this.ws.send(JSON.stringify({ type, action_id: randomUUID(), ts: Math.floor(Date.now() / 1000), payload }));
  }
  request(type, payload = {}) {
    const respTypes = {
      register: ['account_registered'],
      login: ['logged_in'],
      logout: ['logged_out'],
      session: ['session'],
      create_room: ['room_created'],
      join_room: ['room_joined'],
      list_rooms: ['room_list'],
      get_my_stats: ['my_stats'],
    }[type] || [];
    const pred = (msg) => msg.type === 'error' || respTypes.includes(msg.type);
    return new Promise((resolve, reject) => {
      const w = { pred, resolve, reject };
      this.waiters.push(w);
      this.send(type, payload);
      setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i >= 0) { this.waiters.splice(i, 1); reject(new Error(`request ${type} timeout (${this.label})`)); }
      }, REQ_TIMEOUT_MS).unref();
    });
  }
  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

async function connect(label) {
  const c = new Conn(label);
  await c.opened;
  return c;
}

function expectError(msg, code) {
  return msg.type === 'error' && msg.payload?.code === code;
}

async function registerAccount(tag) {
  const conn = await connect(tag);
  const accountName = name(tag);
  const res = await conn.request('register', { account_name: accountName, password: PASSWORD });
  if (res.type !== 'account_registered') throw new Error(`${tag} register failed: ${JSON.stringify(res.payload)}`);
  return { conn, accountName, session: res.payload.session, roleId: res.payload.role_id, accountId: res.payload.account_id };
}

async function main() {
  // LG-01 注册成功自动登录
  let a1;
  try {
    a1 = await registerAccount('r1');
    const p = { session: a1.session, role_id: a1.roleId, account_id: a1.accountId };
    const ok = typeof p.session === 'string' && p.session.length >= 32 && p.role_id != null && p.account_id != null;
    record('LG-01', '注册成功自动登录并下发 session', ok ? 'PASS' : 'FAIL', ok ? '' : `payload=${JSON.stringify(p)}`);
    if (ok) {
      const lr = await a1.conn.request('list_rooms', {});
      record('LG-01b', '注册后立即可 list_rooms（已认证态）', lr.type === 'room_list' ? 'PASS' : 'FAIL', lr.type !== 'room_list' ? JSON.stringify(lr.payload) : '');
    }
  } catch (e) {
    record('LG-01', '注册成功自动登录并下发 session', 'FAIL', e.message);
    throw e;
  }

  // LG-05 重复注册
  {
    const c = await connect('dup');
    const res = await c.request('register', { account_name: a1.accountName, password: PASSWORD });
    record('LG-05', '重复注册返回 account_exists', expectError(res, 'account_exists') ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    c.close();
  }

  // LG-03 错误密码
  {
    const c = await connect('badpw');
    const res = await c.request('login', { account_name: a1.accountName, password: 'wrongPass#999' });
    record('LG-03', '错误密码返回 invalid_credentials', expectError(res, 'invalid_credentials') ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    var badPwMsg = res.payload?.message;
    c.close();
  }

  // LG-04 不存在账号
  {
    const c = await connect('ghost');
    const res = await c.request('login', { account_name: name('ghost'), password: PASSWORD });
    const sameMsg = res.payload?.message === badPwMsg;
    record('LG-04', '不存在账号返回 invalid_credentials 且文案与 LG-03 一致', expectError(res, 'invalid_credentials') && sameMsg ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    c.close();
  }

  // LG-06 格式校验
  const fmtCases = [
    ['name_too_short', { account_name: 'ab', password: PASSWORD }],
    ['name_too_long', { account_name: 'x'.repeat(65), password: PASSWORD }],
    ['name_invalid_chars', { account_name: 'bad name!', password: PASSWORD }],
    ['password_too_short', { account_name: name('ps'), password: 'short12' }],
    ['password_too_long', { account_name: name('pl'), password: 'p'.repeat(257) }],
  ];
  for (const [code, payload] of fmtCases) {
    const c = await connect(`fmt_${code}`);
    const res = await c.request('register', payload);
    record('LG-06', `格式校验 ${code}`, expectError(res, code) ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    c.close();
  }

  // LG-02 正常登录
  let login1;
  {
    const c = await connect('login1');
    const res = await c.request('login', { account_name: a1.accountName, password: PASSWORD });
    const ok = res.type === 'logged_in' && typeof res.payload?.session === 'string' && res.payload?.role_id === a1.roleId;
    record('LG-02', '登录成功返回新 session 且 role_id 一致', ok ? 'PASS' : 'FAIL', ok ? '' : JSON.stringify(res.payload));
    if (ok) {
      const lr = await c.request('list_rooms', {});
      record('LG-02b', '登录后 list_rooms 成功', lr.type === 'room_list' ? 'PASS' : 'FAIL');
    }
    login1 = { conn: c, session: res.payload?.session };
    if (!ok) throw new Error('login failed, abort');
  }

  // LG-07 同连接重复登录/注册
  {
    const res1 = await login1.conn.request('login', { account_name: a1.accountName, password: PASSWORD });
    const res2 = await login1.conn.request('register', { account_name: name('r2'), password: PASSWORD });
    const ok = expectError(res1, 'already_authenticated') && expectError(res2, 'already_authenticated');
    record('LG-07', '已认证连接再 login/register 返回 already_authenticated', ok ? 'PASS' : 'FAIL', `login=${res1.payload?.code} register=${res2.payload?.code}`);
  }

  // LG-15 并发登录不互踢（先验证，供 LG-08 用 login1 连接做登出）
  {
    const c2 = await connect('login2');
    const res = await c2.request('login', { account_name: a1.accountName, password: PASSWORD });
    const ok = res.type === 'logged_in' && res.payload?.role_id === a1.roleId && res.payload?.session !== login1.session && !login1.conn.closed;
    record('LG-15', '第二连接同账号登录成功、session 不同、不互踢', ok ? 'PASS' : 'FAIL', ok ? '' : JSON.stringify(res.payload));
    if (ok && !login1.conn.closed) {
      const lr = await login1.conn.request('list_rooms', {});
      record('LG-15b', '第一连接在第二登录后仍可用', lr.type === 'room_list' ? 'PASS' : 'FAIL');
    }
    c2.close();
  }

  // LG-16 并发注册同名归一化
  {
    const dupName = name('race');
    const cA = await connect('raceA');
    const cB = await connect('raceB');
    const [rA, rB] = await Promise.all([
      cA.request('register', { account_name: dupName, password: PASSWORD }),
      cB.request('register', { account_name: dupName, password: PASSWORD }),
    ]);
    const okCount = [rA, rB].filter((r) => r.type === 'account_registered').length;
    const err = [rA, rB].find((r) => r.type === 'error');
    const ok = okCount === 1 && err && err.payload?.code === 'account_exists';
    record('LG-16', '并发注册同名：恰好一条成功，另一条 account_exists', ok ? 'PASS' : 'FAIL', `A=${rA.type}/${rA.payload?.code ?? ''} B=${rB.type}/${rB.payload?.code ?? ''}`);
    cA.close();
    cB.close();
  }

  // LG-12 未登录登出
  {
    const c = await connect('guest_logout');
    const res = await c.request('logout', {});
    record('LG-12', '未认证发 logout 返回 not_authenticated', expectError(res, 'not_authenticated') ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    c.close();
  }

  // LG-18 游客建房/查询房间被拒
  {
    const c = await connect('guest_room');
    const r1 = await c.request('create_room', { player_name: 'Guest' });
    const r2 = await c.request('list_rooms', {});
    const ok = expectError(r1, 'authentication_required') && expectError(r2, 'authentication_required');
    record('LG-18', '游客 create_room/list_rooms 返回 authentication_required', ok ? 'PASS' : 'FAIL', `create=${r1.payload?.code} list=${r2.payload?.code}`);
    c.close();
  }

  // LG-08/09/10/11 登出生命周期（login1 连接登出）
  {
    const oldSession = login1.session;
    const res = await login1.conn.request('logout', {});
    record('LG-08', '登出返回 logged_out（MySQL 启用下不崩溃）', res.type === 'logged_out' ? 'PASS' : 'FAIL', JSON.stringify(res.payload));

    // LG-11 登出后同连接不能建房
    const r1 = await login1.conn.request('create_room', { player_name: 'X' });
    record('LG-11', '登出后同连接 create_room 返回 authentication_required', expectError(r1, 'authentication_required') ? 'PASS' : 'FAIL', JSON.stringify(r1.payload));

    // LG-09/10 旧 session 新连接失效
    const c = await connect('old_session');
    const rs = await c.request('session', { session: oldSession });
    record('LG-09', '登出后旧 session 恢复返回 authenticated=false', rs.type === 'session' && rs.payload?.authenticated === false ? 'PASS' : 'FAIL', JSON.stringify(rs.payload));
    const rc = await c.request('create_room', { player_name: 'X' });
    record('LG-10', '失效 session 连接 create_room 返回 authentication_required', expectError(rc, 'authentication_required') ? 'PASS' : 'FAIL', JSON.stringify(rc.payload));
    c.close();
  }

  // LG-13 有效 session 新连接恢复
  {
    const c = await connect('resume');
    const fresh = await c.request('login', { account_name: a1.accountName, password: PASSWORD });
    const sess = fresh.payload?.session;
    c.close();
    await new Promise((r) => setTimeout(r, 200));
    const c2 = await connect('resume2');
    const rs = await c2.request('session', { session: sess });
    const ok = rs.type === 'session' && rs.payload?.authenticated === true && rs.payload?.role_id === a1.roleId && rs.payload?.account_name === a1.accountName;
    record('LG-13', '新连接用有效 session 恢复 authenticated=true', ok ? 'PASS' : 'FAIL', ok ? '' : JSON.stringify(rs.payload));
    if (ok) {
      const st = await c2.request('get_my_stats', {});
      record('LG-13b', 'session 恢复后 get_my_stats 可用', st.type === 'my_stats' ? 'PASS' : 'FAIL', st.type !== 'my_stats' ? JSON.stringify(st.payload) : '');
    }
    c2.close();
  }

  // LG-14 伪造 token
  {
    const c = await connect('forged');
    const res = await c.request('session', { session: randomBytes(32).toString('hex') });
    record('LG-14', '伪造 session 返回 authenticated=false', res.type === 'session' && res.payload?.authenticated === false ? 'PASS' : 'FAIL', JSON.stringify(res.payload));
    c.close();
  }

  // LG-17 房间内禁止 logout/login
  {
    const acct = await registerAccount('room');
    const rc = await acct.conn.request('create_room', { player_name: 'Roomy' });
    const created = rc.type === 'room_created';
    if (!created) {
      record('LG-17', '房间内 logout/login 返回 already_in_room', 'FAIL', `create_room: ${JSON.stringify(rc.payload)}`);
    } else {
      const r1 = await acct.conn.request('logout', {});
      const r2 = await acct.conn.request('login', { account_name: acct.accountName, password: PASSWORD });
      const r3 = await acct.conn.request('register', { account_name: name('r3'), password: PASSWORD });
      const ok = expectError(r1, 'already_in_room') && expectError(r2, 'already_in_room') && expectError(r3, 'already_in_room');
      record('LG-17', '房间内 logout/login/register 返回 already_in_room', ok ? 'PASS' : 'FAIL', `logout=${r1.payload?.code} login=${r2.payload?.code} register=${r3.payload?.code}`);
      const lu = await acct.conn.request('list_rooms', {});
      record('LG-17b', 'already_in_room 后连接仍在房间内（list_rooms 可用）', lu.type === 'room_list' ? 'PASS' : 'FAIL', JSON.stringify(lu.payload));
    }
    acct.conn.close();
  }

  // LG-19 / LG-20 需要停 MySQL / 重启服务端，脚本内无法执行
  record('LG-19', 'MySQL 未启用降级（登出不崩溃）', 'BLOCKED', '需停 MySQL 后单独验证；本次 MySQL 在线，登出路径已由 LG-08 覆盖正向不崩溃');
  record('LG-20', '服务端重启后 session 从 MySQL 恢复', 'BLOCKED', '需重启服务端，冒烟脚本不停服务端；建议运维窗口手工验证');
  record('LG-08db', 'MySQL sessions.revoked=1 断言', 'BLOCKED', '脚本不直连数据库； revoked 效果已由 LG-09/LG-10 行为断言间接覆盖');

  a1.conn.close();
  login1.conn.close();
}

const globalTimer = setTimeout(() => {
  record('GLOBAL', '全局超时', 'FAIL', '180s');
  summary();
}, 180000);

function summary() {
  clearTimeout(globalTimer);
  const pass = results.filter((r) => r.status === 'PASS').length;
  const fail = results.filter((r) => r.status === 'FAIL');
  const blocked = results.filter((r) => r.status === 'BLOCKED');
  console.log(`\n=== SUMMARY: ${pass} PASS / ${fail.length} FAIL / ${blocked.length} BLOCKED (total ${results.length}) ===`);
  for (const r of [...fail, ...blocked]) console.log(`  ${r.status} ${r.id} ${r.desc} -- ${r.note}`);
  const code = fail.length > 0 ? 1 : (blocked.length > 0 ? 2 : 0);
  setTimeout(() => process.exit(code), 200);
}

main().then(summary).catch((e) => {
  record('GLOBAL', '执行异常中断', 'FAIL', e.message);
  summary();
});
