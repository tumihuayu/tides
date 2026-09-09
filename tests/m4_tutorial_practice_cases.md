# M4 新手陪练验收用例

版本：M4 tutorial practice
验收角色：测试 PM
事实来源：`shared/protocol.md:42,68,81,87-107,134-139,171-175`；普通 BOT/BOT2/LDR 基线见 `tests/robot.mjs`、`tests/stats_check.mjs` 和 `tests/acceptance_checklist.md`。

## 1. 范围与判定

最终身份模型下 `tutorial_practice` 已废弃，不验收 `start_practice`：游客无 `role_id`/`PlayerProcess`，只能进行纯客户端教程；游客不得创建房间、加入房间、重连、开始陪练或进行任何真实对战。旧服务端陪练用例全部保留为 BLOCKED 历史骨架。

`PASS` 只表示本用例实际收到并校验了运行时帧。协议文字或历史 BOT/LDR 结果只能作为前置依据，不能替代 M4 live 证据。服务端未启动、没有已完成 T1-T9 的可用身份、数据库/战绩查询不可用或超时，均记 `BLOCKED`；响应不符合预期记 `FAIL`。

## 2. 前置条件

| 编号 | 条件 | 不满足时 |
|---|---|---|
| F-01 | Node >= 22，使用原生 `WebSocket` | BLOCKED |
| F-02 | 服务端监听 `ws://127.0.0.1:9500/ws`（可传 URL） | BLOCKED |
| F-03 | 有一个已完成 T1-T9 的账号 `player_token`；脚本通过 `M4_COMPLETED_TOKEN` 注入 | 完成资格、陪练主链路 BLOCKED，不伪造完成 |
| F-04 | 可在陪练前后读取同一身份 `my_stats`，并保存完整快照 | 统计隔离用例 BLOCKED |
| F-05 | 可另建普通房并由房主手动 `add_bot` | 普通 bot 计分用例 BLOCKED |

## 3. 用例

| ID | 场景与步骤 | 预期 |
|---|---|---|
| M4-P01 | 未完成的新 token 发送 `start_practice` | `error`，`payload.code` 为字符串；不得创建房间 |
| M4-P02 | 已完成身份发送 `start_practice` | 收到 `practice_started`，含 `room_id`、`room_mode=tutorial_practice`、`stats_eligible=false` |
| M4-P03 | 同一已完成身份在原连接重复发送相同 `start_practice` 请求 | 幂等：不新增第二个陪练房；重复请求返回同一房间/等价已开始结果，或明确字符串错误，不得产生第二局 |
| M4-P04 | 陪练创建后的 `room_update`/`game_started` | 恰好 1 真人 + 1 bot；bot `is_bot=true`、`difficulty=easy`、ready=true；真人携带原 token |
| M4-G01 | 检查陪练 `game_started` | `room_mode=tutorial_practice`、`stats_eligible=false`；正式初始资源/手牌结构可见，不是 T1-T9 固定快照 |
| M4-G02 | 真人和 easy bot 逐回合推进 | 使用正式 4 轮 × 3 回合；真人提交合法正式行动，bot 在时限内合法行动；无持续拒绝/45 秒兜底依赖 |
| M4-G03 | 陪练终局 | `game_over` 含 2 个 scores；`room_mode=tutorial_practice`、`stats_eligible=false`；真人 `ladder_delta=null` |
| M4-S01 | 对比陪练前后 `get_my_stats` 与排行榜 | `games/wins/top2/avg_total/ladder/ladder_max/recent` 和排行榜结果不变 |
| M4-N01 | 普通房房主手动 `add_bot {}` 后按 BOT 基线开局至终局 | 普通房仍 `room_mode=normal`、`stats_eligible=true`；带 token 真人按含 bot 规则产生正式统计/天梯变化，bot delta 为 null |
| M4-B01 | 非陪练真人尝试 `join_room` 已开始/已创建的陪练房 | 被拒绝，返回字符串 `error`；陪练仍只有原真人 + easy bot |
| M4-B02 | 陪练房主发送 `add_bot {}` | 被拒绝，返回字符串 `error`；人数和 bot 数不变 |
| M4-R01 | 陪练进行中断开真人连接，宽限期内用原 room/player/token `reconnect` | 收到 `room_joined` 及游戏阶段恢复快照（`game_started` + private hand）；继续推进，无双提交 |
| M4-R02 | 重连后陪练继续到终局 | 原房间正常收束；不产生第二房间、第二真人座位或 bot 残留 |
| M4-I01 | 陪练期间另建普通房/发送普通房行动 | 会话隔离；不串 room_id、状态、行动或教程完成状态 |

共 **14 条**（P01-P04 4 条、G01-G03 3 条、S01 1 条、N01 1 条、B01-B02 2 条、R01-R02 2 条、I01 1 条）。

## 4. 执行入口与结果规则

静态/环境门禁：

```text
node tests/m4_tutorial_practice_smoke.mjs
```

live 探测（必须有已完成账号 token）：

```text
set M4_COMPLETED_TOKEN=<completed-account-player-token>
node tests/m4_tutorial_practice_smoke.mjs --live ws://127.0.0.1:9500/ws
```

脚本不会自动完成 T1-T9，也不会修改数据库或伪造 `completed`。未提供 fixture、协议/服务端实现缺失、服务不可达、统计查询不可用均输出 `BLOCKED` 并以退出码 2 结束；仅实际断言失败时退出码 1。

## 5. 本轮执行记录

| 日期 | 命令 | 结果 |
|---|---|---|
| 2026-08-28 | `node tests/m4_tutorial_practice_smoke.mjs` | `PASS=0 FAIL=0 BLOCKED=1 TOTAL=1`（协议存在；服务端源码未实现/未暴露 `start_practice` 等 M4 路由，故 BLOCKED） |
