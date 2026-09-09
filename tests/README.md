# tests/ — 测试资产说明

本目录由测试PM维护，包含：测试计划、MVP 验收清单、4 人整局冒烟机器人。

## 文件

| 文件 | 说明 |
|---|---|
| `test_plan.md` | 测试计划，56 条用例（协议一致性/规则/非法拒绝/断线/超时/并发/性能/隐藏信息） |
| `acceptance_checklist.md` | MVP 验收 checkbox 清单 |
| `robot.mjs` | 零依赖正式账号 4 人整局冒烟机器人（Node >= 22，使用全局 WebSocket）；连接先用 `login` 或 `session` 认证并记录 `account_session/role_id`；账号通过 `TEST_ACCOUNTS=<JSON>` 或 `TEST_ACCOUNT_FIXTURE=<JSON文件>` 注入；兼容 `TEST_PLAYER_TOKENS`，但其值明确是 session token，不是账号或房间 token；`--bots=N`（1-3）为 1 账号 + N 个房间临时 Bot |
| `mem_check.mjs` | v0.2 内存回归脚本（MEM-02/04/05/08）：重复建房、200 次异常 TCP 连接、lobby 房主断开/转移、孤儿房间检查 |
| `stats_check.mjs` | v0.3 战绩/人机进阶端到端脚本（LDR/BOT2 可自动化项）；账号按 `role_id` 查询；游客实际发送受保护请求并断言 `authentication_required`；Bot 不减半；`--verify-persist` 重启后持久化复查；`--autopilot` 断线托管接管+重连夺回链路 |
| `issue1_regression.mjs` | 问题1快速回归：旧重连凭据失败后可建新房、有效房间重复建房拒绝、断线宽限内重连恢复 |
| `acceptance_report_v0.3.md` | v0.3 战绩与排行榜 + 人机进阶验收报告 |
| `acceptance_report_v0.2.md` | v0.2 内存修复 + 人机功能验收报告 |
| `proxy_sim.mjs` | 零依赖本地反向代理模拟（Node 内置 http/net）：静态托管 `client/dist`（SPA 回退 index.html）+ `/ws` Upgrade 隧道转发 127.0.0.1:9500，用于验证 nginx `location /ws` 反代形态（PC-10） |
| `mysql_readonly_check.mjs` | 只读 MySQL driver、连接和 `accounts` schema 检查；凭据仅从进程环境读取，不执行清档或写入数据库 |
| `tidesctl_static_check.mjs` | `deploy/tidesctl.bat`（ASCII 转发）、`tidesctl.cmd`（GBK/CRLF、本地中文 help、业务转发）、`tidesctl.ps1` 与 `tidesctl.sh` 的只读静态门禁：命令、错误传播、编码、凭据安全、init-db 不清档、reset-dev 开发保护 |
| `tidesctl_plan.md` | tidesctl Windows/Linux 静态与行为测试计划、验收矩阵 |
| `new_player_tutorial_m3_smoke.mjs` | 零依赖 M3 教程协议门禁及可选 WebSocket 探测；严格区分 PASS、FAIL、BLOCKED |
| `identity_lifecycle_skeleton.mjs` | 游客禁止联机、纯客户端教程及教程后注册/退出、Bot 房间临时清理、账号 role 生命周期的契约门禁/测试骨架；缺少最终接口或 fixture 时只输出 BLOCKED |
| `quit_game_check.mjs` | v0.5 退出对战端到端检查（LQ-01~08）：场景 A=4 人局第 2 回合退出（ack+returned_to_lobby、player_left、reconnect 拒绝、立即 list/create_room、game_over rank=4/rage_quit/ladder_delta=-20、stats games+1/win_streak=0）；场景 B=2 人局退出立即终局 + lobby 阶段 not_in_game；`--register` 自注册隔离账号 |

## 运行冒烟机器人

前置：服务端已启动并监听 WebSocket（默认 9500 端口，路径 `/ws`），且已准备隔离账号 fixture。游客不得运行正式对战机器人。

```bat
:: 无账号 fixture 时必须 BLOCKED（exit 2），不会建立游客房间
node tests\robot.mjs

:: 指定其他地址
node tests\robot.mjs ws://192.168.1.10:9500/ws

:: 人机模式：1 账号脚本 + 3 房间临时 bot（BOT-12）
node tests\robot.mjs --bots=3

:: 配置账号 fixture（密码不硬编码到脚本，不把 room token 当账号身份）
set TEST_ACCOUNTS=[{"account_name":"test_a","password":"<local-password>"},...]
node tests\robot.mjs --bots=3

:: 身份/教程/清理/role 骨架；未提供 fixture 时预期 exit 2
node tests\identity_lifecycle_skeleton.mjs

:: v0.5 退出对战检查（需服务端已启动；--register 自注册隔离账号，否则用 TEST_ACCOUNT_FIXTURE）
node tests\quit_game_check.mjs --register
node tests\quit_game_check.mjs --scenario=a   :: 仅 4 人局退出场景
node tests\quit_game_check.mjs --scenario=b   :: 仅 2 人局立即终局 + lobby 拒绝场景
```

## 内存回归（mem_check.mjs）

```bat
node tests\mem_check.mjs

:: 问题1：旧凭据/重复建房/宽限内重连
node tests\issue1_regression.mjs
```
覆盖 MEM-05（200 次异常 TCP 连接后仍可建房）→ MEM-02（同连接 50 次重复 create_room 全部 `already_in_room`）→ MEM-08（lobby 房主断开：单人房间消失 / 2 人房主转移）→ MEM-04（无孤儿房间）。输出 `MEM_CHECK PASS`（exit 0）或逐项 FAIL 明细。

`issue1_regression.mjs` 不操作浏览器 `localStorage`，而是验证其清理后必须满足的协议结果：失效 reconnect 后同一连接可 `create_room`。浏览器存储清理、重连失败 UI 和 60s 后托管接管仍需按验收清单人工/`stats_check.mjs --autopilot` 验证。

## M3 教程最小冒烟

当前最终模型中 `tutorial_practice` 已废弃：游客只能使用客户端教程，不能调用服务端 `start_practice` 或进入真实对局。

```bat
:: 仅检查历史 M3 契约；游客纯客户端教程不得据此宣称可调用服务端教程接口
node tests\new_player_tutorial_m3_smoke.mjs

:: 连接运行中的服务端，执行真实 status/start/reconnect/replay/隔离探测
node tests\new_player_tutorial_m3_smoke.mjs --live
```

脚本使用 Node 原生 `WebSocket`，不创建账号、不完成 T9，也不写数据库。缺少教程状态版本字段、服务端未启动、没有可用完成账号 fixture 或协议响应不可观察时输出 `BLOCKED`，退出码为 `2`；不得据此宣称 M3 通过。`FAIL` 仅表示已收到可判定的错误响应或身份/幂等断言失败。

行为：
1. 本正式对战机器人仅适用于账号 fixture；游客只能在客户端完成教程，游客连接不得创建服务端房间。
2. 每个 select 阶段按优先级自动行动：deliver（货物满足公开订单）→ trade（buy salt×1）→ sail（去相邻港口）→ post → 兜底 mode=tide 弃手牌第 1 张；行动被拒时自动尝试下一候选；Bot 参与不使账号战绩减半。
3. 收到 `game_over` 校验 scores=4 人且 total≥0，随后等待 `returned_to_lobby`，并验证可再次 `list_rooms`。

退出码：
- `0` + 输出 `SMOKE PASS`：整局通过。
- `1` + 输出 `SMOKE FAIL`：120s 全局超时、连续 error/action_rejected >20 次、连接异常断开或终局数据校验失败；失败时打印原因与最后状态摘要。

日志：关键事件带 ISO 时间戳，单局 ≤100 行（超出后停止打印但继续运行）。

## 生产代理路径模拟（proxy_sim.mjs）

前置：服务端已启动（9500），`client/dist` 已构建。

```bat
:: 终端1：启动本地反向代理（127.0.0.1:18080）
node tests\proxy_sim.mjs

:: 终端2：经代理跑完整 4 人局
node tests\robot.mjs ws://127.0.0.1:18080/ws
```

行为：
- `GET /` 与 `GET /assets/*` 返回 `client/dist` 对应文件；其他 GET 路径回退 `index.html`（SPA）。
- `/ws` 的 Upgrade 请求以原始 TCP 隧道转发到 `127.0.0.1:9500`（逐字转发握手请求行与原始头，随后双向 pipe）。
- 验证完毕务必关闭代理进程，并 `netstat -ano | findstr :18080` 确认无 LISTENING 残留。

## 对照验收

### MySQL 只读检查

在提供本地凭据的同一进程中运行，密码通过环境变量传递，不作为命令行参数：

```bat
set MYSQL_HOST=127.0.0.1
set MYSQL_PORT=3306
set MYSQL_USER=<local-user>
set MYSQL_DATABASE=<isolated-development-database>
set MYSQL_PASSWORD=<local-password>
node tests\mysql_readonly_check.mjs
```

脚本只执行 `SELECT VERSION()` 和 `information_schema.columns` 查询。不要使用 `reset-dev` 或任何清档命令；`MYSQL_PASSWORD` 不会写入文件、输出或子进程参数。

1. 先跑 `robot.mjs` 确认冒烟通过（对应 checklist「核心功能」整局链路）。
2. 按 `acceptance_checklist.md` 逐项验证：
   - 不同网络 4 人整局、讲解 ≤10 分钟、单局 ≤60 分钟：真人实测记录。
   - 断线重连/超时：参照 `test_plan.md` DC/TO 用例步骤手工操作。
   - 10 并发房间：并行启动 10 个 `robot.mjs` 进程（每进程 1 房），全部 PASS 即通过（CC-03）。
   - 隐藏信息：抓包任一客户端的 `state_sync`，确认无他人 hand/hidden_contracts（SC-01）。
3. 全部 P0 用例通过 + checklist 无 ❌ 后，填写验收结论。
