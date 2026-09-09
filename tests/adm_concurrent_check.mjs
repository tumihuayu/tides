const BASE = 'http://127.0.0.1:9500';

function percentile(arr, p) {
  const s = [...arr].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil(s.length * p / 100) - 1)];
}

async function one(path) {
  const t0 = performance.now();
  const res = await fetch(`${BASE}${path}`);
  const body = await res.text();
  const ms = performance.now() - t0;
  let json = null;
  try { json = JSON.parse(body); } catch { /* keep null */ }
  return { status: res.status, ms, okJson: json !== null && json.ok === true, connClose: (res.headers.get('connection') || '').toLowerCase().includes('close'), cl: Number(res.headers.get('content-length')) === Buffer.byteLength(body, 'utf8') };
}

function report(tag, results) {
  const badStatus = results.filter((r) => r.status !== 200).length;
  const badJson = results.filter((r) => !r.okJson).length;
  const badConn = results.filter((r) => !r.connClose).length;
  const badCl = results.filter((r) => !r.cl).length;
  const times = results.map((r) => r.ms);
  const p95 = percentile(times, 95);
  console.log(`${tag}: n=${results.length} bad_status=${badStatus} bad_json=${badJson} bad_conn_close=${badConn} bad_cl=${badCl} min=${Math.min(...times).toFixed(1)}ms p95=${p95.toFixed(1)}ms max=${Math.max(...times).toFixed(1)}ms`);
  return badStatus + badJson + badConn + badCl === 0 && p95 < 500;
}

const mode = process.argv[2] || 'both';
let ok = true;

if (mode === 'both' || mode === 'concurrent') {
  const [st, pl] = await Promise.all([
    Promise.all(Array.from({ length: 20 }, () => one('/admin/status'))),
    Promise.all(Array.from({ length: 20 }, () => one('/admin/players'))),
  ]);
  ok = report('concurrent status x20', st) && ok;
  ok = report('concurrent players x20', pl) && ok;
}

if (mode === 'both' || mode === 'sequential') {
  const st = [], pl = [];
  for (let i = 0; i < 50; i++) st.push(await one('/admin/status'));
  for (let i = 0; i < 50; i++) pl.push(await one('/admin/players'));
  ok = report('sequential status x50', st) && ok;
  ok = report('sequential players x50', pl) && ok;
}

console.log(ok ? 'ADM-09/10 PASS' : 'ADM-09/10 FAIL');
process.exit(ok ? 0 : 1);
