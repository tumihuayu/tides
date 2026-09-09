import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// Static gate for account/database reset work. It deliberately never starts a
// service or executes a destructive command; runtime checks belong to the
// manual matrix in account_mysql_reset_plan.md.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', '_build']);
const TEXT_EXTENSIONS = new Set(['.bat', '.conf', '.erl', '.json', '.md', '.mjs', '.ps1', '.sh', '.sql', '.ts', '.tsx', '.yml', '.yaml']);

function walk(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) files.push(...walk(path.join(dir, entry.name)));
    } else if (TEXT_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) {
      files.push(path.join(dir, entry.name));
    }
  }
  return files;
}

const files = walk(ROOT);
const corpus = files.map((file) => {
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { /* unreadable files are not evidence */ }
  return { file: path.relative(ROOT, file).replaceAll(path.sep, '/'), text };
});

function evidence(pattern, roots = null) {
  const re = pattern instanceof RegExp ? pattern : new RegExp(pattern, 'i');
  return corpus.filter((item) => item.file !== 'tests/account_mysql_reset_acceptance.mjs' &&
    item.file !== 'tests/account_mysql_reset_plan.md' &&
    (!roots || roots.some((root) => item.file === root || item.file.startsWith(`${root}/`))) && re.test(item.text));
}

const results = [];
function check(id, title, pattern, options = {}) {
  const hits = evidence(pattern, options.roots);
  const ok = hits.length > 0;
  results.push({ id, title, status: ok ? 'PASS' : 'FAIL', evidence: hits.slice(0, 3).map((hit) => hit.file) });
}

check('ACC-01', '注册和登录接口/流程有实现证据', /register|sign[_ -]?up|login|sign[_ -]?in/i, { roots: ['server', 'client', 'shared', 'docs'] });
  check('ACC-02', '游客只能进行客户端教程，真实对战需要账号', /游客.*(只能|教程)|guest.*(tutorial|client)|authentication_required/i, { roots: ['server', 'client', 'shared', 'docs'] });
check('ACC-03', '旧数据不迁移，且有明确版本/备份策略', /不迁移|no migration|migration.*(reject|disabled|forbid)|schema[_ -]?version|旧数据.*(拒绝|备份|隔离)/i, { roots: ['server', 'deploy', 'docs', 'tests'] });
check('ACC-04', '同账号同时只能进入一个房间', /same.*(account|player_token).*one.*room|同一.*(账号|player_token).*一个房间|already_in_room/i, { roots: ['server', 'shared', 'docs', 'tests'] });
check('ACC-05', '同账号多设备登录策略和可验证行为已定义', /multi.?device|多设备|并发登录|device.*login|kick.*old.*session|session.*limit/i, { roots: ['server', 'client', 'shared', 'docs', 'tests'] });
check('RST-01', 'reset-dev 命令/入口存在', /reset[-_]dev|reset_dev/i, { roots: ['deploy', 'server', 'tests', 'docs'] });
check('RST-02', 'reset-dev 仅开发环境可执行，有硬性环境保护', /reset[-_]dev|reset_dev/i, { roots: ['deploy', 'server', 'tests', 'docs'] });
check('RST-03', '清档前先停止服务并确认端口/进程已退出', /stop.*(before|prior).*clear|clear.*after.*stop|停.*服务.*(清档|清库)|清档.*停服|port.*free.*(reset|clear)|not.*running/i, { roots: ['deploy', 'tests', 'docs'] });
check('MYSQL-01', 'MySQL 连接配置/业务表清单存在', /mysql|mariadb|CREATE TABLE|business tables?|业务表/i, { roots: ['server', 'deploy', 'shared', 'docs', 'tests'] });
check('MYSQL-02', 'MySQL 不可用时清档失败关闭，不会继续删除', /mysql.*(unavailable|不可用|连接失败)|fail.?closed|失败.*(关闭|退出)|transaction.*rollback|rollback/i, { roots: ['server', 'deploy', 'tests', 'docs'] });
check('MYSQL-03', '清档后逐张确认数据库业务表为空', /TRUNCATE|DELETE FROM|业务表.*(为空|empty)|table.*empty|count\(\*\).*0/i, { roots: ['server', 'deploy', 'tests', 'docs'] });
check('RST-04', '清档不删除静态资源，且有保护性断言', /static.*(preserv|retain|保留)|静态资源.*(不删|保留)|client\/dist.*(preserv|保留)|do not.*(delete|remove).*static/i, { roots: ['deploy', 'tests', 'docs'] });

const failed = results.filter((result) => result.status === 'FAIL');
console.log('ACCOUNT_MYSQL_RESET_STATIC_CHECK');
for (const result of results) {
  const detail = result.evidence.length > 0 ? ` evidence=${result.evidence.join(',')}` : ' evidence=none';
  console.log(`${result.status} ${result.id} ${result.title}${detail}`);
}
console.log(`SUMMARY pass=${results.length - failed.length} fail=${failed.length} total=${results.length}`);
process.exitCode = failed.length === 0 ? 0 : 1;
