# 战斗结算页 验收报告（测试PM）

> 需求：对战结束后弹出战斗结算页面（①胜负结果 ②近七天胜率 ③连胜场次 ④当局结算信息）。
> 日期：2026-09-04 ｜ 依据：tests/settlement_page_triage.md §3、docs/12_battle_settlement_v1.0.md（冻结口径）、shared/protocol.md v0.4。

---

## 1. 验收结论：**通过（PASS）**

四区功能、边界口径、降级/异常态均与策划冻结口径一致；服务端编译/eunit/20 局模拟、客户端构建、4 人整局冒烟全部通过；并做了 my_stats 新字段的在线协议级实证。未发现实现 bug。发现 1 项低严重级文档内部不一致（见 §4）。

## 2. 命令执行结果

| 命令 | 结果 |
|---|---|
| `cd server && erl -noshell -eval "make:all()" -s init stop` | ✅ 通过（无报错输出，exit 0） |
| eunit `[tides_json_tests, tides_game_tests, tides_stats_tests]` + `tides_sim:run(20)` | ✅ **38 tests passed**，sim `{ok,20}`，exit 0（日志中 `dets open failed ... rebuilding` 为 corrupt_file_rebuild_test 用例的预期输出） |
| `cd client && npm run build` | ✅ 通过（tsc + vite build，13 modules，无错误） |
| 服务端启动（`deploy\start_server.bat`，erl PID 26740） | ✅ healthz `{"ok":true,"version":"0.3.2"}`；冒烟结束后已 taskkill，9500 无 LISTENING 残留（仅 TIME_WAIT） |
| `node tests\robot.mjs`（fixture 由 `tests\_baseline_fixture.mjs` 现场注册 4 账号，写入 %TEMP% 用后删除） | ✅ **SMOKE PASS**（exit 0）：房间 F299，4 轮整局至 game_over，scores=4 且 total≥0，随后 returned_to_lobby + list_rooms 正常 |
| 在线实证 `get_my_stats`（本局胜者 p4 / 末名 p3 两账号） | ✅ p4：`{win_streak:1, games_7d:1, wins_7d:1, games:1, wins:1, ladder:1036}`（1000+30×1.2 低分加成）；p3：`{win_streak:0, games_7d:1, wins_7d:0, ladder:980}`——v0.4 三字段已在线下发且口径正确，落盘先于 game_over 的时序链路透传验证通过 |

## 3. 验收标准逐项核对（对应分诊 §3 编号）

### 3.1 功能主路径

| # | 项 | 结论 | 证据 |
|---|---|---|---|
| 1 | 正常整局弹结算页含四要素 | ✅ 通过 | robot 整局 PASS；UI 四区结构 game.ts:556-643（标题/统计/明细/返回大厅） |
| 2 | rank=1 判胜、rank>1 判负 | ✅ 通过 | game.ts:571 `meScore?.rank === 1`；口径 docs/12 §2.1 |
| 3 | 本场结算与 scores 本人条目一致 | ✅ 通过 | 副标题 game.ts:573-582（#rank · total · 天梯 ±delta，null→`—`）；明细行 game.ts:594-635 含 breakdown 逐项与 ladder_delta 三态（+/−/0） |
| 4 | 7 日胜率口径一致、整数% | ✅ 通过 | 服务端 slide_counts（tides_stats.erl:219-221）；客户端 `Math.round(wins7d/games7d*100)%`+`N胜/M场`（game.ts:524-525），与 docs/12 §2.2 一致；在线实证 wins_7d/games_7d=1/1 |
| 5 | 连胜：胜后≥1、负后清零 | ✅ 通过 | tides_stats.erl:254-257；eunit `win_streak_inc_reset_test`（3 连胜→负清零→胜归 1）PASS；在线实证胜者=1/负者=0 |

### 3.2 边界

| # | 项 | 结论 | 证据 |
|---|---|---|---|
| 6 | 新玩家首战：games_7d=0 显示「—」不 NaN | ✅ 通过 | game.ts:524-525 `games7d>0 ? ... : '—'` + 「近 7 天暂无对局」；`stats=null` 走 `stats?.games_7d ?? 0` 同路径（game.ts:519-520），符合 docs/12 §4.3 |
| 7 | 连败清零、再胜归 1 | ✅ 通过 | eunit `win_streak_inc_reset_test` PASS；0 时文案「暂无连胜」（game.ts:528） |
| 8 | 7 日窗口含等号边界 | ✅ 通过 | tides_stats.erl:220 `T >= Now - 604800`；eunit `slide_window_boundary_test`：T0+604800 计入 {1,1}、T0+604801 剔除 {0,0} PASS，与 docs/12 §2.2「含等号」一致 |
| 9 | 7 日内 >10 局仍正确 | ✅ 通过 | 独立 hist_7d 滑窗（上限 200，tides_stats.erl:26/214-216），不从 recent 10 条推算；eunit `games_7d_beyond_recent_10_test`：12 局 games_7d=12、wins_7d=8 PASS |
| 10 | 掉线托管计入统计 | ✅ 通过（静态） | 托管玩家 role_id 仍在 Entries 中，finalize_scores（tides_room.erl:441-447）不区分 auto_pilot，正常 record_game；未做动态断线托管用例 |
| 11 | 秒退强制末名按败计、断连胜 | ✅ 通过（静态+eunit 间接） | tides_room.erl:432-434 rage_quit rank=N>1 → tides_stats.erl:254-257 清零、WinInt=0（:244）；与 docs/12 §2.3 一致；未做动态秒退用例 |
| 12 | stats_eligible=false 不计入不打断、降级展示 | ✅ 通过 | 服务端 tides_room.erl:448-449 直接跳过 record_game（连胜原地保持）；客户端 game.ts:568-569 标题「对局结束」、:587-588 统计区「本局不计入正式战绩」 |
| 13 | 并列第一双方判胜、连胜各 +1、双方 👑 | ✅ 通过 | 服务端排名 tides_room.erl:437（并列同 rank=1）；eunit `win_streak_tie_first_test`（双方 +1、wins_7d/games_7d=1）PASS；客户端 game.ts:598/602 `sc.rank===1` 即 👑，并列者均加冠 |
| 14 | returned_to_lobby 不关闭结算弹窗 | ✅ 通过 | main.ts:523-530 仅切屏+render；render() main.ts:139-141 `replaceChildren` 后重挂 `mask-gameover`，遮罩保留至玩家点「返回大厅」（game.ts:636-640）主动关闭 |
| 15 | game_over 阶段断线重连恢复结算 | ⬜ 未覆盖（策划裁决本期不支持） | docs/12 §5.3 明确不扩展 reconnect；非缺陷 |

### 3.3 回归

| # | 项 | 结论 | 证据 |
|---|---|---|---|
| 16 | robot 冒烟 / eunit / sim / game_over 旧字段不变 | ✅ 通过 | 见 §2；game_over 结构未改（tides_room.erl:501-503 仅原有 scores/room_mode/stats_eligible） |
| 17 | 个人中心不受影响 | ✅ 通过 | profile 渲染路径未改；my_stats handler（main.ts:630-639）仅在 settleStatsPending 时路由到结算遮罩，profile/lobby 渲染照旧；PlayerStats 新字段为可选（types.ts:118-120） |

### 异常态（docs/12 §4.3 补充核对）

| 项 | 结论 | 证据 |
|---|---|---|
| my_stats 加载态 | ✅ | 统计区初始占位 `…`（game.ts:492/500） |
| my_stats 失败/超时重试 | ✅ | 5s 超时 → settlementStatsFailed（main.ts:57-70）；失败态「战绩统计加载失败」+「重试」按钮重发（game.ts:541-554，settlementRetry=onRetryStats game.ts:557/main.ts:623） |
| 弹窗打开期间断线 | ✅ | main.ts:690-696 断线且 pending 时转入失败态（可重试），已渲染内容保留 |
| 旧档案兼容升级 | ✅ | upgrade_prof（tides_stats.erl:204-210）缺字段补 0/[]；eunit `old_profile_compat_test` PASS |
| 协议文档同步 | ✅ | shared/protocol.md v0.4 :92 已写明三字段口径与时序保证，与实现一致 |

## 4. 发现的问题

| 编号 | 严重级 | 问题 | 位置 |
|---|---|---|---|
| SP-1 | 低（文档） | docs/12 内部不一致：§2.3 写「连胜 N 场（N ≥ 1 时高亮）」，§4.2 写「≥2 时数字用汐金高亮」。实现按 §4.2（`winStreak >= 2` 加 gold，game.ts:529）。建议策划/主协调统一口径，实现侧无需改动 | docs/12_battle_settlement_v1.0.md §2.3 vs §4.2；client/src/game.ts:529 |

无实现 bug，未修改 server/ 或 client/ 任何文件。

## 5. 未动态覆盖项（环境/成本限制，均已有静态或 eunit 证据）

1. 浏览器端 DOM 实测（四区渲染、重试按钮点击）——本轮为构建+静态核对+协议级实证，建议下次联调窗口人工过一遍视觉效果。
2. 秒退（rage_quit）与掉线托管的整局动态用例——服务端逻辑静态核对一致，动态路径沿用既有 test_plan DC/TO 用例，本轮未重跑。
3. 验收项 15（game_over 阶段重连恢复）——策划裁决本期不支持，关闭。

## 6. 环境收尾

- 服务端 erl（PID 26740）已 taskkill，9500 端口无 LISTENING 残留。
- fixture 文件 `%TEMP%\opencode\settle_fixture.json` 用后已删除；4 个 bl_rb* 隔离账号留在开发库中（与既往基线回归惯例一致）。
