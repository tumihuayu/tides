# 《潮汐商会》联机协议 v0.5

传输：WebSocket（RFC6455）文本帧，JSON 编码。服务端监听端口见 `data/config.json`（默认 9500），路径 `/ws`。

## 通用信封
```json
{
  "type": "submit_card",
  "room_id": "A7Q2",
  "player_id": "p1",
  "action_id": "uuid-由客户端生成用于去重",
  "seq": 12,
  "ts": 1730000000,
  "payload": {}
}
```
- 服务端→客户端的 `state_sync` 必须携带单调递增 `seq`。
- 所有客户端行动必须带 `action_id`，服务端去重，重复提交直接忽略并回 `ack`。
- 认证身份由服务端按连接上的账号 session 状态确定（经 `register`/`login`/`session` 建立），客户端提交的 `account_id`、`role_id` 或旧 `player_token` 不可信。
- 未认证连接是游客，只能进行纯客户端新手教程和账号注册/登录；游客没有 `role_id`，不能创建、加入或重连真实房间，也不产生正式统计。
- `role_id` 是注册账号的长期玩家身份和正式统计归属键。`player_token` 仅保留为旧版本兼容字段，不再作为新身份、授权或统计主键。

## 消息列表（客户端→服务端）
| type | payload | 说明 |
|---|---|---|
| `register` | `{account_name, password}` | 注册账号；成功后自动建立 session，等同于登录 |
| `login` | `{account_name, password}` | 账号登录，返回新 session |
| `logout` | `{}` | 退出登录，当前 session 立即失效（revoked） |
| `session` | `{session}` | 用已有 session 恢复认证（刷新/断线后），不再发密码 |
| `change_password` | `{old_password, new_password}` | 已认证账号修改密码；成功后该账号全部 session 失效，需重新登录 |
| `create_room` | `{player_name}` | 已认证账号创建房间，创建者为房主 |
| `join_room` | `{room_id, player_name}` | 已认证账号加入房间，最多4人 |
| `ready` | `{ready: true|false}` | 准备/取消准备 |
| `start_game` | `{}` | 仅房主，全员已准备且人数2-4 |
| `submit_card` | `{card_uid, mode, target?}` | mode: `action`/`cargo`/`tide`；mode=action 时 target 见下 |
| `leave_game` | `{}` | 对战中主动退出对局，退出者强制末名判负；座位由 AI 托管打完，本人立即返回大厅 |
| `reconnect` | `{room_id, player_id, token}` | 已认证账号断线重连原房间席位 |
| `list_rooms` | `{}` | 已认证账号查询在线房间列表 |
| `add_bot` | `{difficulty?}` | 添加人机；仅房主、仅 lobby、房间未满4人；difficulty: `easy`(默认)/`hard` |
| `get_my_stats` | `{}` | 查询本人战绩，需已认证账号，按 `role_id` 归属 |
| `get_leaderboard` | `{board, offset?, limit?}` | 排行榜；board: `ladder`(天梯分)/`wins`(胜场)；limit 默认 10 最大 100 |
| `remove_bot` | `{player_id}` | 移除人机；仅房主、仅 lobby；目标须 `is_bot=true` |
| `ping` | `{}` | 心跳 |
| `start_tutorial` | `{}` | 已废弃；教程完全由客户端运行 |
| `tutorial_action` | `{stage, card_uid, mode, target?}` | 已废弃；教程完全由客户端运行 |
| `tutorial_exit` | `{}` | 已废弃；教程完全由客户端运行 |
| `tutorial_status` | `{}` | 已废弃；教程完全由客户端运行 |
| `tutorial_reconnect` | `{session_id}` | 已废弃；游客教程不提供服务端恢复 |
| `tutorial_replay` | `{}` | 已废弃；教程完全由客户端运行 |
| `start_practice` | `{}` | 已废弃；当前版本不提供服务端新手陪练 |

- 同一连接已在房间内时再发 `create_room`/`join_room`/`reconnect` → 返回 `error code=already_in_room`，原房间不变。

账号与会话规则：
- 账号名 3-64 字符，仅允许字母、数字、`_`、`-`；密码 8-256 字节。校验失败返回对应错误码。
- 密码错误与账号不存在统一返回 `invalid_credentials`，防止账号枚举。
- 已认证连接再发 `register`/`login` → `already_authenticated`（含在房间内的情形）；未认证发 `logout` → `not_authenticated`。
- 房间内禁止 `logout`，需先离开房间，否则返回 `already_in_room`。
- session 有效期 30 天；`logout` 后该 session 立即失效，旧 session 再发 `session` 返回 `authenticated=false`。
- 同一账号可在多连接同时登录，不互踢；`logout` 只撤销发起连接所用的 session。
- `change_password` 需已认证且不在房间内（房间内返回 `already_in_room`）；旧密码错误返回 `wrong_old_password`（不暴露账号是否存在之外的更多信息）；新密码校验规则与注册一致（8-256 字节，复用 `password_too_short`/`password_too_long`）；新密码与旧密码相同返回 `same_password`；每账号限流 3 次/分钟，超限返回 `rate_limited`；成功后服务端撤销该账号全部 session（含当前连接所用），回复 `password_changed` 后连接回到游客态，客户端应回登录界面。
- 账号类错误码：`account_exists` / `invalid_credentials` / `invalid_credentials_format` / `name_too_short` / `name_too_long` / `name_invalid_chars` / `password_too_short` / `password_too_long` / `already_authenticated` / `not_authenticated` / `authentication_required` / `wrong_old_password` / `same_password` / `rate_limited` / `account_error`。

`submit_card.target`（mode=action 时按卡牌行动类型决定）：
- sail: `{to_port}`
- trade: `{kind:"buy"|"sell", good, count}`（buy 最多2，sell 固定1）
- deliver: `{contract_id}`
- post: `{port}`
- tidecraft: `{op:"peek"|"shift", delta?}`（shift 时 delta 为 1 或 -1）
- tailwind: `{to_port, kind:"buy"|"sell", good, count}`（航行后追加一次交易）

## 消息列表（服务端→客户端）
| type | payload | 说明 |
|---|---|---|
| `account_registered` | `{account_id, account_name, session, role_id}` | 注册成功，已自动登录 |
| `logged_in` | `{session, account_id, account_name, role_id}` | 登录成功 |
| `logged_out` | `{}` | 登出成功，连接回到游客态 |
| `password_changed` | `{}` | 修改密码成功；全部 session 已失效，连接回到游客态 |
| `session` | `{authenticated, account_id?, account_name?, role_id?}` | session 恢复结果；`authenticated=false` 时无其余字段 |
| `room_created` | `{room_id, player_id, token}` | token 用于重连，服务端签名 |
| `room_joined` | `{room_id, player_id, token}` | 同上 |
| `room_update` | `{players:[PlayerBrief]}` | 大厅人员/准备状态变化 |
| `room_list` | `{rooms:[RoomBrief]}` | `list_rooms` 的回应 |
| `game_started` | `{public_state, private_state, room_mode?, stats_eligible?}` | 开局 |
| `phase_changed` | `{phase, deadline_ts}` | phase: `select`/`resolve`/`game_over` |
| `ack` | `{action_id}` | 行动已受理 |
| `action_rejected` | `{action_id, reason}` | reason 为字符串（禁止动态原子） |
| `reveal_cards` | `{plays:[{player_id, card_id, mode}]}` | 同时亮牌 |
| `state_sync` | `{seq, public_state, private_state}` | 每次结算后推送（private 仅本人可见部分） |
| `action_log` | `{entries:[string]}` | 公开日志 |
| `player_left` | `{player_id, name, reason}` | 有玩家退出对局；reason: `quit`(主动退出)/`disconnect`(断线超宽限托管)；该座位 `connected=false`、`auto_pilot=true` |
| `game_over` | `{scores:[{player_id, total, rank, ladder_delta, breakdown, rage_quit}], room_mode?, stats_eligible?}` | 终局；陪练 stats_eligible=false 且不写正式统计；`rage_quit=true` 表示该玩家强制末名（主动退出或开局 30s 内断线未归） |
| `returned_to_lobby` | `{room_id}` | 房间结束，账号角色解除房间绑定并回到大厅 |
| `my_stats` | `{stats}` | stats: `{games, wins, top2, avg_total, ladder, ladder_max, win_streak, games_7d, wins_7d, recent:[{ts, room_size, has_bot, rank, total, ladder_delta, ladder_after}]}`；`win_streak`=当前连胜（rank=1 含并列 +1，否则清零，v0.4 起）；`games_7d`/`wins_7d` 为滚动 7 天窗口（ts ≥ now−604800s，含等号边界）内的对局数/胜场数；三者与 games/wins 同口径（排除 stats_eligible=false 局）。时序保证：room 先落盘统计再广播 `game_over`，客户端收到 `game_over` 后调 `get_my_stats` 必得含本局结果的数据 |
| `leaderboard` | `{board, entries, self_rank}` | entries: `[{rank, name, ladder, games, wins, win_rate}]`；入榜门槛 games≥5 |
| `error` | `{code, message}` | code 为字符串 |
| `pong` | `{}` | 心跳回应 |
| `tutorial_state` | `{session_id, snapshot_version, stage, stage_status, public_state, private_state, completed}` | 教程权威快照；仅教程连接可见；snapshot_version 单调递增 |
| `tutorial_ack` | `{action_id, stage}` | 教程行动已受理 |
| `tutorial_rejected` | `{action_id, reason}` | 教程行动被拒绝，reason 为字符串 |
| `tutorial_completed` | `{}` | T1-T9 全部完成；不产生正式战绩 |
| `tutorial_exited` | `{}` | 教程会话已退出 |
| `tutorial_status` | `{completed, stage, session_id?, snapshot_version?}` | 当前身份的教程状态 |
| `tutorial_reconnected` | `{session_id}` | 教程会话恢复成功，随后发送 `tutorial_state` |
| `tutorial_replay_started` | `{session_id}` | 新教程会话已从 T1 开始，既有完成事实保留 |
| `practice_started` | `{room_id, room_mode, stats_eligible}` | 已废弃；当前版本不提供服务端新手陪练 |

`PlayerBrief`: `{id, name, ready, host, connected, is_bot, difficulty, auto_pilot}`
- `difficulty`：仅 bot 有效，`easy`/`hard`；真人字段为 null。
- `auto_pilot`：真人断线超宽限期被 AI 托管时为 true，重连夺回后恢复 false。

人机（bot）规则：
- 人机 `id` 形如 `bot_N`，无 token，`reconnect` 一律拒绝；人机加入即视为恒 `ready=true`，永不为房主。
- `start_game` 人数 2-4 含人机；人机与真人同一套服务端校验。
- `add_bot`/`remove_bot` 错误码：`not_host` / `not_in_lobby` / `room_full` / `not_a_bot` / `player_not_found` / `invalid_difficulty`；战绩相关错误码：`authentication_required` / `invalid_board` / `invalid_limit`。
- `public_state.players[]` 同样含 `is_bot`/`difficulty`/`auto_pilot` 字段。

## 战绩与天梯（简化积分制）
- 仅已认证账号真人参与计分；正式统计以 `role_id` 为唯一归属键，初始分 1000，下限 0。
- 名次得分：4人局 +30/+10/0/-20；3人局 +25/+5/-15；2人局 +20/-10；并列均分，向下取整；天梯分 <1100 时正分 ×1.2。
- 普通含人机对局照常计分，记录标记 `has_bot`；Bot 本身不产生角色和统计。
- 主动退出（`leave_game`）任意时刻均强制末名计（`rage_quit=true`）；断线且开局 30s 内 grace 未归同样按末名计；30s 之后掉线由 AI 托管打完，按实际名次正常计分。多名 `rage_quit` 玩家并列末名，按并列规则均分末名档负分。
- 同一 `role_id` 在同一房间并行连接只计一次。

`RoomBrief`: `{room_id, player_count, max_players, phase, host_name}`，其中 `phase` 为服务端原始阶段：`lobby`（等待中，可加入）/ `select`、`resolve`（游戏中）/ `game_over`（已结束）。仅 `lobby` 且未满的房间可加入。

房间模式：
 - `room_mode` 当前仅为 `normal`；`tutorial_practice` 服务端陪练已废弃。
 - `stats_eligible` 表示是否写入正式战绩；普通房默认为 `true`。
 - 只有已认证账号可以创建、加入或重连普通房；游客统一返回 `authentication_required`。
 - 普通手动创建的含 Bot 房保持 `room_mode=normal`、`stats_eligible=true`；Bot 为房间临时数据，房间关闭后释放。

## 状态结构
```jsonc
// public_state（全员可见）
{
  "round": 1, "turn": 1, "phase": "select",
  "tide": "rising",                     // low | rising | full | ebb
  "market": {"salt": 3, "lamp": 3, "silk": 4},
  "ports": [                            // 顺序固定，见 data/ports.json
    {"id": "east", "ships": ["p1"], "posts": [{"player_id": "p2"}]}
  ],
  "public_contracts": [Contract],
  "players": [
    {"id": "p1", "name": "A", "coins": 3, "vp": 0,
     "cargo_count": 2, "submitted": false, "connected": true}
  ]
}

// private_state（仅本人）
{
  "hand": [Card],                       // 含 uid 的完整手牌
  "cargo": ["salt", "silk"],            // 已留存货物明细
  "hidden_contracts": [Contract]
}
```

## 牌局流程（服务端权威）
1. `create_room`/`join_room` → `room_update` 广播。
2. 全员 ready 后房主 `start_game` → 服务端洗牌发牌（手牌5、金币3、每人1张隐藏订单、公开3张订单）→ `game_started` + `phase_changed(select)`。
3. select 阶段：玩家 `submit_card`。所有人提交或超时（45s）→ `reveal_cards` → `phase_changed(resolve)` → 按座位顺时针结算 → `state_sync` → 进入下一 turn（`phase_changed(select)`）。
4. 超时未提交：服务端自动执行 `弃置该玩家手牌第1张，mode=tide`。
5. 4 轮 × 3 回合结束后 → `game_over`。

## 新手教程与游客身份
- 新手教程是纯客户端界面介绍和模拟场景，不创建服务端教程会话、玩家进程或房间，也不发送教程行动协议。
- 游客没有 `role_id`、账号 session 或服务端长期数据；刷新、断线、重连后教程状态消失，需要重新开始。
- 教程结束后客户端只能进入账号注册或退出流程；取消注册不得进入真实大厅。
- 注册成功后服务端创建账号的 `role_id` 和 PlayerProcess，并自动建立账号 session；只有此后才允许进入大厅和真实对局。
- 客户端教程完成状态不是安全凭证；服务端真实对战资格只以有效账号 session 为准。
- 旧教程消息收到时，服务端返回 `tutorial_client_only`，不创建服务端教程状态。

<!-- 以下为旧版服务端教程说明，仅保留作历史记录，不属于当前协议。 -->
## 固定任务教程（历史废弃）
- `start_tutorial` 创建或恢复独立教程会话；教程会话不进入 `list_rooms`，不产生普通房间成员、正式 `action_log`、`game_over` 或战绩统计。
- 教程只有当前连接对应的一名真人，使用策划文档 `docs/10_new_player_tutorial_v1.0.md` 定义的 T1-T9 固定快照；不等待其他玩家，不使用随机正式牌库。
- `tutorial_action` 必须携带通用 `action_id`，服务端按当前 `stage`、固定手牌、模式、目标、费用、位置、订单和共享卡牌/订单数据校验。重复 action_id 只返回 `tutorial_ack`，不得重复结算。
- 成功行动后服务端发送最新 `tutorial_state`；阶段完成后装载下一固定快照。T9 完成后发送 `tutorial_completed`，并保持完成状态不产生正式统计。
- `tutorial_state.private_state` 仅包含当前玩家手牌、货物和隐藏订单；不得通过普通房间广播或 `list_rooms` 暴露。
- `tutorial_exit` 释放当前教程会话并发送 `tutorial_exited`；退出、跳过和重玩不等同于完成。教程重玩重新从 T1 固定快照开始。
- 教程协议为 M2 的最小状态接口；登录账号完成状态服务端持久化、游客本地保存及账号/游客迁移规则在 M3 实现。
- M3 状态恢复：登录账号以服务端账号 ID保存教程完成事实；游客不得以服务端身份保存完成事实。`tutorial_status` 只返回当前身份状态。
- M3 会话恢复：服务端在短期恢复窗口内保留教程会话快照和 session_id；`tutorial_reconnect` 只能恢复同一身份的会话。恢复后发送当前权威 `tutorial_state`，不得回退或重复结算。
- `tutorial_state.snapshot_version` 为会话内单调递增的权威快照版本；重连返回的版本不得小于断线前已确认版本。新建或重玩会话从版本 1 开始。
- M3 重玩：`tutorial_replay` 结束旧会话并创建 T1 新会话，既有 `completed=true` 完成事实保持；新会话行动仍按 T1-T9 权威规则处理。
- 刷新或断线未完成的教程不得自动标记完成；服务端无法恢复会话时返回字符串错误，客户端可明确选择重新开始。

## 规则细则（仲裁版，优先级高于其他文档）
- **初始潮位**：`config.start_tide`（rising）。潮汐循环顺序：`config.tide_order` = low → rising → full → ebb 循环。
- **潮汐推进**：本回合所有 `mode=tide` 弃牌的潮纹值之和，按 tide_order 前进对应格数；和为 0 则不推进。wild 货物卡潮纹为 0。
- **事件**：潮汐每次进入新档位时，翻该档位事件堆顶 1 张执行（各档位事件堆独立循环）。事件见 `events.json`。
- **补牌**：每回合结算完成后，每位玩家从牌库抽 `draw_per_turn`（=1）张；牌库抽空则不再补（48 张牌数学上不会抽空）。
- **费用**：
  - sail：基础 `sail_base_cost`=1 金币；低潮/退潮 +1，满潮 -1；最低 `sail_cost_min`=0。
  - post：固定 `post_cost`=2 金币，每港口最多 3 个商站。
  - trade.buy：单价=该货当前市价，最多 2 件；低潮买货总价 -1（最低 0）。wild 不可购买，只能由手牌留作货物。
  - trade.sell：固定卖 1 件，得该货当前市价；满潮 +1（临时修正，可突破 market_max）；随后该货市价 -1（从原价压，下限 market_min）。wild 卖货时须声明货物种类 `good`，按该货价格结算。
- **货物压价**：完成订单后，订单涉及的每种货物市价 -1（下限 market_min）。
- **手牌去向**：`mode=action` 执行行动后进入弃牌堆；`mode=cargo` 不执行行动，卡牌 cargo 直接放入货物区（wild 入局时须声明为哪种货物，target.good 必填）；`mode=tide` 进入弃牌堆并计潮纹。
- **商站计分**：每港口按商站数量排名，依次得 `post_scores`=[4,2,1]；数量并列时并列名次平分该名次分数，向下取整。
- **交货**：须在船只所在港口完成；订单 port=`any` 不限港口；涨潮交货 +1VP；退潮完成隐藏订单 +1VP；奖励金币立即到账。
- **座位顺序**：按加入房间顺序，结算从每回合起始玩家顺时针；每回合起始玩家轮转为下一位。

## 主动退出对局（leave_game）
- 仅 `select`/`resolve` 阶段可发 `leave_game`；`lobby` 阶段返回 `not_in_game`，`game_over` 阶段返回 `already_game_over`，不重复结算。
- 退出立即生效：该座位 `connected=false`、`auto_pilot=true`、`rage_quit=true`（强制末名），由 AI 托管打完本局，对局不中断。
- 退出者立即收到 `ack` 与 `returned_to_lobby`，其角色房间绑定即刻释放（可立即 `create_room`/`join_room` 新房间）；之后对原房间 `reconnect` 一律拒绝。
- 其余玩家收到 `player_left`（reason=`quit`）及后续 `room_update`/`state_sync`，正常打完本局；终局 `game_over` 中退出者 rank 为末名、`ladder_delta` 取末名档。
- 刷新/关闭页面不视为退出，走断线流程；只有显式发送 `leave_game` 才判负退出。
- 只剩 1 名真人时（其余均为 bot 或 rage_quit 托管），对局立即终局并按当前比分结算。

## 断线
- 断线 60s 内可 `reconnect` 恢复；`room_update` 中 `connected` 反映在线状态。重连成功后服务端按当前阶段推送恢复快照：lobby 阶段为 `room_update`，游戏阶段为 `game_started`（含完整 public/private state）+ `phase_changed`，此后正常接收 `state_sync`。
- 断线玩家轮到提交时走超时自动逻辑，不阻塞他人；断线超过 60s（grace 到期）保留座位并由简单人机**托管接管**（`auto_pilot=true`，1-2s 延迟行动，非简单弃牌），`reconnect` 成功后立即夺回控制权（`auto_pilot=false`）；座位与数据随本局结束一并回收。
- **房主转移**：lobby 阶段房主离开/断线，房主按座位顺序转移给下一位在线真人（人机不继承房主）；房间只剩人机时房间解散。
- 游戏阶段房主断线不转移，按上述断线规则处理；重连后仍为房主。

## 管理 HTTP 端点（非 WS，运维用）
| 端点 | 响应 | 说明 |
|---|---|---|
| `GET /healthz` | `{ok, service, version}` | 健康检查（公开，供反代/监控） |
| `GET /admin/status` | `{ok, version, uptime_sec, rooms_online, players_online, connections_online, memory_mb}` | players_online=房间内 connected 玩家数（含人机）；connections_online=活跃连接总数（含未进房） |
| `GET /admin/players` | `{ok, players:[{name, room_id, phase, is_bot, connected, auto_pilot}]}` | 全服在线玩家摘要 |

- 鉴权：仅 `127.0.0.1`/`::1` 来源放行；`config.json` 配置 `admin_token` 后，非 localhost 来源携 `X-Admin-Token` 头匹配可放行，否则 403。
- nginx/Caddy 反代**不得暴露** `/admin/*`（现有配置只反代 `/ws` 与 `/healthz`，天然满足）。
- 管理脚本：`deploy/tidesctl.bat|sh start|stop|status|players`（status/players 即调用上述端点）。

## 安全约束
- 牌库顺序、他人手牌、他人隐藏订单只存在服务端 room 进程。
- 服务端校验一切：阶段、费用、位置、目标、订单条件。
- `reason`/`code` 一律字符串，禁止 `list_to_atom`/`binary_to_atom` 处理外部输入。
