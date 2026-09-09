import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

// Read-only deployment-script gate. It never invokes tidesctl, mysql, erl, or
// a file-deleting command. Runtime cases belong to tidesctl_plan.md.
// Windows entries: deploy/tidesctl.ps1 is the primary script (PowerShell 5.1),
// deploy/tidesctl.bat is the ASCII PowerShell-window wrapper, and
// deploy/tidesctl.cmd is the GBK cmd compatibility wrapper. Linux stays
// tidesctl.sh.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEPLOY = path.join(ROOT, 'deploy');
const files = {
  BAT: path.join(DEPLOY, 'tidesctl.bat'),
  PS1: path.join(DEPLOY, 'tidesctl.ps1'),
  CMD: path.join(DEPLOY, 'tidesctl.cmd'),
  SH: path.join(DEPLOY, 'tidesctl.sh')
};
const requiredCommands = ['build', 'start', 'stop', 'status', 'players', 'init-db', 'reset-dev'];
const helpCommands = [...requiredCommands];
const results = [];
const CJK = /[一-鿿]/; // 一-鿿

function check(id, title, ok, evidence = '') {
  results.push({ id, title, ok, evidence });
}

function readBuffer(name, file) {
  try {
    const buffer = fs.readFileSync(file);
    check(`${name}-FILE`, `${name} script exists and is readable`, buffer.length > 0,
      `${path.relative(ROOT, file)} bytes=${buffer.length}`);
    return buffer;
  } catch (error) {
    check(`${name}-FILE`, `${name} script exists and is readable`, false,
      `${path.relative(ROOT, file)} ${error.code}`);
    return null;
  }
}

function decode(name, buffer, encoding) {
  const tag = encoding.toUpperCase().replace('-', '');
  try {
    const text = new TextDecoder(encoding, { fatal: true }).decode(buffer);
    check(`${name}-${tag}-VALID`, `${name} is valid ${encoding}`, true);
    return text;
  } catch (error) {
    check(`${name}-${tag}-VALID`, `${name} is valid ${encoding}`, false, error.message);
    return buffer.toString('utf8');
  }
}

// Encoding policy:
// - tidesctl.ps1: UTF-8 WITH BOM; PowerShell 5.1 misreads BOM-less UTF-8 as ANSI
//   and would mangle the Chinese help text.
// - tidesctl.cmd: GBK + CRLF + no BOM, and no `chcp 65001`; cmd parses .cmd
//   byte-wise under the active code page (936), so UTF-8 lines would break.
// - tidesctl.sh: UTF-8 + LF + no BOM.
function loadPs1() {
  const buffer = readBuffer('PS1', files.PS1);
  if (!buffer) return '';
  const hasUtf8Bom = buffer.length >= 3 && buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf;
  check('PS1-UTF8-BOM', 'ps1 is UTF-8 with BOM (PowerShell 5.1 needs it for CJK)', hasUtf8Bom,
    buffer.length >= 3 ? buffer.subarray(0, 3).toString('hex') : 'empty');
  return decode('PS1', buffer, 'utf-8');
}

function loadBat() {
  const buffer = readBuffer('BAT', files.BAT);
  if (!buffer) return '';
  const isAscii = buffer.every((byte) => byte < 0x80);
  check('BAT-ASCII', 'bat is ASCII-safe for every Windows code page', isAscii);
  check('BAT-CRLF', 'bat uses CRLF line endings with no lone LF',
    buffer.includes('\r\n') && !/(?<!\r)\n/.test(buffer.toString('latin1')));
  return buffer.toString('ascii');
}

function loadCmd() {
  const buffer = readBuffer('CMD', files.CMD);
  if (!buffer) return '';
  const hasUtf8Bom = buffer.length >= 3 && buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf;
  const hasUtf16Bom = buffer.length >= 2 &&
    ((buffer[0] === 0xff && buffer[1] === 0xfe) || (buffer[0] === 0xfe && buffer[1] === 0xff));
  check('CMD-NOBOM', 'cmd has no UTF-8/UTF-16 BOM', buffer.length > 0 && !hasUtf8Bom && !hasUtf16Bom,
    buffer.length >= 3 ? buffer.subarray(0, 3).toString('hex') : 'empty');
  check('CMD-CRLF', 'cmd uses CRLF line endings with no lone LF',
    buffer.includes('\r\n') && !/(?<!\r)\n/.test(buffer.toString('latin1')));
  return decode('CMD', buffer, 'gbk');
}

function loadSh() {
  const buffer = readBuffer('SH', files.SH);
  if (!buffer) return '';
  const hasUtf8Bom = buffer.length >= 3 && buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf;
  check('SH-NOBOM', 'sh has no UTF-8 BOM', buffer.length > 0 && !hasUtf8Bom,
    buffer.length >= 3 ? buffer.subarray(0, 3).toString('hex') : 'empty');
  check('SH-LF', 'sh uses LF line endings (no CRLF)', !buffer.includes('\r\n'));
  return decode('SH', buffer, 'utf-8');
}

function commandExists(text, command, platform) {
  if (platform === 'PS1') {
    return new RegExp(`(?:-eq\\s*['"]${command}['"]|^\\s*['"]${command}['"]\\s*\\{)`, 'mi').test(text);
  }
  if (platform === 'CMD') return new RegExp(`^\\s*if /i \\"%~1\\"==\\"${command}\\"`, 'mi').test(text);
  return new RegExp(`^\\s*${command}\\)`, 'mi').test(text);
}

function usageBlock(text, platform) {
  if (platform === 'PS1') {
    const lines = text.split(/\r?\n/);
    const start = lines.findIndex((line) => /用法/u.test(line));
    if (start === -1) return '';
    const block = [];
    for (let i = start; i < lines.length && i <= start + 80; i += 1) {
      if (i > start && /^\s*(?:\}|["']@)/.test(lines[i])) break;
      block.push(lines[i]);
    }
    return block.join('\n');
  }
  if (platform === 'CMD') {
    // CMD help is a local echo block. Stop at its explicit exit rather than
    // relying on the next label, so a label-like line in help cannot truncate
    // the text being checked.
    return text.match(/^\s*:help\r?\n[\s\S]*?^\s*exit \/b 0\s*$/mi)?.[0] ?? '';
  }
  return text.match(/^\s*''\|help\|--help\|-h\)[\s\S]*?^\s*;;/mi)?.[0] ?? '';
}

function hasAllCommands(text) {
  return helpCommands.every((command) => new RegExp(`\\b${command}\\b`, 'i').test(text));
}

function zhHelpChecks(platform, text) {
  const usage = usageBlock(text, platform);
  check(`${platform}-HELP-ZH-LABELS`, `${platform} help labels 用法/命令/选项 are Chinese`,
    Boolean(usage) && /用法/u.test(usage) && /命令/u.test(usage) && /选项/u.test(usage));
  const linePattern = (command) =>
    new RegExp(`^\\s*(?:echo\\s+|Write-(?:Host|Output)\\s+)?["']?${command}\\b.*${CJK.source}`, 'mu');
  check(`${platform}-HELP-ZH-DESC`, `${platform} help describes every command in Chinese while command names stay English`,
    Boolean(usage) && helpCommands.every((command) => linePattern(command).test(usage)));
  check(`${platform}-RESET-WARNING`, `${platform} help marks reset-dev with a Chinese destructive warning`,
    Boolean(usage) && new RegExp(`^\\s*(?:echo\\s+|Write-(?:Host|Output)\\s+)?["']?reset-dev\\b.*(?:破坏性|危险|不可逆|谨慎)`, 'mu').test(usage));
}

const content = { BAT: loadBat(), PS1: loadPs1(), CMD: loadCmd(), SH: loadSh() };

for (const platform of ['PS1', 'CMD', 'SH']) {
  const text = content[platform];
  for (const command of requiredCommands) {
    check(`${platform}-${command.toUpperCase()}`, `${platform} exposes ${command}`, commandExists(text, command, platform));
  }
  zhHelpChecks(platform, text);
}

const ps7Only = [
  ['PS51-NO-NULLCOAL', 'no null-coalescing operator ?? (PS7+)', /\?\?/],
  ['PS51-NO-NULLCOND', 'no null-conditional operator ?. (PS7+)', /\?\./],
  ['PS51-NO-CHAIN', 'no pipeline chain operators && / || (PS7+)', /&&|\|\|/],
  ['PS51-NO-PARALLEL', 'no ForEach-Object -Parallel (PS7+)', /ForEach-Object\s+-Parallel/i]
];
const ps1Lines = content.PS1.split(/\r?\n/);
for (const [suffix, title, pattern] of ps7Only) {
  const hit = ps1Lines.find((line) => !/^\s*#/.test(line) && pattern.test(line));
  check(`PS1-${suffix}`, `ps1 stays PowerShell 5.1 compatible: ${title}`,
    Boolean(content.PS1) && !hit,
    content.PS1 ? (hit ? hit.trim().slice(0, 120) : '') : 'blocked by PS1-FILE');
}

check('CMD-NO-CHCP65001', 'cmd must not use chcp 65001 (GBK file under code page 936)',
  Boolean(content.CMD) && !/^\s*chcp\s+65001\b/mi.test(content.CMD),
  content.CMD ? '' : 'blocked by CMD-FILE');

// Linux-only gates retained from the previous plan.
const sh = content.SH;
check('SH-UNKNOWN', 'sh rejects unknown commands with non-zero status', /\*\)[\s\S]*exit 1/i.test(sh));
check('SH-HELP-ALIASES', 'sh recognizes help, --help, and -h', /^\s*''\|help\|--help\|-h\)/mi.test(sh));
check('SH-HELP-COMMANDS', 'sh help lists the complete command set',
  Boolean(usageBlock(sh, 'SH')) && hasAllCommands(usageBlock(sh, 'SH')));
check('SH-HELP-STATUS', 'sh help exits with status 0', usageBlock(sh, 'SH').includes('exit 0'));
check('SH-HELP-NO-SIDE-EFFECT', 'sh help has no command side effects',
  Boolean(usageBlock(sh, 'SH')) &&
  !/(?:\b(?:cd|erl|make|mysql|curl|exec|start_server|taskkill|kill|rm|del)\b|(?:^|[;&|])\s*>{1,2})/im.test(usageBlock(sh, 'SH')));
check('SH-PASSWORD-ARGV', 'sh never puts MYSQL_PASSWORD in a mysql command line',
  !sh.split(/\r?\n/).some((line) => /\bmysql\b/i.test(line) &&
    (/(?:MYSQL_PASSWORD|--password(?:=|\s))/i.test(line) || /(?:^|\s)-p\S*/.test(line))));
const shInitDb = sh.match(/init-db\)[\s\S]*?(?=\n\s*[a-z-]+\)|$)/i);
check('SH-INITDB-NOCLEAR', 'sh init-db contains no destructive SQL/file cleanup',
  Boolean(shInitDb) && !/\b(?:DROP|TRUNCATE|DELETE)\b|rm\s+-|del\s+/i.test(shInitDb[0]));
check('SH-RESET-ENV', 'sh reset-dev requires exact development environment',
  /\[ "\$\{TIDES_ENV:-\}" != "development" \][\s\S]*?exit 1/i.test(sh));
check('SH-RESET-DB', 'sh reset-dev restricts database to development/test',
  /case "\$MYSQL_DATABASE" in tides_dev\|tides_test\).*?exit 1/i.test(sh));
check('SH-RESET-HOST', 'sh reset-dev restricts MySQL to localhost',
  /127\.0\.0\.1|localhost/i.test(sh) && /local MySQL host|MYSQL_HOST.*localhost|MYSQL_HOST.*127\.0\.0\.1/i.test(sh));
check('SH-RESET-STATIC', 'sh reset-dev preserves client/dist and removes only legacy data',
  /client[\\/]dist.*(?:missing|exist|存在|缺失|找不到)/i.test(sh) && /tides_stats\.dets/i.test(sh) &&
  !/(?:rm|del)[^\r\n]*(?:client[\\/]dist|client\\\\dist)/i.test(sh));

const [bat, cmd, shText] = [content.BAT, content.CMD, content.SH];
const cmdForwardPattern = (command) =>
  new RegExp(`^:${command}[\\s\\S]*?powershell\\.exe[^\\r\\n]*tidesctl\\.ps1"\\s+${command}\\s*[\\r\\n]+exit \/b %ERRORLEVEL%`, 'mi');
check('BAT-FORWARD', 'bat forwards all arguments to tidesctl.ps1',
  /powershell\.exe[^\r\n]*tidesctl\.ps1" %\*/i.test(bat));
check('BAT-ERROR-PROPAGATION', 'bat propagates the PowerShell exit code',
  /powershell\.exe[\s\S]*tidesctl\.ps1" %\*[\s\S]*exit \/b %ERRORLEVEL%/i.test(bat));
check('CMD-FORWARD', 'cmd forwards every business command to tidesctl.ps1',
  Boolean(cmd) && requiredCommands.every((command) => cmdForwardPattern(command).test(cmd)));
check('CMD-ERROR-PROPAGATION', 'cmd propagates each forwarded command exit code',
  Boolean(cmd) && requiredCommands.every((command) => cmdForwardPattern(command).test(cmd)));
check('BUILD-ERROR-PROPAGATION', 'build propagates compiler failure on ps1 and sh',
  /"build"[\s\S]*?(?:erl|make)[^\r\n]*\r?\n[\s\S]*?LASTEXITCODE[\s\S]*?exit 5/i.test(content.PS1) &&
  /build\)[\s\S]*?(?:erl|make)[^\r\n]*(?:\n|$)[\s\S]*?(?:set -e|\|\|[^\n]*exit 1)/i.test(shText));
check('START-ERROR-PROPAGATION', 'start propagates compiler and launch failure on ps1 and sh',
  /"start"[\s\S]*?start_server\.bat[\s\S]*?LASTEXITCODE/i.test(content.PS1) &&
  /start\)[\s\S]*?exec[^\n]*start_server/i.test(shText));
check('STOP-ERROR-PROPAGATION', 'stop checks process termination failure on ps1 and sh',
  /Stop-Process[\s\S]*?if \(\$\?\)[\s\S]*?exit 1/i.test(content.PS1) &&
  /kill[^\n]*\n[\s\S]*?rm -f[^\n]*\n[\s\S]*?exit 0/i.test(shText));
check('INITDB-ERROR-PROPAGATION', 'init-db checks mysql failure before reporting success',
  /"init-db"[\s\S]*?mysql[\s\S]*?LASTEXITCODE[\s\S]*?exit (?:10|11)/i.test(content.PS1) &&
  /init-db\)[\s\S]*?mysql[\s\S]*?(?:\|\||set -e)[\s\S]*?;;/i.test(shText));
check('RESETDB-ERROR-PROPAGATION', 'reset-dev stops on mysql failure before legacy-file deletion',
  /"reset-dev"[\s\S]*?mysql[\s\S]*?LASTEXITCODE[\s\S]*?exit 1[\s\S]*?Remove-Item/i.test(content.PS1) &&
  /mysql[\s\S]*?\|\|[\s\S]*?exit 1[\s\S]*?rm -f/i.test(shText));

const failed = results.filter((result) => !result.ok);
console.log('TIDESCTL_STATIC_CHECK');
for (const result of results) {
  console.log(`${result.ok ? 'PASS' : 'FAIL'} ${result.id} ${result.title}${result.evidence ? ` evidence=${result.evidence}` : ''}`);
}
console.log(`SUMMARY pass=${results.length - failed.length} fail=${failed.length} total=${results.length}`);
process.exitCode = failed.length === 0 ? 0 : 1;
