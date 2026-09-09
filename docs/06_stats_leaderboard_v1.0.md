# 《潮汐商会》战绩与排行榜策划案 v1.0

> **身份规则状态：已由 `08_account_system_and_dev_reset_v1.0.md` 取代。** 本文的 `player_token` 仅保留为旧历史与兼容说明；不得据此实现新账号、登录、跨设备或数据迁移逻辑。

> 版本：v1.0 ｜ 状态：统计口径已冻结，旧身份/旧 Bot 计分方案废止 ｜ 对应：shared/protocol.md v0.2、01_rulebook_v1.0.md、02_bot_design_v1.0.md
> 本文只写设计意图与协议提案；`shared/` 由主协调统一修改。本文件名 03 系用户指定，与既有 03_balance.md 并存，后续由主协调统一重编号。

---

## 1. 功能定位

### 1.1 冻结统计口径

- 正式统计档案按 `role_id` 归属；`#role` 是注册账号长期数据身份。`player_token` 不得创建、归属或恢复正式统计档案。
- 只有普通注册账号参加正式规则局，且对局正常结束，才写入正式统计。
- 普通账号 + Bot 的正式规则局按既定规则正常统计，不减半；Bot 仅是房间临时席位，不产生自身统计。
- 游客、Bot、教程和 `practice` 局均不写入 `games`、`wins`、`ladder`、排行榜或正式 `recent`。

- **轻量留存向**：让玩家「打完想再来一局上分」，给 2-4 人小局一个长期目标。不做赛季、不做奖励发放、不做社交关系链（本期）。
- 数据来源：终局 `game_over.scores`（`{player_id, total, breakdown}`，见 tides_game.erl compute_scores）。按 `total` 降序得名次；并列 total 时**并列同一名次**（与局内商站计分哲学一致，避免服务端引入 tie-break 随机性争议）。
- **非目标（本期不做）**：账号注册/登录、跨设备同步、赛季重置与奖励、好友榜、强反作弊、人机自身档案。

---

## 2. 天梯计分规则

### 2.1 方案选型：简化积分制（非 ELO）

采用**名次固定得分 + 当前分线性调整**的简化天梯，不用 ELO。理由：

1. 本游戏是 2-4 人混战，ELO 多人泛化（如 TrueSkill）实现与调参成本高，与「轻量留存」定位不符。
2. 玩家池小、匹配无段位概念，ELO 的「预期胜率」前提不成立。
3. 简化积分规则一行文案可向玩家解释清楚（「第1名+30，第2名+10…」），透明感强。

### 2.2 计分表

基础分（按名次，并列名次取并列者均分、向下取整）：

| 名次 | 2人局 | 3人局 | 4人局 |
|---|---|---|---|
| 1st | +20 | +25 | +30 |
| 2nd | -10 | +5 | +10 |
| 3rd | — | -15 | 0 |
| 4th | — | — | -20 |

- **设计意图**：4人局为基准（±30/+10/0/-20，期望微正，鼓励多打）；2人局收敛到 ±20/-10 防止刷分（二人局方差小、易控分）；零和近似为负（总和略亏），抑制通货膨胀，让 top100 有区分度。
- **新手保护**：天梯分下限 0，扣分不会扣到 0 以下。初始分 **1000**。
- **低保分段加成**（可选，本期实现）：当前分 < 1100 时，正得分 ×1.2（向下取整），帮助新手快速离开鱼塘；负得分不变。

### 2.3 人机对局计分策略

普通账号参与的正式规则 Bot 局按第 2.2 节计分表正常结算，并在最近记录标记 `has_bot=true`；不减半。

旧方案曾提出“含 Bot 局减半”，现已废止；不得实现 `bot_game_weight=0.5` 或以 Bot 参与为由改变正式计分。

---

## 3. 身份归属（`role_id`）

### 3.1 推荐方案

- 服务端维护 `role_id → 战绩档案` 映射；昵称为**纯显示名**，可每局随便改，不影响战绩归属。
- 登录创建 `PlayerProcess`，由其携带当前账号的 `role_id` 参与房间；进程/连接重建不改变归属。游客和 Bot 不具备 `role_id`。
- 与现有重连 `token`（房间级、服务端签名、一次性对局用）相互独立；重连 token 仅用于恢复房间席位，不得作为长期统计身份。

### 3.2 防刷边界（明确声明）

本期**不做强反作弊**，已知风险：

| 风险 | 说明 | 本期对策 |
|---|---|---|
| 清 localStorage 换身份 | 任何人可无限生成新 token | 接受；排行榜展示昵称，刷号成本=清零自己战绩 |
| token 被复制盗用 | 拿到别人 token 即可顶替其战绩 | 接受（轻量场景）；文档注明「token 即身份，勿分享」 |
| 自开房间多开刷分 | 同人机房 3 个小号保送大号 | 见 §7 反刷分基础措施 |
| 秒退控分 | 劣势局秒退避免扣分 | 见 §7 |

---

## 4. 战绩数据字段

每个 `role_id` 一份档案：

```jsonc
{
  "role_id": "role_123",
  "name": "最近使用的昵称",           // 展示用，可改
  "games": 42,                        // 正式统计场次（可含普通账号+Bot正式规则局，不含practice）
  "wins": 11,                         // 第1名次数（并列第1各计1胜）
  "top2": 25,                         // 前二次数（2人局即第1名）
  "total_score_sum": 1234,            // 各局 game_over.total 之和，用于算均值
  "avg_total": 29.4,                  // 总VP均值 = total_score_sum / games，保留1位小数
  "ladder": 1180,                     // 当前天梯分
  "ladder_max": 1240,                 // 历史最高天梯分
  "recent": [                         // 最近10场，新→旧
    {
      "ts": 1730000000,
      "room_size": 4,                 // 开局人数（含人机）
      "has_bot": true,
      "rank": 1,                      // 本人名次（并列则同值）
      "total": 38,                    // 本局总分
      "ladder_delta": +15,            // 本场天梯变化（已含人机权重）
      "ladder_after": 1180
    }
  ]
}
```

- **计入条件**：存在普通账号 `role_id`、房间模式不是 `tutorial`/`practice`、对局正常打满到 `game_over` 才结算；中途房间解散/异常终止不计。
- **派生展示**：前二率 = top2/games；胜率 = wins/games。

---

## 5. 排行榜与客户端展示设计

### 5.1 榜单

- **天梯榜 top100**：按 `ladder` 降序；同分按 `ladder_max` 再按 `games` 少者优先（少场次高分含金量高）。入榜门槛：`games ≥ 5`（防一局运气上榜）。
- **胜场榜 top100**：按 `wins` 降序，同胜场按胜率。入榜门槛：`games ≥ 5`。
- 榜单每 60s 服务端缓存刷新一次即可，无需实时。

### 5.2 客户端展示（供前端参考）

1. **大厅入口**：房间列表页顶部加两个按钮：「我的战绩」「排行榜」。
2. **个人战绩面板**：昵称（可点击改名）、天梯分（当前/最高）、总场次/胜率/前二率/场均VP、最近10场列表（名次徽标、分数、天梯±、含人机标记「人机局」）。
3. **排行榜页**：两个 Tab（天梯榜/胜场榜），每行：名次、昵称、天梯分（或胜场）、场次；高亮本人行；未上榜时显示「还需 N 场方可上榜」。
4. **终局结算页**：在现有 `game_over` 基础上，每名真人玩家昵称旁显示本场 `ladder_delta`（如 `+30 ▲`），见 §6.3。

---

## 6. 协议变更提案（供主协调修改 shared/protocol.md）

> 均为草案，snake_case，`code`/`reason` 一律字符串。

### 6.1 通用身份字段（旧提案废止）

正式规则消息必须由登录创建的 `PlayerProcess` 关联 `role_id`；服务端按 `role_id` 归集战绩。游客没有服务端消息链路，不能以“无 token 可正常游戏”的方式进入正式房间。

```json
{"type":"join_room","room_id":"A7Q2","player_id":null,"role_id":"role_123","action_id":"uuid","seq":3,"ts":1730000000,"payload":{"player_name":"阿潮"}}
```

### 6.2 新增客户端→服务端消息

| type | payload | 说明 |
|---|---|---|
| `get_my_stats` | `{}` | 查询本人战绩档案；需由登录 `PlayerProcess` 关联 `role_id` |
| `get_leaderboard` | `{board: "ladder"|"wins", offset?: 0, limit?: 100}` | 查询排行榜；limit 上限 100 |

### 6.3 新增服务端→客户端消息

| type | payload | 说明 |
|---|---|---|
| `my_stats` | `{stats: PlayerStats}` | `get_my_stats` 回应；档案不存在时 `stats=null` |
| `leaderboard` | `{board, entries:[{rank, name, ladder, games, wins, win_rate}], self_rank: null|number}` | `get_leaderboard` 回应；`self_rank` 为本人名次（未上榜为 null） |

```json
{"type":"my_stats","payload":{"stats":{"games":42,"wins":11,"top2":25,"avg_total":29.4,"ladder":1180,"ladder_max":1240,"recent":[{"ts":1730000000,"room_size":4,"has_bot":true,"rank":1,"total":38,"ladder_delta":15,"ladder_after":1180}]}}}
```

### 6.4 `game_over` 扩展

scores 条目增加 `rank` 与 `ladder_delta`（人机与无 token 玩家为 null）：

```json
{"type":"game_over","payload":{"scores":[
  {"player_id":"p1","total":38,"rank":1,"ladder_delta":30,"breakdown":{"orders":20,"posts":8,"cargo":5,"coins":4}},
  {"player_id":"bot_1","total":31,"rank":2,"ladder_delta":null,"breakdown":{"orders":18,"posts":6,"cargo":4,"coins":3}}
]}}
```

`ladder_delta` 为按既定计分表及账号资格计算的最终值；Bot、教程、practice 和游客均为 null，且不写入正式统计。

### 6.5 错误码

`stats_token_required`（get_my_stats 无 token）、`invalid_board`、`invalid_limit`。

---

## 7. 反刷分基础措施

| 措施 | 规则 |
|---|---|
| 同账号房间占用限制 | 同一账号的 `role_id` 同时只能在一个房间；服务端按账号占用查重并返回 `already_in_room`。**不做** IP/设备级限制 |
| 秒退处理 | **断线场景**：开局 **30 秒内**（select 阶段第1回合结束前）真人掉线且 grace 到期未归：该局若继续打完，该玩家**按第末名计负**（扣对应名次分）；其名次由剩余玩家正常排。开局30秒前掉线且房间因此不足2真人而散局 → 不计分。**主动退出场景已由 `13_leave_game_rage_quit_v1.0.md` 取代**：对战中任意时刻主动退出（leave_game）均强制末名，不再受 30s 窗口限制；30s 窗口仅保留给断线场景 |
| 中途弃局 | 30 秒后掉线未归者：走现有超时自动行动打完全程，按实际总分正常排名计分（托管人机 v2 上线后改由托管代打，同样正常计分） |
| 人机权重 | 废止减半方案；普通账号 + Bot 正式规则局按既定计分表正常统计 |
| 参数入 config | `ladder_table`、`rage_quit_window_ms=30000`、入榜门槛 `min_games_for_board=5` 均入服务端 config，可调；`bot_game_weight` 废止 |

---

## 附：验收清单（供测试PM）

1. 注册账号以 `role_id` 打完一局 4 人纯真人局 → `get_my_stats` 返回 games=1、ladder=1000+对应名次分；`game_over.scores[]` 含 `rank` 与正确 `ladder_delta`。
2. 普通账号 + Bot 正式规则局：真人按既定表值正常计分；recent 记录 `has_bot=true`，不减半。
3. 2/3/4 人局分别验证计分表数值；并列 total 验证并列名次与均分。
4. 天梯下限 0 不为负；<1100 分段正得分 ×1.2。
5. 排行榜：games<5 不上榜；top100 排序正确；`self_rank` 正确；无 `role_id` 不得创建正式统计档案。
6. 同一 token 在两个连接同时 join 不同房间 → 第二个被拒绝。
7. 开局 30s 内断线秒退：该玩家按末名扣分；其余正常结算。主动退出（任意时刻判末名）的验收见 `13_leave_game_rage_quit_v1.0.md` §5。
8. 改昵称后战绩归属不变（同 token 不同 name，档案 name 更新为最近值）。
9. 游客无 `role_id`、无服务端会话，只能纯客户端教程；刷新/断线后重开教程，不能打正式局。
10. 教程、游客、Bot、`practice` 均不改变正式统计；房间结束后账号回大厅。

## 8. 废止旧规则

- 废止本文原有的 `player_token → 战绩档案`、无 token 游客可进服务端游戏、含 Bot 局 `ladder_delta` 减半及“陪练是否计分待裁决”规则。
- 废止其他文档中与本节冻结口径冲突的描述；实现和测试以本节及 `08_account_system_and_dev_reset_v1.0.md` 为准。
