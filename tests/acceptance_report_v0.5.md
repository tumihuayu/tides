# v0.5 退出对战（leave_game）验收报告

- 验收日期：2026-09-04　验收人：测试PM agent
- 范围：协议 v0.5「主动退出对局」——C→S `leave_game`；S→C `player_left{player_id,name,reason}`、`game_over.scores[].rage_quit`；错误码 `not_in_game`/`already_game_over`；退出者判负（强制末名）、立即释放房间绑定、reconnect 原房被拒；只剩 1 名真人立即按当前比分终局；断线 grace 到期托管广播 `player_left(reason="disconnect")`。
- 依据：`shared/protocol.md` v0.5 §主动退出对局；`tests/test_plan.md` §11（LQ-01~11）。

## 1. 执行摘要

| 项 | 结果 |
|---|---|
| 编译 `make:all()` | 通过 |
| eunit（tides_json_tests + tides_game_tests，含 leave_game 4 用例） | 22/22 通过 |
| `tides_sim:run(20)` | `{ok,20}`（exit 0） |
| `robot.mjs` 4 账号整局冒烟（原有用例回归） | `SMOKE PASS`（exit 0），无回归 |
| `quit_game_check.mjs --register`（新增，场景 A+B） | `QUIT_CHECK PASS (2 scenario(s))`，连续 2 轮全过（exit 0） |
| 客户端 `npm run build`（tsc + vite） | 通过（LQ-11 UI 项走查替代） |
| 服务端 bug | 0 |
| 最终结论 | **通过** |

## 2. 验收清单逐项结果（LQ-01~11）

| 用例 | 内容 | 结果 | 证据 |
|---|---|---|---|
| LQ-01 | lobby 阶段 `leave_game` → `not_in_game` | 通过 | 场景 B / B1：`error.payload.code=not_in_game` |
| LQ-02 | 4 人局第 2 回合退出者收 `ack` + `returned_to_lobby{room_id=原房}` | 通过 | 场景 A / A1-A2（ack action_id 匹配，room_id 匹配）×2 轮 |
| LQ-03 | 其余 3 人收 `player_left{player_id,name,reason="quit"}`；座位 `connected=false/auto_pilot=true` | 通过 | A3（3 人逐一校验 player_id/name/reason）+ A4（room_update 座位标志） |
| LQ-04 | 退出者 reconnect 原房被拒；立即 `list_rooms`/`create_room` 成功 | 通过 | A5-A7（reconnect 拒绝见遗留 Q1；create_room 新 room_id ≠ 原房） |
| LQ-05 | 其余 3 人不中断打完收 `game_over`（scores=4，total≥0）+ `returned_to_lobby` | 通过 | A8/A10；对局在 p2 托管下正常推进 4 轮 ×3 回合 |
| LQ-06 | 退出者 `rage_quit=true`、`rank=4`、`ladder_delta=-20`；其余 `rage_quit=false`、rank∈1..3 | 通过 | A9；两轮退出者 total=6 与 total=10（全场最高分之一）仍强制末名，强制末名逻辑确实压过实际比分 |
| LQ-07 | 退出者 `get_my_stats`：games+1、wins 不变、win_streak=0、recent[0]={rank:4,ladder_delta:-20} | 通过 | A11（开局前基线对比，隔离新账号基线 games=0） |
| LQ-08 | 2 人局退出 → 只剩 1 真人立即按当前比分终局 | 通过 | 场景 B / B2-B5：player_left→game_over 秒级到达；scores=2，退出者 rank=2/rage_quit/delta=-10，剩余 rank=1/delta>0 ×2 轮 |
| LQ-09 | game_over 阶段 `leave_game` → `already_game_over`，不重复结算 | 通过 | eunit `leave_game_last_human_finishes_test`（live 有 returned_to_lobby 竞态窗口，不自动化） |
| LQ-10 | 断线 grace 到期托管广播 `player_left{reason="disconnect"}` | 通过（走查） | tides_room.erl:155-176 grace 到期分支与 quit 共用 player_left 广播，reason 区分正确；60s 等待不做 live 自动化 |
| LQ-11 | 客户端退出按钮 + 二次确认 + toast + 结算「退出」标记 | 通过（走查+构建） | 前端为纯 UI 改动；`npm run build`（tsc 类型检查 + vite）通过；未做浏览器人工点击，建议上线前人工过一遍交互 |

## 3. 新增测试资产

| 文件 | 说明 | 运行结果 |
|---|---|---|
| `tests/quit_game_check.mjs` | 零依赖 WS 检查脚本（robot.mjs 风格）：场景 A=4 人局第 2 回合退出全链路（A1-A11 断言组），场景 B=2 人局立即终局 + lobby 拒绝（B1-B5）；`--register` 自注册隔离账号，无 fixture 时 BLOCKED(exit 2) | `QUIT_CHECK PASS (2 scenario(s))` exit 0，连续 2 轮 |
| `tests/test_plan.md` §11 | LQ-01~11 用例表与通过标准 | — |
| `tests/acceptance_checklist.md` §4.12 | v0.5 验收勾选项（全部 [x]） | — |
| `tests/README.md` | 脚本登记与运行说明 | — |

## 4. 发现的 bug / 遗留观察项

无服务端/客户端功能性 bug。以下两项为观察项，均不阻塞验收：

| 编号 | 级别 | 说明 | 建议 |
|---|---|---|---|
| Q1 | P3 建议 | 退出者 reconnect 原房间被拒时，WS 层返回的是通用 `error{code:"error", message:"player has left the game"}`，无专用错误码（protocol.md 未要求专用码，但客户端若要做差异化提示只能匹配 message 文案） | 建议后端在后续版本为该类拒绝补专用 code（如 `player_left`/`reconnect_forbidden`），由主协调评估是否入 protocol.md；建议修复方：后端 agent |
| Q2 | P4 环境噪音 | eunit 环境（未启动 tides_stats）运行 `leave_game_last_human_finishes_test` 时打印一条 `tides stats write failed ... noproc` ERROR REPORT，用例本身通过；纯测试环境噪音 | 建议后端在测试 setup 中按需启动或 mock tides_stats，消除告警噪音；建议修复方：后端 agent（低优先） |

测试脚本自身在联调中修复的 3 处竞态（与被测系统无关，仅记录备查）：广播类消息（player_left/returned_to_lobby/game_over）可能与 ack 同 TCP 段同步到达，waiter 必须提前注册；`Promise.all` 误写为 `await 数组`；autoPlay 开启后需立即补一次提交触发避免空等 45s 超时。

## 5. 回归项复核

- `robot.mjs`（4 账号整局）：PASS，终局排名/breakdown 正常，无协议行为回退。
- eunit 22/22、`tides_sim:run(20)`={ok,20}：PASS。
- 数值口径核对：4 人局末名档 -20（`points_table(4)=[30,10,0,-20]`）、2 人局末名档 -10（`points_table(2)=[20,-10]`），负分不受低天梯加成影响，实测与 `tides_stats.erl` 一致。
- 验收完成后服务端已停止（9500 无 LISTENING 残留）。

## 6. 最终验收结论

**通过**。v0.5「退出对战（退出者判负）」协议层行为与 protocol.md v0.5 完全一致，回归无回退；遗留 Q1（reconnect 拒绝缺专用错误码）为 P3 改进建议，Q2 为 eunit 环境噪音，均不阻塞。客户端 UI 项（LQ-11）已通过代码走查 + 构建确认，建议下次人工验收窗口补一次浏览器实机点击。
