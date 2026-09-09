// 临时工具：为基线回归注册 4 个隔离账号，输出 TEST_ACCOUNT_FIXTURE JSON 到 %TEMP%。
// 用法：node tests\_baseline_fixture.mjs <outFile>
import fs from 'node:fs';

const outFile = process.argv[2];
if (!outFile) { console.error('usage: node _baseline_fixture.mjs <outFile>'); process.exit(1); }
const WS_URL = process.env.WS_URL || 'ws://127.0.0.1:9500/ws';
const PASSWORD = `robotPass#${Date.now().toString(36)}`;

function register(name) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    const timer = setTimeout(() => reject(new Error(`timeout ${name}`)), 15000);
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'register', action_id: 'fx1', ts: Math.floor(Date.now() / 1000), payload: { account_name: name, password: PASSWORD } }));
    });
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString());
      if (m.type === 'account_registered') {
        clearTimeout(timer);
        ws.close();
        resolve({ account_name: name, password: PASSWORD, session: m.payload.session });
      } else if (m.type === 'error') {
        clearTimeout(timer);
        reject(new Error(`${name}: ${JSON.stringify(m.payload)}`));
      }
    });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`connect failed ${name}`)); });
  });
}

const suffix = `${Date.now().toString(36)}`;
const accounts = [];
for (const tag of ['rb1', 'rb2', 'rb3', 'rb4']) {
  accounts.push(await register(`bl_${tag}_${suffix}`));
}
fs.writeFileSync(outFile, JSON.stringify(accounts));
console.log(`fixture written: ${outFile} (${accounts.length} accounts)`);
