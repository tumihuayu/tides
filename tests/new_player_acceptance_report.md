# M5 新手流程（M0-M4）全量回归验收报告

- 验收版本：M5（新手流程整体验收）
- 验收日期：2026-08-28
- 验收人：测试 PM
- 环境：Windows 10 / PowerShell 5.1；服务端本机 `ws://127.0.0.1:9500/ws`（按 `deploy/start_server.bat` 启动）；Node 原生 WebSocket
- 依据：`tests/acceptance_checklist.md`、`tests/new_player_test_plan.md`、`tests/new_player_tutorial_m2_cases.md`、`tests/new_player_tutorial_m3_cases.md`、`tests/m4_tutorial_practice_cases.md`、`tests/new_player_tutorial_m3_static_acceptance.md`

## 1. 本轮回归执行结果

| # | 回归项 | 命令 | 结果 |
|---|---|---|---|
| 1 | server 编译 | `erl -noshell -eval "make:all(), init:stop()."` | PASS（无错误输出，ebin 产物更新） |
| 2 | server EUnit + 三组 sim | `escript verify.escript` | PASS（28 tests passed；SIM OK） |
| 3 | 4 人整局冒烟 | `node tests/robot.mjs` | PASS（SMOKE PASS，4 轮 × 3 回合收束，game_over scores=4） |
| 4 | 1 真人 + 3 bot 整局 | `node tests/robot.mjs --bots=3` | PASS（SMOKE PASS，bot 每回合 2-3s 内合法提交） |
| 5a | M4 陪练静态门禁 | `node tests/m4_tutorial_practice_smoke.mjs` | PASS=1 FAIL=0 BLOCKED=1（M4-ENV-WS live 未请求 → BLOCKED，未伪造） |
| 5b | M3 教程静态门禁 | `node tests/new_player_tutorial_m3_smoke.mjs` | PASS=2 FAIL=0 BLOCKED=1（ENV-WS live 未请求 → BLOCKED，未伪造） |
| 6 | client 构建 | `npm run build`（tsc && vite build） | PASS（271ms，无 TS 错误） |
| 7 | tidesctl 静态检查 | `node tests/tidesctl_static_check.mjs` | PASS（69/69） |

说明：`--live` 探测需要已完成 T1-T9 的账号 token / M4_COMPLETED_TOKEN 及 MySQL 环境，本轮按既有用户批准跳过，两项 live 门禁真实输出 BLOCKED（退出语义符合用例文档），未伪造任何 live 结果。

## 2. 新手流程（M0-M4）整体验收状态

### 2.1 通过项（PASS）

| 域 | 内容 | 证据 |
|---|---|---|
| 回归门槛 | 编译、28 项 eunit、sim、robot × 2、client 构建、tidesctl 69 项全过，无正式流程回退 | 本报告 §1 |
| M3 协议契约 | PC-01..PC-06 教程消息/字段在 `shared/protocol.md` 定义且服务端路由实现（静态） | `new_player_tutorial_m3_smoke.mjs` PASS |
| M3 实现字段 | session_id、snapshot_version 递增、错误字符串路径、游客不写账号、教程/普通房隔离源码路径 | 静态门禁 IMPL-01..06 PASS；`new_player_tutorial_m3_static_acceptance.md` §3 |
| 客户端恢复链路 | 账号先校验再查教程、版本过滤、恢复遮罩与失败重开 UI、静态手册 ≠ 教程完成 | 同上 §3.4 |
| M4 陪练协议 | practice 消息、mode、资格、组成、正式回合契约已文档化（M4-PC） | `m4_tutorial_practice_smoke.mjs` PASS |
| 既有 BOT/BOT2/LDR 基线 | 1+3 bot 整局、托管接管/夺回、战绩落盘、排行榜等历史 PASS 项本轮无回退 | §1 第 3/4 项 + `acceptance_checklist.md` §4.7-4.9 |

### 2.2 条件通过项（CONDITIONAL，静态可见但缺行为证据）

| 项 | 说明 |
|---|---|
| action_id 行动幂等 | 进程内 map 去重存在，但断线/重启/并发行为未实测（M3-A05/A06） |
| 账号完成写入/读取路径 | SQL 与 UPDATE 路径存在，真实 MySQL driver/凭据/重启读取未闭环 |
| snapshot_version 单调性 | 服务端递增 + 客户端拒旧版本，乱序/多连接/重启语义未证明 |
| 完成幂等与原子性 | T9 先持久化后置 passed，DB 失败/重试/响应丢失分支未测 |
| 账号本地身份键 | 客户端键用 accountName 而非 account_id，同名/改名边界未定义 |
| 正式流程历史回归 | 历史 v0.3.2 报告仅证明普通流程，教程专项（M3-G01..G04）未覆盖 |

### 2.3 跳过项（含用户批准，不得写成 PASS）

| 项 | 状态与原因 |
|---|---|
| M3 live 探测（`--live`） | 用户批准跳过；本轮静态门禁真实输出 ENV-WS BLOCKED |
| M4 live 探测（`M4_COMPLETED_TOKEN`） | 用户批准跳过；M4-ENV-WS BLOCKED |
| MySQL 实测（账号持久化/跨重启/跨设备） | 无认证凭据、无 Erlang driver 证据（`mysql_readonly_report_2026-08-27.md`），M3-I01..I04 相关全 BLOCKED |
| `start_tutorial` live 无响应问题 | 已知未解决问题：live 环境下 `start_tutorial` 无响应，导致 M2/M3 的 WS 行为用例无法通过 live 链路执行，按用户决定记跳过/遗留，不作为本轮阻塞关闭项 |
| 浏览器实测（刷新/清存储/双标签/禁用 localStorage） | 环境未提供，M3-I05..I10、M3-A03 相关 BLOCKED |
| M2-T01..T24 行为执行 | 用例文档仍为待填写模板，无 live 证据 |

### 2.4 未覆盖项（NOT COVERED）

- M3-R01..R07 断线/恢复/未确认行动两支/T9 丢响应全部分支（恢复快照在内存，服务端重启不可恢复为已知 P0）。
- M3-W04 replay 请求幂等（协议与实现均无 replay 幂等标识，P0 风险）。
- M3-A01/A02/A04/A07/A08 并发、故障注入、安全越权。
- M3-G01..G04 教程对正式统计/普通房的隔离行为验证。
- NP-B04 受试者 10 分钟首行动、NP-A04~A06 等 P1 体验用例。
- M4-P01..I01 全部 14 条 live 陪练用例（仅静态契约 PASS）。

## 3. 用例汇总

| 分组 | 总数 | PASS | CONDITIONAL | BLOCKED/SKIP | NOT RUN |
|---|---:|---:|---:|---:|---:|
| 回归门槛（§1 七项） | 7 | 7 | 0 | 0 | 0 |
| M2 固定任务教程（T01-T24） | 24 | 0 | 0 | 24（live 未执行 + start_tutorial 无响应遗留） | 0 |
| M3 身份/恢复/重玩（40 条） | 40 | 8（静态） | 14 | 18 | 0 |
| M4 陪练（14 条） | 14 | 0 | 1（静态契约） | 13（live 环境缺） | 0 |
| M0 基线 P0（NP-A/B/C/D/E/F/G 39 条） | 39 | 部分由静态/历史基线覆盖 | — | 多数依赖 live/浏览器/MySQL | 未按用例逐条执行 |

## 4. 主要风险与阻塞

1. **P0**：教程进行中快照非持久化（`tides_tutorial.erl` 进程/ETS），服务端重启后不可恢复最近稳定点。
2. **P0**：`tutorial_replay` 无请求级幂等，重复点击/双设备可产生多 session。
3. **P0**：MySQL 持久化闭环未验证（driver/凭据/schema/重启读取）。
4. **P0**：`start_tutorial` live 无响应问题未定位修复，阻塞 M2/M3 live 链路。
5. **P0**：客户端 localStorage 读写无异常降级保护。
6. 教程对正式统计/房间的隔离、并发与故障注入均无行为证据。

## 5. 最终结论

**结论：有条件通过（不构成新手流程 M0-M4 行为验收通过）。**

- 通过层面：M5 全量回归七项全部 PASS，正式对局/人机/战绩/管理基线无回退；M3 协议契约与实现字段静态门禁 PASS；M4 陪练静态契约 PASS。
- 条件/保留：M2/M3/M4 的行为验收大量依赖 live WS、MySQL、浏览器环境，本轮按用户批准跳过，脚本均真实输出 BLOCKED；`start_tutorial` live 无响应为已知遗留问题；教程快照持久化与 replay 幂等为 P0 级实现缺口。

## 6. 上线前建议

1. 优先定位并修复 `start_tutorial` live 无响应问题，解锁 M2-T01..T24 与 M3 live 链路。
2. 为 `tutorial_replay` 增加请求级幂等/并发裁决并补齐公开协议字段。
3. 明确教程恢复快照持久化边界（至少账号完成事实 + 最近稳定阶段可恢复）。
4. 提供隔离 MySQL 凭据与兼容 driver，完成账号写入/读取/重启/跨设备证据链。
5. 客户端 localStorage 增加 try/catch 与损坏降级；本地账号键改用 account_id 或明确约束。
6. 补跑 M3 live、M4 live（M4_COMPLETED_TOKEN）、M3-G01..G04 隔离回归及 NP-B04 受试者体验验证后，再由测试 PM 将各条件项转 PASS。
7. 在上述 1-4 关闭前，新手教程/陪练功能不得对正式玩家默认开启，或须以功能开关灰度。
