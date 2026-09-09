# v0.2 验收报告 — 内存修复（C1-C3/H1-H4/M1-M4/L1-L2）+ 人机（bot）功能

- 验收日期：2026-08-26
- 验收人：测试PM（自动化回归）
- 被测版本：服务端 v0.2（healthz 上报 0.1.0，应用内版本号未随 v0.2 更新，见遗留风险 R3）
- 环境：本机 Windows，`ws://127.0.0.1:9500/ws`，服务端 PID 13496（测试后保持运行）

## 1. 准入门槛（全部 PASS）

| 步骤 | 命令 | 结果 |
|---|---|---|
| 编译 | `erl -noshell -eval "make:all()" -s init stop` | PASS，exit 0 |
| eunit + 模拟 | `eunit:test([tides_json_tests, tides_game_tests])` → `tides_sim:run(20)` | PASS，16 tests passed；`{ok,20}`，exit 0 |
| 4 真人冒烟 | `node tests\robot.mjs` | PASS（SMOKE PASS，房间 RSNZ，整局 12 回合至 game_over，scores=4） |
| 人机冒烟 | `node tests\robot.mjs --bots=3` | PASS（SMOKE PASS，房间 MEHH，1 真人 + bot_1/2/3，整局至 game_over，scores=4） |
| 反代链路（顺带） | `node tests\robot.mjs ws://127.0.0.1:18080/ws`（proxy_sim + client/dist） | PASS（SMOKE PASS，房间 WA9Z） |

## 2. 用例结果明细

### J. 内存回归（MEM）

| 用例 | 结果 | 证据/说明 |
|---|---|---|
| MEM-01 分片缓冲上限 | ⬜ 未测 | 需构造 raw 分片帧，本轮未自动化 |
| MEM-02 重复 create_room 50 次 | ✅ PASS | mem_check.mjs：50 次全部收到 `error code=already_in_room`；`list_rooms` 中该房间恰好 1 个实例（总房间数=1） |
| MEM-03 join 后再 join/create | ⬜ 未测 | MEM-02 已覆盖 create 分支（同码 already_in_room）；join 分支未单独验证 |
| MEM-04 无孤儿房间 | ✅ PASS | 脚本创建的全部房间（695C 等）在连接断开后消失，`list_rooms` 回落至基线 0 |
| MEM-05 200 次异常 TCP 连接 | ✅ PASS | 200 次（一半握手中途断开、一半立即 RST）后 ping/pong 与 create_room 正常，监听器存活 |
| MEM-06 conn catch-all | ⬜ 未测 | 需注入进程消息，属服务端内部观测 |
| MEM-07 grace_expired 行为 | ⬜ 未测 | 需等待 >60s grace，本轮未跑 |
| MEM-08 lobby 房主断开 | ✅ PASS | 场景1：单人 lobby 房主断线 → 房间立即从 list_rooms 消失；场景2：2 人 lobby 房主断线 → 房主转移给真人 guest（room_update 中 guest.host=true） |
| MEM-09 慢消费者背压 | ⬜ 未测 | 需限速读取脚本，本轮未自动化 |
| MEM-10 action_ids 累积 | ⬜ 未测 | 需服务端内存观测 |
| MEM-11 大帧性能 | ⬜ 未测 | — |
| MEM-12 连续 5 局内存回落 | ⬜ 未测 | 需 erlang:memory 采样工具，本轮未自动化 |

### K. 人机功能（BOT）

| 用例 | 结果 | 证据/说明 |
|---|---|---|
| BOT-01 add_bot×3 + PlayerBrief | ✅ PASS | robot --bots=3：3 次 add_bot 后 room_update 增至 4 人；bot 均 `is_bot=true`、`ready=true`、`connected=true`、`host=false`（robot 内置校验，不符即 FAIL） |
| BOT-02 1 真人 + 3 bot 开局 | ✅ PASS | 真人 ready 后 start_game 成功，收到 game_started（手牌 5、公开订单 3） |
| BOT-03 整局自动推进 | ✅ PASS | bot 每回合在超时前约 2-3s 自动提交（reveal 中 bot 行动 action/cargo/tide 均有），无 action_rejected 风暴；整局 12 回合至 game_over，scores 恰 4 条，total 均 ≥0 |
| BOT-04 1 真人 + 1 bot | ⬜ 未测 | robot 支持 `--bots=1`，本轮未跑 |
| BOT-05 非房主 add_bot | ⬜ 未测 | — |
| BOT-06 满员 add_bot | ⬜ 未测 | — |
| BOT-07 游戏中 add_bot | ⬜ 未测 | — |
| BOT-08 真人断线重连（人机局） | ⬜ 未测 | — |
| BOT-09 房主离开后人机房回收 | ⬜ 未测 | 服务端代码路径（has_human=false → stop）存在，未实测 |
| BOT-10 bot 行动合法性抽测 | ✅ PASS（间接） | --bots=3 整局 reveal 显示 bot 全部提交成功，无拒绝；未做 3 回合 deadline 前提交的时间戳抽测 |
| BOT-11 伪造 bot reconnect | ⬜ 未测 | — |
| BOT-12 `robot.mjs --bots=3` SMOKE PASS | ✅ PASS | 见准入门槛 |

### v0.1 回归（抽测）

| 项 | 结果 |
|---|---|
| eunit（协议 JSON + 游戏规则 16 项） | ✅ PASS |
| 4 真人整局冒烟（RC 链路 + 终局计分校验） | ✅ PASS |
| PC-09 healthz | ✅ PASS（`{"ok":true,"service":"tides"}`） |
| PC-10 反代整局 | ✅ PASS |
| v0.1 其余 P0 手工项（RJ/DC/TO/SC 全量） | ⬜ 本轮未重跑 |

## 3. 结论

- **内存修复验收：有条件通过。** 可自动化项 MEM-02/04/05/08 全部 PASS，重复建房、异常连接风暴、lobby 断线房间回收均无泄漏迹象；MEM-01/03/06/07/09/10/11/12 未覆盖，需后续补测或服务端侧观测。
- **人机功能验收：核心链路通过。** BOT-01/02/03/10/12 PASS，服务端 bot 行为与 protocol.md v0.2 一致，未发现协议偏差；BOT-04/05/06/07/08/09/11 未测。
- **v0.1 回归：无回退迹象**（eunit + 双场景冒烟 + 反代全 PASS），但手工 P0 项未全量重跑。

## 4. 遗留风险

- R1：MEM-12（连续多局内存回落）与 MEM-09（慢消费者背压）为线上稳定性关键项，尚无自动化工具，建议下轮补 `erlang:memory` 采样脚本。
- R2：BOT-05/06/07（三类拒绝场景）与 BOT-11（伪造 bot token）为 P1 安全/校验项，未覆盖。
- R3：服务端 healthz 上报 `version: "0.1.0"`，与 v0.2 发布不符（建议后端下次更新应用版本号）。
- R4：BOT-04（2 人下限局）脚本已支持 `--bots=1` 但未实测。
