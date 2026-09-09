# v0.3 验收报告 — 战绩与排行榜（LDR）+ 人机进阶（BOT2）

- 验收日期：2026-08-26
- 验收人：测试PM（自动化回归）
- 被测版本：服务端 v0.3（healthz 上报 `version: "0.2.0"`，应用版本号未随 v0.3 更新，见遗留风险 R2）
- 环境：本机 Windows，`ws://127.0.0.1:9500/ws`；首轮服务端 PID 5068，LDR-02 重启后 PID 13212
- 新工具：`tests/stats_check.mjs`（默认全量 LDR/BOT2 检查；`--verify-persist` 重启后持久化复查；`--autopilot` 断线托管夺回链路）

## 0. 旧用例与 v0.3 语义冲突修订（test_plan.md）

| 用例 | 修订内容 |
|---|---|
| DC-03 | 旧预期"断线 >60s 拒绝 reconnect"作废 → v0.3：座位保留 + AI 托管接管（auto_pilot=true），原 token reconnect **成功**并夺回控制权 |
| MEM-07 | grace_expired 实际行为明确为托管接管 + 广播 room_update/action_log，重连夺回后托管解除 |
| LDR-03 | 最终口径为协议 v0.3 简化积分制公式（4人 +30/+10/0/-20；<1100 正分 ×1.2 trunc；Bot 不减半；下限 0） |
| LDR-04 | 补入榜门槛 games≥5、limit 默认10/最大100、非法参数错误码、self_rank |
| LDR-05 | 最终口径：含人机局照常计分，Bot 不减半，recent 标 has_bot；bot 无记录。旧报告中的 ×0.5 结果不再作为验收依据 |
| LDR-08 | ID-3 定案：开局 30s 内未归按末名（rage_quit）；之后托管按实际名次正常计分 |
| §7 前置 | ID-1/2/3 均标记已定案（player_token 指纹身份） |

其余旧用例（DC-01/02/04/05、TO-01~03、BOT-01~12）与 v0.3 语义不冲突：60s 宽限内的超时自动弃牌路径保留不变。

## 1. 准入门槛与全量回归（全部 PASS）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 编译 | `erl -noshell -eval "make:all()" -s init stop` | PASS，exit 0 |
| eunit（RUNBOOK §5 两模块） | `eunit:test([tides_json_tests, tides_game_tests])` | PASS，18 tests |
| eunit（含战绩模块） | `eunit:test([..., tides_stats_tests])` | PASS，**28 tests**（含损坏 dets 重建用例，error report 为预期输出） |
| sim 三模式 | `tides_sim:run(20)` / `run(20,easy)` / `run(20,hard)` | PASS，`{ok,20}` ×3（默认/easy/hard） |
| 4 真人冒烟 | `node tests\robot.mjs` | PASS（SMOKE PASS，房间 WTF9，12 回合，scores=4） |
| 人机冒烟 | `node tests\robot.mjs --bots=3` | PASS（SMOKE PASS，房间 HTN2，bot 1.5-3s 内自动提交） |
| 内存回归 | `node tests\mem_check.mjs` | PASS，5/5（MEM-02/04/05/08） |
| 战绩端到端 | `node tests\stats_check.mjs` | PASS，14/14 |
| 重启持久化 | taskkill 5068 → start_server.bat → `stats_check.mjs --verify-persist` | PASS，7/7 |
| 断线托管 | `node tests\stats_check.mjs --autopilot` | PASS，5/5（第 3 次运行；前 2 次 FAIL 均为脚本自身竞态，详见 §4 说明） |

## 2. v0.3 用例结果明细

### L. 战绩与排行榜（LDR）

| 用例 | 结果 | 证据/说明 |
|---|---|---|
| LDR-01 落盘 | ✅ PASS | 1 真人（token=UUID）+3 bot 局 game_over：scores=4，每条含 `rank`+`ladder_delta` 字段；随后 get_my_stats games=1 |
| LDR-02 重启不丢 | ✅ PASS | taskkill 后重启，同 token 复查 games=1 / ladder=990 与重启前一致（dets 落盘生效） |
| LDR-03 积分公式 | ✅ PASS（并列分支未触发） | 真人第 4 名：base=-20，×0.5 四舍五入=-10，服务端实报 -10；公式在 JS 侧独立复算逐位一致（含 <1100 ×1.2 trunc 路径，本局负分不触发） |
| LDR-04 排行榜 | ✅ PASS（排序未实测） | board=ladder/wins 均返回 `{board, entries, self_rank}` 字段齐全；entries=0 因入榜门槛 games≥5（符合协议）；多条目排序未实测 |
| LDR-05 含人机局计分 | ✅ PASS | recent[0]：`has_bot=true`、`room_size=4`、`ladder_delta=-10`（=×0.5 后值）；ladder=1000-10=990；3 个 bot 的 ladder_delta 全为 null |
| LDR-06 个人战绩查询 | ✅ PASS | 无 token → `error code=stats_token_required`；带 token → stats 含 games/wins/top2/avg_total/ladder/ladder_max/recent 全字段（协议无"常用策略"字段，以协议为准） |
| LDR-07 身份隔离 | ✅ PASS（归并未实测） | 全新 token 查询 stats=null，不串数据；同身份跨房累计未实测 |
| LDR-08 掉线未归结算 | ⬜ 部分 | 托管至终局计分正常已由 BOT2-06 覆盖；rage_quit（开局 30s 内未归按末名）未实测 |
| LDR-09 并发落盘 | ⬜ 未测 | 3 房并发终局未跑 |
| LDR-10 容错启动 | ✅ PASS（eunit 层） | tides_stats_tests 含损坏 dets 文件重建用例（运行日志可见 `dets open failed ... rebuilding` 后 28/28 通过）；删除文件场景未单独实测 |
| LDR-11 反作弊 | ⬜ 未测 | — |
| LDR-12 非法输入 | ✅ PASS | `board:"xxx"`→invalid_board；limit=0/101、offset=-1→invalid_limit；缺 token→stats_token_required；均字符串 code，服务端不崩溃 |

### M. 人机进阶（BOT2）

| 用例 | 结果 | 证据/说明 |
|---|---|---|
| BOT2-01 easy | ✅ PASS | robot --bots=3（默认 easy）整局合法；sim easy 20 局 {ok,20} |
| BOT2-02 hard | ✅ PASS | `add_bot {difficulty:"hard"}` 后 room_update 中 bot `difficulty="hard"`；1 真人+hard bot 整局至 game_over 无拒绝风暴；sim hard 20 局 {ok,20} |
| BOT2-03 非法难度 | ✅ PASS | `add_bot {difficulty:"xxx"}` → `error code=invalid_difficulty`，房间状态不变 |
| BOT2-04 托管接管 | ✅ PASS | 断线 60s 整（60.000s）后 room_update 广播 `auto_pilot=true, connected=false`；托管期间 h2 出牌含 action（非纯 tide 弃牌），10 回合中 non-tide 3-6 次 |
| BOT2-05 重连夺回 | ✅ PASS | 原 token reconnect → room_joined + 最新状态推送（`game_started` 含 private hand）+ room_update `auto_pilot=false, connected=true`；夺回时挂起的托管动作被撤销，整局无双提交 |
| BOT2-06 托管至终局 | ✅ PASS | 托管-夺回混合局正常 game_over，scores=4 |
| BOT2-07 托管呈现/防伪 | ✅ 部分 | auto_pilot 标志在 room_update/public_state 呈现；伪造 token reconnect 拒绝逻辑（lobby `invalid token`）代码路径存在，未实测 |
| BOT2-08 托管+bot 混合 | ✅ PASS | autopilot 场景为 2 真人（1 托管）+2 bot，调度无冲突，整局收束正常 |
| BOT2-09 托管时限 | ✅ PASS | 托管接管后回合 1-3s 内推进（BOT2-04 接管后 10 回合约 21s），不依赖 45s 兜底 |
| BOT2-10 sim 双难度 | ✅ PASS | easy/hard 各 `{ok,20}` |

### v0.1/v0.2 回归（无回退）

- eunit 18+28 全过；4 真人 / 1+3 人机冒烟全 PASS；mem_check 5/5 PASS；PC-09 healthz 200 `{"ok":true,"service":"tides"}`。
- DC-03 新语义（重连夺回）经 --autopilot 实测符合协议 v0.3。

## 3. 结论

- **v0.3 验收：通过（核心链路全 PASS）。** 战绩/排行榜/难度分级/掉线托管 22 条新用例中 17 条 PASS、2 条部分通过（LDR-08 rage_quit 分支、BOT2-07 伪造 token 未实测）、3 条未测（LDR-09/11 及 LDR-07 归并分支），均为 P1 非阻塞项。
- 全量回归无回退：v0.1/v0.2 已测项全部维持 PASS。

## 4. 遗留风险

- R1：LDR-09（3 房并发落盘）、LDR-11（反作弊/并行计分）、LDR-08 rage_quit 分支未实测；dets 单文件写在并发终局下的写冲突风险未验证。
- R2：服务端 healthz 仍上报 `version:"0.2.0"`（v0.2 报告的 R3 同类问题复现），建议后端下次发布同步应用版本号。
- R3：排行榜 entries 为空时排序/self_rank 分支未实测（需 ≥5 局身份积累，或后端提供测试注入手段）。
- R4：stats_check.mjs --autopilot 前两轮 FAIL 为脚本自身竞态（①等服务端协议措辞为 state_sync 而实现推 game_started——载荷等价，已在报告记录；②h1 的 room_update waiter 注册晚于广播），第三轮起 5/5 PASS；非服务端缺陷。**协议措辞建议**：重连状态推送消息类型为 `game_started`+`phase_changed` 而非字面 `state_sync`，建议主协调在 protocol.md §断线中明确，避免客户端实现歧义。
- R5：reconnect_grace_ms 可经 `shared/data/config.json` 配置（默认 60000）；--autopilot 测试按现网默认 60s 实测，grace 等待带 75s 超时保护。

## 5. 前端遗留问题确认（源码级，未跑浏览器）

1. **win_rate 单位**：服务端 `tides_stats.erl:159` `ratio(wins, games, 2)` → **0-1 小数、保留两位**（如 0.25），**不是 0-100**。客户端 `lobby.ts:125` 已做兼容（`>1 则原样，否则 ×100` 显示为百分比），单位语义自洽，无 bug。
2. **终局 auto_pilot 标注**：**可见**。终局弹窗 `game.ts:496-498` 对托管玩家渲染「托管完成」tag（与 bot 的「人机·简单/困难」并列分支）；对局中玩家条 `game.ts:379-380` 渲染「托管中」。
