import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(ROOT, 'client', 'src');
const results = [];

function check(id, title, ok, evidence = '') {
  results.push({ id, title, ok, evidence });
  console.log(`${id} ${ok ? 'PASS' : 'FAIL'}: ${title}${evidence ? ` -- ${evidence}` : ''}`);
}

function readSrc(name) {
  try {
    return fs.readFileSync(path.join(SRC, name), 'utf8');
  } catch (error) {
    check('FILE', `${name} readable`, false, error.code);
    return '';
  }
}

const lobby = readSrc('lobby.ts');
const main = readSrc('main.ts');
const ui = readSrc('ui.ts');

// Existing prerequisites (should already hold; regression guards).
check('PRE-01', 'AppState has myStats/myStatsLoading',
  /myStats:\s*PlayerStats\s*\|\s*null/.test(ui) && /myStatsLoading:\s*boolean/.test(ui),
  'client/src/ui.ts');
check('PRE-02', 'my_stats handler stores payload.stats',
  /net\.on\('my_stats'/.test(main) && /state\.myStats\s*=/.test(main),
  'client/src/main.ts');

// New-feature gates (expected FAIL until the lobby home stats feature lands).
const lobbyUsesStats = /myStats/.test(lobby);
check('HS-A01', 'lobby.ts renders a stats block from s.myStats (games/wins shown)',
  lobbyUsesStats && /胜/.test(lobby) && /场/.test(lobby),
  lobbyUsesStats ? 'myStats referenced' : 'no myStats reference in lobby.ts');
check('HS-A03', 'lobby.ts shows win rate from myStats (wins/games percentage)',
  lobbyUsesStats && /wins\s*\/\s*st\.games|st\.games\s*>\s*0|st\.wins/.test(lobby),
  'win rate computed from myStats in lobby.ts');

const sendCount = (main.match(/send\('get_my_stats'/g) || []).length;
check('HS-A04', 'get_my_stats is requested outside openProfile (lobby entry/login flow)',
  sendCount >= 2,
  `get_my_stats send sites in main.ts: ${sendCount} (openProfile only today)`);

const handlerBlock = (main.match(/net\.on\('my_stats'[\s\S]*?\}\)/) || [''])[0];
check('HS-A04:render', 'my_stats handler re-renders when screen is lobby',
  /my_stats/.test(main) && handlerBlock.includes("'lobby'"),
  `handler: ${handlerBlock.replace(/\s+/g, ' ').slice(0, 120)}`);

check('HS-B04', 'lobby.ts has a loading branch (myStatsLoading) for the stats block',
  /myStatsLoading/.test(lobby),
  'loading placeholder in lobby.ts');
check('HS-B02', 'lobby.ts handles null stats (empty-record hint, no NaN% possible)',
  lobbyUsesStats && (/暂无/.test(lobby) || /!\s*st/.test(lobby) || /myStats\s*===?\s*null/.test(lobby)),
  'null-stats branch in lobby.ts');

const fails = results.filter((r) => !r.ok);
console.log(`=== SUMMARY: ${results.length - fails.length}/${results.length} PASS ===`);
console.log(fails.length === 0 ? 'HOME_STATS_CHECK PASS' : 'HOME_STATS_CHECK FAIL');
process.exit(fails.length === 0 ? 0 : 1);
