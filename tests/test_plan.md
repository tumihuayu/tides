# 《潮汐商会》测试计划 v0.1

依据：`shared/protocol.md`（唯一协议事实来源）、`shared/data/*.json`（数值事实来源）。
测试对象：服务端（Erlang/OTP，端口 9500，路径 `/ws`）。工具：`tests/robot.mjs` + 手工脚本客户端。
所有用例消息均须携带 `action_id`（uuid）与合法信封字段。

## 1. 身份模型与范围

### 1.1 当前验收身份模型（新口径）

- **游客**没有 `role_id`、`PlayerProcess` 或服务端玩家身份，只能进行纯客户端教程；禁止 `create_room`、`join_room`、`reconnect`、`start_practice` 及任何真实对战。
- **教程结束**游客只能选择注册或退出；注册成功后才创建账号身份，账号数据归属以账号会话/账号 ID 为准。
- **旧 `player_token`**不是账号事实、role 或教程完成状态来源；相关统计仅作 `LEGACY` 兼容检查。
- **游客统计**必须为零，不产生 games/wins/ladder/recent 或其他账号统计。
- **Bot**仅是房间临时数据；房间关闭即释放 Bot、房间、定时器和相关临时状态。

### 1.2 测试身份注入

`robot.mjs` 是正式账号对战脚本；没有账号 fixture 时直接 `BLOCKED`。使用 `--player-token=<token>`（单身份冒烟）或 `TEST_PLAYER_TOKENS=a,b,c,d`（按玩家顺序注入）；脚本不会把服务端返回的房间 token 当作账号身份。游客禁止使用该脚本。

## 2. 范围与优先级

| 模块 | 说明 | 优先级 |
|---|---|---|
| A 协议一致性 | 信封、消息类型、seq 单调递增、状态结构 | P0 |
| B 规则正确性 | 建房/开局、六种行动、结算、终局计分 | P0 |
| C 非法行动拒绝 | 手牌/金钱/港口/订单/阶段校验 | P0 |
| D 断线重连 | 60s 内恢复、不阻塞他人 | P1 |
| E 超时自动行动 | 45s 未提交自动弃第 1 张（mode=tide） | P1 |
| F 并发房间 | 多房间隔离、10 并发 | P1 |
| G 性能基线 | 消息延迟、状态同步大小 | P2 |
| H 安全/隐藏信息 | state_sync 不泄漏他人手牌/隐藏订单 | P0 |
| I 局域网/外网接入 | healthz/反代隧道/防火墙/wss 整局 | P1 |

## 3. 用例表

### A. 协议一致性（PC）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| PC-01 | 服务端已启动 | ws 连接 `ws://127.0.0.1:9500/ws`，发送 `ping` | 收到 `pong` |
| PC-02 | 已连接 | 发送 `create_room {player_name}` | 收到 `room_created`，含 `room_id/player_id/token`；token 非空 |
| PC-03 | 房间内有变动 | 观察任意广播 | 每条 `state_sync` 的 `seq` 严格单调递增，无回退/跳号回退 |
| PC-04 | 已连接 | 发送缺少 `action_id` 的 `submit_card` | 收到 `error`（code 为字符串），连接不断开 |
| PC-05 | 已连接 | 发送未知 `type` 消息 | 收到 `error`，code/message 均为字符串，服务端不崩溃 |
| PC-06 | 游戏进行中 | 收到 `state_sync` | `public_state` 含 round/turn/phase/tide/market/ports/public_contracts/players 全部字段；`private_state` 含 hand/cargo/hidden_contracts |
| PC-07 | 任意 | 收到 `action_rejected` / `error` | `reason`/`code` 为字符串类型（非 atom 序列化产物），JSON 可解析 |
| PC-08 | 已连接 | 先 `create_room` 建房，再发送 `list_rooms {}` | 收到 `room_list`，`rooms` 含该房间：`room_id/phase=lobby/player_count≥1/max_players=4/host_name` 字段齐全；对局开始后该房间 phase 非 lobby；房间回收后从列表消失 |
| PC-09 | 服务端已启动 | node 原生 fetch：`GET /healthz`；`GET /`；非 Upgrade 的 `GET /ws` | `/healthz` 返回 200 且 JSON `ok===true`、`service==="tides"`；`/` 返回 404；非 Upgrade `/ws` 返回 400 |
| PC-10 | 服务端已启动；`node tests/proxy_sim.mjs` 已监听 127.0.0.1:18080 | `node tests/robot.mjs ws://127.0.0.1:18080/ws` 跑完整 4 人局；另验证 `GET /` 与 SPA 回退路径返回 index.html | 机器人输出 `SMOKE PASS`（exit 0）；静态页 200；证明 nginx `location /ws` 反代形态可行 |

### B. 规则正确性（RC）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| RC-01 | 无房间 | p1 `create_room`；p2-p4 `join_room` | 每次变化收到 `room_update`，players 含 4 人，host=p1 |
| RC-02 | 4 人在房 | p2 `ready {ready:true}` 后 `ready {ready:false}` | `room_update` 正确反映 ready 翻转 |
| RC-03 | 非全员 ready | 房主 `start_game` | 收到 `action_rejected` 或 `error`，游戏未开始 |
| RC-04 | 非房主 | p2 `start_game` | 被拒绝，游戏未开始 |
| RC-05 | 4 人全员 ready | 房主 `start_game` | 收到 `game_started`（手牌 5 张、金币 3、隐藏订单 1、公开订单 3）+ `phase_changed(select)`；所有人初始位于 home_port=east |
| RC-06 | select 阶段，手牌有 sail 卡，船在 east | `submit_card {card_uid, mode:"action", target:{to_port:"reef"}}` | 收到 `ack`；结算后 `state_sync` 中船位于 reef（相邻港口航行成功） |
| RC-07 | select 阶段，手牌有 trade 卡，coins≥1 | `submit_card mode=action target:{kind:"buy", good:"salt", count:1}` | 结算后 coins 减少市场价，cargo 增加 salt，market.salt 价格在 [1,6] 内按规则变动 |
| RC-08 | select 阶段，手牌有 trade 卡，cargo 有 salt | `submit_card target:{kind:"sell", good:"salt", count:1}` | 结算后 cargo 减 1 salt，coins 增加 |
| RC-09 | select 阶段，手牌有 deliver 卡，cargo 满足某公开订单 | `submit_card target:{contract_id}` | 结算后该公开订单被移除/标记完成，vp/coins 按 contracts.json 奖励增加 |
| RC-10 | select 阶段，手牌有 post 卡，船在某港口 | `submit_card target:{port}` | 结算后该港口 `posts` 增加本人商站 |
| RC-11 | select 阶段，手牌有 tidecraft 卡 | `submit_card target:{op:"peek"}` | 收到 `ack`，结算正常（窥视牌库顶不公开给他人） |
| RC-12 | select 阶段，手牌有 tidecraft 卡 | `submit_card target:{op:"shift", delta:1}` | 结算后 tide 按 rising/full/ebb/low 方向正确变化一格 |
| RC-13 | select 阶段，手牌有 tailwind 卡，船在 east，coins≥1 | `submit_card target:{to_port:"reef", kind:"buy", good:"salt", count:1}` | 结算后船在 reef 且完成一次买入 |
| RC-14 | select 阶段 | `submit_card {card_uid, mode:"cargo"}` | 结算后该卡 cargo 货物进入本人 cargo（wild 可自选/按规则处理） |
| RC-15 | select 阶段 | `submit_card {card_uid, mode:"tide"}` | 结算后该卡被弃置，手牌减 1，无其他效果 |
| RC-16 | 全员已提交 | 等待结算 | 依次收到 `reveal_cards`（4 条 plays）→ `phase_changed(resolve)` → `state_sync` → `phase_changed(select)` |
| RC-17 | 完成 4 轮 × 3 回合 | 持续对局 | 收到 `game_over`，scores 恰 4 条，每条含 player_id/total/breakdown，total≥0 |
| RC-18 | game_over 后 | 校验 breakdown | 各项分数（商站 post_scores [4,2,1]、订单 vp、货物分 ≤5、金币分 =floor(coins/3) 且 ≤4）之和 == total |

### C. 非法行动拒绝（RJ）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| RJ-01 | select 阶段 | `submit_card` 的 card_uid 不在本人手牌（如 "C999"） | `action_rejected`，reason 为字符串，状态不变 |
| RJ-02 | select 阶段，coins=0 | trade buy 任意货物 | `action_rejected`（钱不够） |
| RJ-03 | select 阶段，船在 east | sail target `{to_port:"fog"}`（非相邻） | `action_rejected`（非相邻港口） |
| RJ-04 | select 阶段，公开订单已被他人交付 | deliver 该 contract_id | `action_rejected`（订单缺货/不存在） |
| RJ-05 | select 阶段，cargo 不满足订单 requires | deliver 该订单 | `action_rejected` |
| RJ-06 | resolve 阶段（已提交后） | 再次 `submit_card` | `action_rejected`（阶段错误/重复提交） |
| RJ-07 | select 阶段 | trade buy count=3（超过上限 2） | `action_rejected` |
| RJ-08 | select 阶段，cargo 无 salt | trade sell salt | `action_rejected` |
| RJ-09 | select 阶段，本港已有本人商站 | post 同一港口 | `action_rejected` |
| RJ-10 | 房间已满 4 人 | 第 5 人 `join_room` | 被拒绝（error），房内状态不变 |
| RJ-11 | 游戏进行中 | 新玩家 `join_room` 该房 | 被拒绝 |
| RJ-12 | 任意 | 重复发送同一 `action_id` 的合法 `submit_card` | 第二次直接忽略并回 `ack`，行动只结算一次（去重生效） |

### D. 断线重连（DC）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| DC-01 | 对局进行中 | p2 断开 ws | `room_update`/`public_state.players` 中 p2 `connected=false`；其他玩家流程不阻塞 |
| DC-02 | p2 断线 <60s | p2 新连接发送 `reconnect {room_id, player_id, token}` | 恢复成功，收到最新 `state_sync`（含本人 private_state），connected 恢复 true，可正常提交下一回合 |
| DC-03 | p2 断线 >60s（grace 到期，已被 AI 托管接管，`auto_pilot=true`） | p2 用原 token 再尝试 `reconnect` | **v0.3 修订**：重连**成功**并夺回控制权（`auto_pilot` 恢复 false），收到最新 `state_sync`（含本人 private_state）；座位保留，数据随本局结束回收。（旧预期"拒绝 reconnect"作废，见协议 v0.3 §断线） |
| DC-04 | p2 断线且轮到提交 | 等待 select 超时 | 服务端自动弃 p2 手牌第 1 张（mode=tide），回合正常推进 |
| DC-05 | 断线重连后 | 校验 token 错误/伪造的 reconnect | 被拒绝，不泄漏任何状态 |

### D1. 问题1回归（ISSUE1）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| ISSUE1-01 | 房间已被回收或 reconnect 凭据失效 | 新连接携带旧 `room_id/player_id/token` 发送 `reconnect`，收到 `reconnect_failed`/`room_not_found` 后立即 `create_room` | 重连失败不会把客户端卡在旧房间；收到新的 `room_created`，新 `room_id` 与旧房不同；客户端 `player_token` 身份凭据不应被清除 |
| ISSUE1-02 | 当前连接已在有效房间 | 再次发送 `create_room` | 返回 `error.payload.code=already_in_room`，原房间唯一且状态不变 |
| ISSUE1-03 | 对局中，玩家断线未超过 60s | 新连接发送原房间级 `reconnect` | 收到恢复响应及当前阶段快照，包含本人 `private_state`；玩家座位保留，其他玩家不被阻塞 |
| ISSUE1-04 | 对局中，玩家断线超过 60s | 等待托管接管，再用原凭据 `reconnect` | `auto_pilot=true` 后可重连夺回，恢复为 `auto_pilot=false`；托管不重复提交。执行 `node tests/stats_check.mjs --autopilot` |

### E. 超时自动行动（TO）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| TO-01 | select 阶段，p1 不提交 | 等待 45s（select_timeout_ms） | 收到 `reveal_cards`，p1 的 play 为手牌第 1 张、mode=tide；回合正常结算 |
| TO-02 | select 阶段，其余 3 人已提交，p4 未提交 | 等待到 deadline | 不因等待提前结算，到达 deadline 后自动弃牌并结算；`phase_changed` 的 deadline_ts 与实际结算时间偏差 <2s |
| TO-03 | 全员均不提交 | 连续 2 个回合等待超时 | 每回合全员自动弃第 1 张，手牌数递减，游戏持续推进至终局 |

### F. 并发房间（CC）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| CC-01 | 无 | 同时创建 2 个房间各 4 人并开打 | 两房 room_id 不同，state_sync/action_log 互不串扰，各自独立推进 |
| CC-02 | 房间 A 进行中 | 房间 A 的玩家尝试 join 房间 B | 按协议处理（拒绝或允许但不影响 A 房状态） |
| CC-03 | 无 | 机器人并发开 10 个房间（每房 2-4 人）同时打到终局 | 10 房全部收到 `game_over`，无房间卡死、无跨房消息 |
| CC-04 | CC-03 进行中 | 观察服务端 | 无致命崩溃，无房间进程异常退出 |

### G. 性能基线（PF）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| PF-01 | 4 人房进行中 | 测量 submit_card → ack/state_sync 往返 | 局域网内 P95 < 500ms |
| PF-02 | 4 人房进行中 | 抓包统计单条 state_sync 大小 | ≤ 16KB（4 人局） |
| PF-03 | 10 并发房 | 测量结算广播延迟 | P95 < 2s |
| PF-04 | 完整 4 人局 | 记录整局时长（全员及时提交） | ≤ 5 分钟（不含人工思考） |

### H. 隐藏信息（SC）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| SC-01 | 对局进行中 | 检查 p1 收到的所有 `state_sync`/`game_started` | 不出现 p2-p4 的 hand/hidden_contracts 明细；public_state.players 仅暴露 cargo_count 等公开字段 |
| SC-02 | 对局进行中 | 检查 `reveal_cards` | 仅含本回合已亮出的 card_id，不提前暴露他人未亮手牌 |
| SC-03 | 任意 | 在 payload 中注入超长字符串/嵌套 JSON/非法 UTF-8 | 服务端不崩溃，返回字符串 code 的 error |

### I. 局域网/外网接入（LAN）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| LAN-01 | 服务端已启动 | 主机侧：`netstat` 确认 0.0.0.0:9500 LISTENING；`Get-NetFirewallRule` 确认 9500/5173 入站允许规则存在且 Enabled；`Test-NetConnection <主机局域网IP> -Port 9500` | 三项全部成立（TcpTestSucceeded=True）；第二台设备浏览器实测为**待人工项** |
| LAN-02 | VPS 已按 `deploy/README.md` 部署 nginx + 服务端 | 外网设备 `node tests/robot.mjs wss://<域名>/ws` 跑完整 4 人局；浏览器 https 打开跑一局 | `SMOKE PASS`；浏览器整局无断连。**待人工/VPS 现场验证** |

## 3. 统计

- 用例总数：60（PC 10 / RC 18 / RJ 12 / DC 5 / TO 3 / CC 4 / PF 4 / SC 3 / LAN 2）
- P0：PC 10 + RC 18 + RJ 12 + SC 3 = 43 条；P1：DC 5 + TO 3 + CC 4 + LAN-01 = 13 条；P2：PF 4 + LAN-02（人工） 条
- 自动化候选：RC-05~18、RJ-01~06、RJ-12、TO-01、CC-03、SC-01 由 `robot.mjs` 及扩展脚本覆盖。

## 4. 通过标准

- 全部 P0 用例通过；P1 用例通过率 ≥ 90%；无 P0/P1 级崩溃或数据错误遗留。
- `robot.mjs` 输出 `SMOKE PASS` 为 RC/终局链路通过的准入条件。

## 5. v0.2 内存安全与人机

背景：修复服务端内存问题 C1-C3 / H1-H4 / M1-M4（见后端修复报告），并新增「人机」功能。
准入：eunit（tides_json_tests + tides_game_tests）全过；`tides_sim:run(20)` 返回 `{ok,20}`；`node tests/robot.mjs` SMOKE PASS。三项为 v0.2 所有用例的前置门槛。

### J. 内存回归（MEM）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| MEM-01 | 服务端已启动 | 单连接连续发送 N≥100 个未完成分片帧（FIN=0 的大帧，永不发结束帧） | 连接被服务端以 1009/1002 关闭或分片缓冲达上限后断开；`erlang:memory(binary)` 不随 N 线性增长（C1 修复验证） |
| MEM-02 | 服务端已启动 | 同一 ws 连接重复 `create_room` 50 次（每次收到 room_created 后再发） | 每次要么返回 error，要么旧房间被回收；`list_rooms` 房间数始终 ≤1，监督树下房间进程数 ≤1（C2 修复验证） |
| MEM-03 | 服务端已启动 | 同一连接 join 房间 A 后再 `join_room`/`create_room` | 服务端返回明确 error（如 `already_in_room`）或先退出旧房再加入；旧房间人数不残留幻影玩家 |
| MEM-04 | MEM-02 后 | `list_rooms` + 观察房间进程 | 无孤儿房间进程残留；`robot.mjs` 跑一局后 `list_rooms` 恢复为空 |
| MEM-05 | 服务端已启动 | 脚本并发发起 200 次 TCP 连接立即 RST/断开（不完成握手或握手中途断开） | 服务端无 accept 忙循环（CPU 不飙高、无错误日志风暴），监听器存活，之后正常连接可建房（C3 修复验证） |
| MEM-06 | 对局进行中 | 向 conn 进程注入非预期消息（如直接 `Pid ! garbage`，或房间进程异常下发非 send_json 消息） | conn 进程有 catch-all 分支，不堆积信箱、不崩溃（H1 修复验证，可配合 eunit/观测信箱长度） |
| MEM-07 | 对局进行中，p2 断线 | 等待 >60s grace 期 | **v0.3 修订**：`grace_expired` 实际行为 = p2 座位保留并由简单人机**托管接管**（`auto_pilot=true`，1-2s 延迟行动，广播 room_update + action_log）；dtimer 不重复触发，房间状态一致；重连夺回后托管解除（H2 修复验证，行为对齐协议 v0.3 §断线） |
| MEM-08 | lobby 阶段，仅房主一人在房 | 房主断开 ws（不发送任何退房消息） | 房间进程终止并从 `list_rooms` 消失；不卡死（H3 修复验证） |
| MEM-09 | 4 人房进行中 | 某玩家连接为慢消费者（脚本端只收不读/限速读取） | 服务端有背压策略（断慢连接或丢弃可丢弃消息），conn 信箱不无限增长；其他玩家对局不受影响（H4 修复验证） |
| MEM-10 | 完整打完一局 4 人局 | 终局后继续观察 | 每玩家 action_ids 不跨局/跨回合无限累积；房间回收后其 ETS/进程内存释放（M1/M4 修复验证） |
| MEM-11 | 服务端已启动 | 单连接发送 64KB 上限帧 1000 次 | 服务端处理耗时近线性（非 O(n^2) 恶化），无超时断连（M2 修复验证，性能粗测） |
| MEM-12 | 连续跑 robot.mjs 5 局 | 每局结束后记录 `erlang:memory(total)` / 房间进程数 | 内存与进程数回落到基线附近，无单调爬升（综合回归，含 M3 子二进制滞留） |

### K. 人机功能（BOT）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| BOT-01 | lobby 阶段，1 真人在房（房主） | 房主发送 `add_bot` ×3 | 每次收到 `room_update`，players 增至 4 人，bot 玩家 `connected=true`、PlayerBrief 可区分 bot（如 `bot:true` 字段） |
| BOT-02 | 1 真人 + 3 bot | 真人 ready 后 `start_game` | 开局成功收到 `game_started`（bot 视为已准备或不受 ready 约束，按最终协议）；进入 select 阶段 |
| BOT-03 | BOT-02 开局后 | 真人每回合正常提交，bot 由服务端自动决策 | bot 在超时前自动完成合法 `submit_card`；每回合正常 reveal/结算；整局推进至 `game_over`，scores 恰 4 条 |
| BOT-04 | 1 真人 + 1 bot（2 人下限局） | 开局并打完整局 | 正常终局，验证人机可解 2 人开局 |
| BOT-05 | lobby 阶段，非房主 | 非房主发送 `add_bot` | 被拒绝（error），房间状态不变 |
| BOT-06 | lobby 阶段，房间已满 4 人 | 房主发送 `add_bot` | 被拒绝（room full），不挤掉真人 |
| BOT-07 | 游戏进行中 | 发送 `add_bot` | 被拒绝（bad_phase） |
| BOT-08 | 1 真人 + 3 bot 对局中 | 真人断线 | bot 继续自动行动；真人 60s 内 `reconnect` 可恢复并对局正常 |
| BOT-09 | 1 真人（房主）+ bot，lobby 或对局中 | 房主离开/断线且不重连 | 房间按既有规则回收（无人连接则终止），bot 不导致房间卡死或泄漏 |
| BOT-10 | 对局中 bot 回合 | 观察 bot 行为合法性 | bot 所有行动通过服务端校验（无 action_rejected 风暴）；bot 不使用 45s 超时兜底成为常态（抽测 3 回合 bot 均在 deadline 前提交） |
| BOT-11 | 任意 | 真人尝试以 bot 的 player_id/token 伪造 `reconnect` | 被拒绝；bot 无重连 token 泄漏 |
| BOT-12 | robot.mjs 扩展人机场景 | `node tests/robot.mjs --bots=3`（1 真人脚本 + 3 服务端 bot） | 输出 `SMOKE PASS`，覆盖 BOT-02/03 自动化链路 |

## 6. v0.2 统计与通过标准

- 新增用例 24 条：MEM 12（P0：MEM-02/03/04/08/12，其余 P1）+ BOT 12（P0：BOT-01/02/03/12，其余 P1）。
- v0.2 准入门槛：eunit 全过 + `tides_sim:run(20)` = `{ok,20}` + `robot.mjs` SMOKE PASS + `robot.mjs --bots=3` SMOKE PASS。
- 内存修复不得改变 v0.1 全部 P0 用例结果（全量回归）。

## 7. v0.3 战绩与人机进阶

背景：新增「战绩与排行榜」（持久化 + 天梯分 + 排行查询）与「人机进阶」（难度分级 + 掉线托管接管）。
前置依赖（v0.3 定稿状态）：
- ID-1 身份归属方案：**最终口径**——游客无 `role_id`/`PlayerProcess`，仅纯客户端教程；注册成功后才成为账号。旧 `player_token` 仅保留兼容专项，不得作为账号归属依据。
- ID-2 含人机局计分：最终口径为照常计分，Bot 不使账号 `ladder_delta` 减半，recent 标记 `has_bot`；本条覆盖旧的 ×0.5 历史约定。
- ID-3 掉线未归结算：**已定案**——开局 30s 内退出/断线未归按末名计（rage_quit）；之后掉线由 AI 托管按实际名次正常计分。
准入：沿用 v0.2 三项门槛 + eunit 新增战绩/托管用例全过。

### L. 战绩与排行榜（LDR）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| LDR-01 | 纯真人 4 人局（无 bot） | 打完一整局收到 `game_over` | 每位真人战绩 games+1，胜者 wins+1；战绩服务/表中可见（落盘成功） |
| LDR-02 | LDR-01 后 | 正常停止并重启服务端，再查询同一身份战绩 | 战绩与重启前一致，不丢失、不回退 |
| LDR-03 | 已知各账号初始天梯分 | 打完一局，对比终局名次与分值变化 | 仅账号按账号契约计分；游客不产生任何统计。旧 token 仅 `LEGACY` |
| LDR-04 | 库中已有 ≥10 个身份的战绩 | 客户端发送 `get_leaderboard {board, offset?, limit?}` | 收到列表：`board=ladder` 按天梯分降序、`board=wins` 按胜场降序；字段含 rank/name/ladder/games/wins/win_rate；**入榜门槛 games≥5**（协议 v0.3）；limit 默认 10 最大 100，非法 board/limit 返回 `invalid_board`/`invalid_limit`；附 `self_rank`（未入榜/游客为 null） |
| LDR-05 | 1 账号 + 3 临时 Bot 局（`robot.mjs --bots=3`） | 打完一整局并关闭房间 | 账号按当前契约计分；Bot 无账号记录，房间关闭后 Bot 临时数据释放；旧 token 统计只作 `LEGACY` |
| LDR-06 | 已有战绩的身份 | 发送个人战绩查询消息 | 返回 games/wins/胜率/天梯分及策划约定的「常用策略」等统计字段，数值与历史对局一致 |
| LDR-07 | 按 ID-1 所选方案构造身份 | 同一身份跨 2 个房间各打一局；再换一个身份打一局 | 同身份两局战绩归并累计；不同身份战绩隔离（昵称相同但身份不同不串数据） |
| LDR-08 | 对局进行中 p2 断线且 60s 内不重连 | 打到终局 | **v0.3 修订**（ID-3 定案）：开局 30s 内断线未归标记 rage_quit **按末名计**；之后掉线由 AI 托管打完，**按实际名次正常计分**；其他玩家正常结算；服务端无残留状态 |
| LDR-09 | 无 | 3 个房间同时打到终局（CC-03 缩减版） | 三局战绩全部正确落盘，无丢失、无跨房间串数据、无写冲突报错 |
| LDR-10 | 服务端未启动 | 场景A：删除战绩数据文件后启动；场景B：写入损坏数据文件后启动 | A：正常启动，战绩为空库；B：不崩溃，按容错策略（丢弃损坏库/备份后重建）启动并记录日志 |
| LDR-11 | 反作弊（按 ID-1 方案细化） | 同一身份并发在两个房间同时开局；短时间内同一身份连打 N 局 | 并行计分策略符合文档；无重复计数、无负分刷分路径；异常频次有日志或限制（若策划要求） |
| LDR-12 | 服务端已启动 | 发送缺字段/非法字段的排行榜与战绩查询消息 | 返回 `error`（code 为字符串），服务端不崩溃；新消息类型不破坏既有信封校验 |

### M. 人机进阶（BOT2）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| BOT2-01 | lobby，房主在房 | `add_bot` 带 `difficulty:"easy"` | 人机以简单难度加入（`room_update` 按协议体现难度或仅服务端记录）；整局行为合法且可观察到与标准难度的差异（如扰动率更高/不前瞻） |
| BOT2-02 | lobby，房主在房 | `add_bot` 带 `difficulty:"hard"`，1 真人开局打完整局 | 困难人机每回合合法提交、正常终局；困难逻辑（前瞻潮汐/商站博弈）不触发任何 `action_rejected` 由人机引起 |
| BOT2-03 | lobby，房主在房 | `add_bot` 带非法 `difficulty`（如 `"impossible"`、数字、超长串） | 被拒绝（error code 字符串）或按协议默认回落，房间状态不变，服务端不崩溃 |
| BOT2-04 | 对局进行中，真人 p2 断线 | 等待超过 60s 宽限期，观察 p2 回合 | p2 由人机托管接管：其回合为 AI 决策的合法行动（不再是简单弃第 1 张 tide）；按协议广播体现托管状态；其他玩家不阻塞 |
| BOT2-05 | BOT2-04 托管中 | p2 用原 token `reconnect` | 重连成功并夺回控制权；收到最新 `state_sync`（含本人 private_state）；下一回合起真人提交生效，托管定时器/消息不残留（不双提交） |
| BOT2-06 | BOT2-04 托管至终局 | 打完剩余回合 | `game_over` 正常，托管玩家正常参与计分；其战绩结算遵循 LDR-08/ID-3 |
| BOT2-07 | 托管期间 | 检查其他玩家收到的 `public_state.players[]` 与 `room_update` | `connected`/托管标志按协议呈现，不泄漏托管 AI 的决策信息；伪造他人 token 重连仍被拒绝 |
| BOT2-08 | 1 真人 + 2 bot 局 | 真人断线 >60s 再重连，打完终局 | 托管接管 + 既有 bot 各自独立调度不冲突；重连夺回后整局正常收束 |
| BOT2-09 | 托管接管生效后 | 观察托管玩家提交时延 | 托管决策在协议约定时限内提交（沿用 1-3s 随机或按新协议），不依赖 45s 超时兜底 |
| BOT2-10 | eunit/sim 层 | `tides_sim` 分别以 easy/hard 各跑 20 局自玩 | 两档难度各 `{ok,20}`，无崩溃、无非法行动兜底风暴 |

## 8. v0.3 统计与通过标准

- 新增用例 22 条：LDR 12（P0：LDR-01/02/03/05/09/10，其余 P1；LDR-07/11 依赖 ID-1 定案后定优先级）+ BOT2 10（P0：BOT2-04/05/08，其余 P1）。
- v0.3 准入门槛：v0.2 三项门槛全过 + eunit 新增用例全过 + `tides_sim` easy/hard 各 `{ok,20}`。
- 全量回归：v0.1/v0.2 全部 P0 用例不得回退；特别注意断线走超时自动行动的旧路径（DC-04/TO-01）在「托管接管」开启后的行为差异须与协议文档一致。

## 9. v0.3.1 上线部署演练（DEP）

背景：用户批准按 `deploy/README.md` 跑生产形态部署演练，验证 v0.3 全部功能在「代理 + 服务端」生产形态下可用。已知风险 R6：docker-compose 缺数据卷，容器重建丢 dets 战绩。
环境约束：本机（Windows）**无 docker、无公网/域名**，演练分两级：
- **本机可验级**：宿主机直装形态（等价 docker 内单容器进程）+ `proxy_sim.mjs` 反代隧道 + dets 落盘/重启持久化。
- **需 VPS/docker 级**（标记「待部署环境」）：compose 真实编排、nginx 真配置、TLS/wss 真链路。
准入：v0.3 准入门槛全过 + deploy/ 差距清单已由主协调闭环（DEP-01 前置）。

### N. 部署演练（DEP）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| DEP-01 | deploy/ 改动已由主协调落地 | 静态审查 docker-compose.yml / Dockerfile.server / nginx.conf / README：数据卷挂载、镜像版本号、healthz 期望版本、healthcheck 段、docker 形态 proxy_pass | 差距清单（见本轮分诊报告）逐条闭环，无遗留 |
| DEP-02 | 服务端以生产等价形态启动（start_server.bat，后台进程） | `curl http://127.0.0.1:9500/healthz`；`curl http://127.0.0.1:9500/` | healthz 200 且 version 与 `tides_server:version()` 当前值（0.3.0）一致；`/` → 404 |
| DEP-03 | DEP-02 后；`node tests/proxy_sim.mjs` 监听 18080 | `node tests/robot.mjs ws://127.0.0.1:18080/ws` 完整 4 人局 | `SMOKE PASS`——代理形态 4 人整局可用（等价 nginx `/ws` 隧道，复用 PC-10 链路） |
| DEP-04 | DEP-03 对局含携带 player_token 的真人身份 | 打完一局后查 `server/data/tides_stats.dets` mtime/大小 + `get_my_stats` | dets 文件随终局写盘更新；games+1——生产形态下落盘链路可用 |
| DEP-05 | DEP-04 后 | 杀服务端进程并重启（等价容器重建但数据目录保留），再查同一 token 战绩 | 战绩与重启前一致（等价验证「数据卷挂载后重建不丢战绩」；卷本身属 DEP-01 审查项） |
| DEP-06 | 备份现有 dets 后 | 删除 `server/data/tides_stats.dets` 重启服务端，跑一局 | 正常启动为空库并重建落盘（容器无卷重建的灾难容错路径，对齐 LDR-10 场景 A）；测后恢复备份 |
| DEP-07 | **待部署环境**（docker 可用） | `docker compose -f deploy/docker-compose.yml config` 校验 + `up -d --build`；`curl http://127.0.0.1:9500/healthz` | 配置校验通过；容器内 healthz 200；`docker exec` 确认 `/app/server/data/tides_stats.dets` 存在于挂载卷（非容器层） |
| DEP-08 | **待部署环境** DEP-07 后 | 打完一局 → `docker compose up -d --build --force-recreate` 重建 tides-server 容器 → 再查战绩 | 重建后战绩仍在（R6 修复的终极验证，DEP-05 的真实形态） |
| DEP-09 | **待部署环境**（nginx 容器或宿主机 nginx） | 用 docker 形态 proxy_pass（tides-server:9500）的 nginx 配置，`node tests/robot.mjs http://<nginx>/ws` | SMOKE PASS；DEP-03 的 proxy_sim 结论在真 nginx 上复现 |
| DEP-10 | **待公网**（域名 + 证书） | `curl https://<域名>/healthz`；`node tests/robot.mjs wss://<域名>/ws`；浏览器 https 整局 | 同 LAN-02：wss 整局 SMOKE PASS、浏览器无断连；本机只能以自签证书演练 TLS 卸载流程，wss 真链路不可本机验证 |

### v0.3.1 统计与通过标准

- 新增用例 10 条：DEP 10（P0：DEP-01/02/03/04/05；P1：DEP-06/07/08/09；P2 人工：DEP-10）。
- 通过标准：本机可验级 DEP-01~06 全 PASS 即「本机演练通过」；DEP-07~10 为上线前 VPS 现场必做项，不阻塞本机验收结论但阻塞「生产就绪」结论。
- wss/TLS 链路（DEP-10）本机无法真实验证：无公网域名则无法签发受信证书，浏览器混合内容限制也无法在 https 页面下测 ws://；只能验证到「http 反代隧道」层（DEP-03/09）。

## 10. v0.3.2 服务端管理（ADM）

背景：用户反馈「开/关服务器、看状态、看在线玩家太麻烦」。形态（分诊定案，待主协调确认）：
- **开/关为 OS 脚本层**：服务端未运行时 HTTP 接口不可用，故 start/stop 必须走脚本。新增统一入口 `deploy/tidesctl.bat start|stop|status|players`（保留 `start_server.bat` 兼容），Linux 侧补 `tidesctl.sh`。
- **状态/在线玩家为 HTTP 管理接口**：复用 `tides_ws_conn` 的 HTTP 应答路径（同 healthz），新增 `GET /admin/status` 与 `GET /admin/players`，不走 WS、不进 `shared/protocol.md` 的 WS 消息表（建议主协调在 protocol.md 补「管理 HTTP 端点」小节）。
- **安全方案（推荐，待主协调定案）**：`/admin/*` 默认仅应答 127.0.0.1 来源；`shared/data/config.json` 可选配置 `admin_token`，配置后要求请求头 `X-Admin-Token` 匹配。
前置依赖：后端实现完成（tides_ws_conn 路由 + tides_lobby/tides_room 管理查询 API）+ deploy 脚本落地。准入：v0.3.1 本机演练结论不回退。

### O. 服务端管理（ADM）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| ADM-01 | 服务端未运行，9500 空闲 | `deploy\tidesctl.bat start` | 编译成功、后台启动、`netstat` 可见 9500 LISTENING；`curl /healthz` 200；重复执行 start 提示端口占用并退出码非 0（不启第二个实例） |
| ADM-02 | ADM-01 后 | `tidesctl.bat status` | 输出来自 `GET /admin/status`：字段完整含 `version`（与 tides_server:version() 一致）、`uptime_sec`（>0 且随时间增长）、`rooms_online`、`players_online`、`memory_mb`；JSON 可解析 |
| ADM-03 | ADM-02 后；robot/手工建 1 房间（2 真人 + 1 bot） | `tidesctl.bat players` | 输出来自 `GET /admin/players`：每名玩家含 `name/room_id/is_bot/connected`，与 WS `list_rooms` + `room_update` 实际成员一致（含 bot 标记）；玩家退房/断线后列表同步变化 |
| ADM-04 | 服务端运行中 | `tidesctl.bat stop` | 服务端进程退出；9500 端口释放（netstat 无 LISTENING）；随后 `curl /healthz` 连接失败；无新增 `erl_crash.dump`；dets 战绩正常落盘不损坏 |
| ADM-05 | 服务端未运行 | `tidesctl.bat status` 与 `tidesctl.bat players` | 友好提示「服务端未运行」（连接失败识别），非堆栈/非乱码；退出码非 0 |
| ADM-06 | 服务端未运行，但本机其他进程占用无关端口 | `tidesctl.bat stop` | 幂等友好提示「服务端未在运行」，**不误杀**任何其他进程（仅按 9500 监听 PID 或 pid 文件定位） |
| ADM-07 | 安全方案按主协调定案配置 | 场景A：从非 127.0.0.1 来源请求 `/admin/status`；场景B（配置了 admin_token 时）：缺头/错头请求 | A：拒绝（403 或不应答）；B：401/403；合法 localhost+正确 token 正常 200 |
| ADM-08 | ADM-01~07 执行后 | 全量回归：`node tests/robot.mjs` + PC-09 healthz 用例 | `SMOKE PASS`；`/healthz` 行为不变；`/` 仍 404；管理接口不影响任何 WS 协议行为 |
| ADM-09 | 1 房间对局进行中（select 阶段） | 对局中并发调用 `status`/`players` 各 20 次 | 响应 P95 < 500ms；对局正常推进不被阻塞（回合按时结算，无超时兜底触发）；无连接/进程泄漏 |
| ADM-10 | 服务端运行中 | 连续 50 次 `GET /admin/status` 与 `GET /admin/players` | 每次 200、Content-Length 正确、`Connection: close`；响应为合法 JSON；服务端无残留进程堆积 |

### v0.3.2 统计与通过标准

- 新增用例 10 条：ADM 10（P0：ADM-01/02/03/04/05/06/08；P1：ADM-07/09/10）。
- 通过标准：ADM-01~06、08 全 PASS 即「本机管理功能验收通过」；ADM-07 依主协调安全方案定案执行；ADM-09/10 可与日常回归合并执行。
- Linux `.sh` 侧（tidesctl.sh start/stop/status/players）本机（Windows）不可验，标记「待 Linux/VPS 环境」，不阻塞本机结论。

## 11. v0.5 主动退出对局（LQ）

背景：新增「对战中退出对战（退出者判负）」（协议 v0.5 §主动退出对局）。C→S `leave_game`；S→C `player_left{player_id,name,reason}`、`game_over.scores[].rage_quit`；错误码 `not_in_game`/`already_game_over`。退出者立即收 ack+returned_to_lobby 并释放角色房间绑定（可立即开新局）、reconnect 原房间被拒；只剩 1 名真人时立即按当前比分终局；断线 grace 到期托管也广播 `player_left(reason="disconnect")`。
准入：eunit 全过（含 leave_game 4 用例）+ `tides_sim:run(20)` = `{ok,20}` + `robot.mjs` SMOKE PASS。
自动化：`node tests/quit_game_check.mjs [--scenario=a|b] [--register]`（无账号 fixture 时 BLOCKED exit 2）。

### P. 主动退出对局（LQ）

| 编号 | 前置 | 步骤 | 预期 |
|---|---|---|---|
| LQ-01 | lobby 阶段（房间未开局） | 发送 `leave_game {}` | 返回 `error.payload.code=not_in_game`，房间状态不变（quit_game_check 场景 B / B1） |
| LQ-02 | 4 人局第 2 回合 select 阶段 | p2 发送 `leave_game` | p2 收到 `ack`（action_id 匹配）+ `returned_to_lobby{room_id=原房}`（场景 A / A1-A2） |
| LQ-03 | LQ-02 后 | 观察其余 3 人 | 每人收到 `player_left{player_id=p2, name, reason="quit"}`；随后 `room_update` 中 p2 座位 `connected=false`、`auto_pilot=true`（A3-A4） |
| LQ-04 | LQ-02 后 | p2 立即 `reconnect` 原房间（原 token）→ `list_rooms` → `create_room` | reconnect 被拒绝（error，message 含 "left the game"）；`list_rooms` 正常返回；`create_room` 成功且 room_id 不同——角色绑定已释放（A5-A7） |
| LQ-05 | LQ-02 后 | 其余 3 人继续对局至终局 | 对局不中断，p2 座位由 AI 托管；3 人均收到 `game_over`，scores 恰 4 条、total≥0；随后收到 `returned_to_lobby`（A8/A10） |
| LQ-06 | LQ-05 终局 | 校验 p2 的 score 条目 | p2 `rage_quit=true`、`rank=4`（强制末名，即使 total 最高）、`ladder_delta=-20`（4 人末名档）；其余玩家 `rage_quit=false`、rank∈1..3（A9） |
| LQ-07 | LQ-05 终局后 | p2 发送 `get_my_stats`，与开局前基线对比 | `games`+1、`wins` 不变、`win_streak=0`；`recent[0]` 为 `rank=4, ladder_delta=-20`（A11） |
| LQ-08 | 2 人局 select 阶段 | p2 发送 `leave_game` | 只剩 1 名真人，立即按当前比分终局：剩余玩家收到 `player_left(quit)` 后收 `game_over`，scores 恰 2 条；p2 `rank=2/rage_quit=true/ladder_delta=-10`（2 人末名档），剩余玩家 `rank=1/rage_quit=false/ladder_delta>0`；随后 `returned_to_lobby`（场景 B / B2-B5） |
| LQ-09 | game_over 阶段 | 发送 `leave_game` | 返回 `error.payload.code=already_game_over`，不重复结算（eunit `leave_game_last_human_finishes_test` 覆盖，live 有 returned_to_lobby 竞态窗口不自动化） |
| LQ-10 | 对局中 p2 断线且 grace（60s）到期未归 | 观察广播 | 托管接管时广播 `player_left{reason="disconnect"}`（eunit/代码走查覆盖；与 LQ-02 的 `quit` 区分） |
| LQ-11 | 客户端 UI | 对战中点「退出对战」按钮 | 二次确认弹窗；确认后发送 `leave_game`，本人收到 toast/返回大厅；结算页退出者带「退出」标记（纯 UI 项：代码走查 + `npm run build` 通过） |

### v0.5 统计与通过标准

- 新增用例 11 条：LQ 11（P0：LQ-01~09；P1：LQ-10；UI 人工项：LQ-11）。
- 通过标准：LQ-01~08 由 `quit_game_check.mjs` 全量自动化 PASS（exit 0）；LQ-09/10 由 eunit 覆盖；LQ-11 走代码走查 + 构建确认。
- 全量回归：eunit + `tides_sim:run(20)` + `robot.mjs` 不得回退。
