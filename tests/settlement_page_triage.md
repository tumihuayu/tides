# 战斗结算页 分诊报告（测试PM）

> 需求：对战结束后弹出战斗结算页面，包含 ① 对战结果（胜利/失败）② 近七天胜率 ③ 连胜场次 ④ 此次对战的结算信息。
> 日期：2026-09-04 ｜ 范围：仅调研与分诊，不改动 tests/ 以外文件。

---

## 1. 现状摘要

### 1.1 服务端
- 终局流程：`tides_room.erl:481 resolve_flow` → `tides_game:is_over` → `finalize_scores`（tides_room.erl:424）按 total 排名（并列同名次、rage_quit 强制末名）→ `tides_stats:record_game` 同步落盘 → 广播 `game_over`（tides_room.erl:501）→ 1s 后 `stop_room`，`notify_roles` 使账号回大厅（`returned_to_lobby`）。
- `game_over` payload 现有：`scores:[{player_id, total, rank, ladder_delta, breakdown}]`、`room_mode`、`stats_eligible`。**不含胜负结论、7 日胜率、连胜场次。**
- 战绩档案 `tides_stats.erl #r_prof`：`games/wins/top2/total_sum/ladder/ladder_max/recent(仅保留 10 条)`。**无连胜字段、无时间窗统计字段。**
- recent 只存 10 条（tides_stats.erl:226），7 天内若打超过 10 局，客户端无法从 recent 推出「近七天胜率」；连胜在 recent 内可推但跨 10 条边界会断。

### 1.2 客户端
- `main.ts:592` 收 `game_over` → `game.ts:486 showGameOver`：现有计分板含名次、`ladder_delta`、breakdown、「再来一局」按钮。**无胜利/失败标题、无 7 日胜率、无连胜。**
- `get_my_stats`/`my_stats` 已存在（main.ts:140/601，profile.ts 个人中心展示），stats 结构见 types.ts:111，无连胜/7日字段。
- `stats_eligible=false`（如旧陪练）时不写正式统计，结算页需降级展示。

### 1.3 文档
- `docs/06_stats_leaderboard_v1.0.md` §4/§6.4 已冻结现有口径（ladder_delta、recent 字段），未定义「胜利/失败」「近七天胜率」「连胜」口径。
- `docs/05_ui_spec.md` S6 仅描述终局计分板 breakdown 展示，无结算页新元素规范。

---

## 2. 影响面分析

| 层 | 文件 | 影响 |
|---|---|---|
| shared | `protocol.md` | 需新增/扩展消息字段：`game_over` 扩展或 `my_stats` 扩展（见 §4.4），由主协调决定 |
| server | `tides_stats.erl` | 档案需支持连胜（当前连胜/连败）与 7 日窗口统计；recent 10 条上限不足以算 7 日胜率，需加时间窗累计字段或拉长历史 |
| server | `tides_room.erl` | `finalize_scores`/`game_over` 广播时附带本人结算摘要（若走 game_over 扩展方案） |
| server | `tides_stats_tests.erl` 等 | 新增字段的 eunit 覆盖 |
| client | `types.ts` | `PlayerStats`/`ScoreEntry`/新结算类型定义 |
| client | `game.ts` `showGameOver` | 结算页改版：胜负标题、7日胜率、连胜、本场结算信息 |
| client | `main.ts` | game_over 后拉取 stats（若走 my_stats 方案）或消费扩展字段；注意 1s 后 `returned_to_lobby` 不打断结算页 |
| client | `profile.ts`（可选） | 个人中心是否同步展示连胜/7日胜率，待策划定 |
| docs | 06 统计文档 / 05 UI 规范 | 口径定义与 UI 规范需补充（策划 agent） |
| tests | 新增冒烟/验收脚本 | 见 §3 |

---

## 3. 验收标准（可测试清单）

### 3.1 功能主路径
1. 正常打完一局（2/3/4 人局均可）→ 所有在场真人客户端弹出结算页，含：胜负结果、近七天胜率、连胜场次、本场结算信息（名次、总分、breakdown、ladder_delta）。
2. 本人 `rank=1` → 显示「胜利」；`rank>1` → 显示「失败」（若策划改为 top2 算胜等其它口径，以策划案为准）。
3. 本场结算信息与 `game_over.scores` 中本人条目一致：rank、total、breakdown 各项、`ladder_delta`（含 ± 与 0 的显示）。
4. 近七天胜率 = 近 7 天窗口内胜场/场次，与 `my_stats`（或扩展字段）服务端口径一致，显示精度符合策划定义（如保留整数%）。
5. 连胜场次：刚赢一局后连胜 ≥1；刚输一局后连胜为 0（或按策划定义显示连败 N）。

### 3.2 边界
6. **新玩家首战**：无任何历史战绩 → 7 日胜率显示「—」或「暂无」（不显示 NaN/除零错误）；胜利则连胜=1，失败则连胜=0。
7. **连败**：连续输 N 局后，连胜显示 0（或连败 N，按策划口径）；随后赢 1 局连胜归 1。
8. **跨七天窗口**：构造 ts 距今 6 天 23 小时（计入）与 7 天 1 小时（不计入）的历史记录 → 7 日胜率只统计窗口内对局。窗口边界（含/不含恰好 7×24h 整点）以策划口径为准，验证一致性。
9. **七天窗口内 >10 局**：7 日内打 11+ 局 → 7 日胜率仍正确（验证服务端不是从 recent 10 条硬算的）。
10. **掉线/托管（auto_pilot）**：30s 后掉线由 AI 托管打完 → 该对局计入统计与 7 日胜率/连胜，结算页数值含此局。
11. **秒退（rage_quit）**：开局 30s 内退出且未归 → 强制末名、按败计入；该玩家（若能看到结算）与其余玩家统计一致，连胜清零。
12. **不计入对局**：游客、bot、`stats_eligible=false` 局 → 不产生统计；结算页对这些玩家不显示或降级显示 7 日胜率/连胜（如「本局不计入正式战绩」）。
13. **并列第一**：两人并列 rank=1 → 双方都判胜、双方连胜 +1（与现有 wins 口径「并列第1各计1胜」一致）。
14. **再来一局/返回大厅**：点「再来一局」或收到 `returned_to_lobby` → 结算页正常关闭、回大厅无报错；1s 后房间解散不影响结算页已展示数据。
15. **断线重连到 game_over 阶段**（若服务端支持）：重连后能看到结算信息或明确降级行为（待策划/后端确认是否支持）。

### 3.3 回归
16. 既有验收不回归：`tests/robot.mjs` 4 人整局冒烟通过；eunit + 20 局自玩模拟通过；`game_over` 现有字段（rank/ladder_delta/breakdown）格式不变，旧客户端字段兼容。
17. 个人中心（profile.ts）战绩展示不受影响；若策划要求同步展示连胜/7日胜率，另行验收。

---

## 4. 实现拆分建议

### 4.1 策划（docs/）
需输出结算页策划案（新文档或补 06/05），明确：
1. **胜负口径**：rank=1 判胜？2 人局是否同口径？平局（并列第1）算胜？
2. **近七天胜率口径**：窗口定义（滚动 7×24h？按自然日？）、边界含/不含、胜=第1名还是 top2、无对局时展示文案、精度（整数%/一位小数）、分母是否含人机局（建议：与正式统计口径一致，含人机局）。
3. **连胜口径**：连胜=连续第1名？连败是否显示（「连败 N」）？并列第1是否续连胜？不计入局（practice/游客）是否打断连胜（建议不打断、不计入）？秒退判负是否断连胜（建议断）。
4. **结算信息内容清单**：本场名次/总分/breakdown 各项/ladder_delta/天梯分变动后分值、人机局标记、托管标记等展示项与文案。
5. UI 布局：结算页在现有 S6 计分板基础上扩展还是独立全屏页；降级态（不计入局、无历史）样式。

### 4.2 后端（server/）
1. `tides_stats.erl`：档案新增字段，建议：
   - `win_streak`（当前连胜，胜 +1、负清零；并列第1按胜处理）；
   - 7 日窗口统计：维护带 ts 的滑窗累计（如 `recent` 扩容并保留 ts 足够久，或新增 `day_buckets`/`hist_7d: {games_7d, wins_7d}`），保证 7 日 >10 局仍正确；
   - `record_game` 时更新上述字段；`stats_json` 输出 `win_streak`、`games_7d`、`wins_7d`（或 `win_rate_7d`）。
2. `game_over` 扩展（与主协调定方案二选一）：
   - 方案 A：`game_over.scores[]` 本人条目旁加 `result: "win"|"lose"`，并新增顶层 `self_summary: {result, win_streak, games_7d, wins_7d}`（每连接个性化，需定向发送而非纯广播——注意当前 game_over 是 bcast，个性化需 send_to 改造）；
   - 方案 B：不动 `game_over`，客户端收到 game_over 后发 `get_my_stats`（此时统计已落盘，时序上 record_game 先于广播，安全），从扩展后的 `my_stats` 取连胜/7日数据，胜负由 rank 自判。**改动最小，推荐**。
3. rage_quit/托管/并列的 streak 与 7d 更新逻辑与既有计分口径保持一致。
4. eunit 覆盖：新字段计算、窗口边界、连败清零、并列第1、秒退。

### 4.3 前端（client/）
1. `types.ts`：扩展 `PlayerStats`（`win_streak`、`games_7d`、`wins_7d`/`win_rate_7d`）；如走方案 A 再加结算类型。
2. `game.ts showGameOver`：
   - 标题区按本人 rank 显示「胜利 / 失败」样式区分；
   - 新增统计区：近七天胜率（无数据显示「—」）、连胜场次（连败按策划文案）；
   - 保留现有本场结算信息（名次、breakdown、ladder_delta）；
   - `stats_eligible=false` 时不展示统计区并给提示文案。
3. `main.ts`：方案 B 下 game_over 时 `net.send('get_my_stats')`，`my_stats` 到达后刷新结算页统计区（注意 my_stats 现有 handler 只在 profile/lobby 触发 render，需扩展到结算遮罩更新）；保证 `returned_to_lobby` 不提前销毁结算页。
4. 处理时序：game_over 先到、my_stats 后到，统计区需有加载态。

### 4.4 shared/（建议，主协调决定）
- `my_stats` 的 stats 增加：`win_streak: number`、`games_7d: number`、`wins_7d: number`（或 `win_rate_7d`）。
- 若选方案 A：`game_over` 增加个性化结算摘要消息（建议新消息 `settlement` 定向下发，避免污染广播结构）。
- 更新 protocol.md v0.3 → v0.4 消息表与战绩章节，明确连胜/7日口径与 game_over 时序（record_game 先于 game_over 广播，客户端可在收到 game_over 后立即拉取）。

### 4.5 测试PM 后续工作
1. 待策划口径冻结后产出验收清单正式版与冒烟脚本（基于 robot.mjs 扩展：打完一局校验 game_over + my_stats 新字段与结算页 DOM）。
2. 构造窗口边界用例需服务端可注入历史 ts（建议后端提供测试钩子或用 eunit 覆盖，冒烟层只测主路径）。

---

## 5. 风险与开放问题
1. recent 仅 10 条：若后端选择从 recent 计算 7 日胜率，7 日 >10 局会算错——验收项 9 专防此点，建议服务端独立滑窗字段。
2. game_over 是广播、无个性化数据：方案 A 需改造为定向发送，影响面大于方案 B。
3. `returned_to_lobby` 在 game_over 后 1s 到达：现有客户端逻辑（main.ts:497）切换页面时需确认结算遮罩不被误关。
4. 「胜利/失败」与现有 top2/wins 口径的关系需策划明确，避免结算页「失败」但个人中心前二率上升的观感冲突。
5. 断线重连到已结束房间的结算可见性：当前协议 game_over 阶段重连恢复未明确含 scores，需策划裁决是否支持。
