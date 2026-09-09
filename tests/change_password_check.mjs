// change_password 协议 WS 端到端冒烟（回归用）：
// 注册 → 错误旧密码改密(wrong_old_password) → 正确改密(password_changed + 全 session 失效)
// → 旧 session 恢复失败 → 旧密码登录失败 → 新密码登录成功 → 限流(rate_limited, 3次/分)。
// 前置：服务端已启动（默认 ws://127.0.0.1:9500/ws）。退出码 0=PASS，1=FAIL，2=BLOCKED。
const WS_URL = process.argv[2] || 'ws://127.0.0.1:9500/ws';
const OLD_PW = `cpOld#${Date.now().toString(36)}`;
const NEW_PW = `cpNew#${Date.now().toString(36)}x`;
const NAME = `cpw_${Date.now().toString(36)}`;

let failures = 0;
function check(label, ok, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${label}${ok ? '' : ` (${detail})`}`);
  if (!ok) failures += 1;
}

function rpc(ws, type, payload, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting reply for ${type}`)), timeoutMs);
    const onMsg = (ev) => {
      const m = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      if (m.type === 'pong') return;
      if (m.type === 'ack') return;
      ws.removeEventListener('message', onMsg);
      clearTimeout(timer);
      resolve(m);
    };
    ws.addEventListener('message', onMsg);
    ws.send(JSON.stringify({ type, action_id: `${type}-${Math.random()}`, ts: Math.floor(Date.now() / 1000), payload }));
  });
}

function connect() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    ws.addEventListener('open', () => resolve(ws));
    ws.addEventListener('error', () => reject(new Error('connect failed')));
  });
}

try {
  const ws = await connect();
  const reg = await rpc(ws, 'register', { account_name: NAME, password: OLD_PW });
  check('register ok', reg.type === 'account_registered' && !!reg.payload?.session, JSON.stringify(reg));
  const session = reg.payload.session;

  const wrong = await rpc(ws, 'change_password', { old_password: 'wrongoldpass', new_password: NEW_PW });
  check('wrong old password -> error wrong_old_password', wrong.type === 'error' && wrong.payload?.code === 'wrong_old_password', JSON.stringify(wrong));

  const okRes = await rpc(ws, 'change_password', { old_password: OLD_PW, new_password: NEW_PW });
  check('change_password ok -> password_changed', okRes.type === 'password_changed', JSON.stringify(okRes));

  const sessRes = await rpc(ws, 'session', { session });
  check('old session revoked', sessRes.type === 'session' && sessRes.payload?.authenticated === false, JSON.stringify(sessRes));

  const oldLogin = await rpc(ws, 'login', { account_name: NAME, password: OLD_PW });
  check('old password login rejected', oldLogin.type === 'error' && oldLogin.payload?.code === 'invalid_credentials', JSON.stringify(oldLogin));

  const newLogin = await rpc(ws, 'login', { account_name: NAME, password: NEW_PW });
  check('new password login ok', newLogin.type === 'logged_in' && !!newLogin.payload?.session, JSON.stringify(newLogin));
  const session2 = newLogin.payload?.session;

  let last = null;
  for (let i = 0; i < 4; i += 1) {
    last = await rpc(ws, 'change_password', { old_password: 'wrongoldpass', new_password: `${NEW_PW}${i}` });
  }
  check('rate limit -> 4th attempt rate_limited', last.type === 'error' && last.payload?.code === 'rate_limited', JSON.stringify(last));

  const stillValid = await rpc(ws, 'session', { session: session2 });
  check('failed change attempts do not revoke session', stillValid.type === 'session' && stillValid.payload?.authenticated === true, JSON.stringify(stillValid));

  ws.close();
} catch (e) {
  if (e.message === 'connect failed') {
    console.log(`BLOCKED: server not reachable at ${WS_URL}`);
    process.exit(2);
  }
  console.log(`FAIL: ${e.message}`);
  failures += 1;
}

if (failures > 0) { console.log('CP_SMOKE FAIL'); process.exit(1); }
console.log('CP_SMOKE PASS');
process.exit(0);
