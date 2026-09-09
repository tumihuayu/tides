#!/usr/bin/env node
// Contract-first skeleton. It deliberately does not invent login/tutorial APIs.
// Exit 2 means the service contract or isolated fixtures are not available.
const cases = [
  ['GUEST-BATTLE-01', '游客无 role_id/PlayerProcess，create/join/reconnect/start_practice 和任何真实对战请求均不可用'],
  ['GUEST-AUTH-02', '游客不能读取/修改账号统计、账号教程状态或他人私有状态；游客统计为零'],
  ['GUEST-TUTORIAL-03', '游客只能在纯客户端完成教程；教程结束只能选择注册或退出'],
  ['GUEST-LOGOUT-04', '游客教程后注册成功才成为账号；退出注册流程不创建账号且游客状态不迁移'],
  ['BOT-CLEANUP-05', 'Bot 仅为房间临时数据；房间关闭即释放 Bot、房间、定时器和连接状态'],
  ['ROLE-06', '账号 role 从注册/登录、登出、过期到重新登录的生命周期权限正确'],
  ['ROLE-07', '游客、普通账号、管理员权限边界正确；role 不可由客户端字段自授予'],
];

const live = process.argv.includes('--live');
const fixture = process.env.TEST_IDENTITY_FIXTURE;
const contract = process.env.TEST_IDENTITY_CONTRACT;

function print(id, status, detail) {
  console.log(`${status.padEnd(8)} ${id}: ${detail}`);
}

if (!live) {
  cases.forEach(([id]) => print(id, 'BLOCKED', '未请求 live；需最终协议契约与隔离 fixture'));
} else if (!fixture || !contract) {
  cases.forEach(([id]) => print(id, 'BLOCKED', '缺少 TEST_IDENTITY_FIXTURE 或 TEST_IDENTITY_CONTRACT；不猜测未实现接口'));
} else {
  cases.forEach(([id]) => print(id, 'BLOCKED', 'fixture 已提供但尚无 tests 侧协议适配器；待最终契约落地'));
}

console.log(`IDENTITY summary: PASS=0 FAIL=0 BLOCKED=${cases.length} TOTAL=${cases.length}`);
process.exitCode = 2;
