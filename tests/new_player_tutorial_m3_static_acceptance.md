# M3 新玩家教程静态验收报告

版本：M3 static acceptance  
验收日期：2026-08-28  
验收人：测试 PM  
验收方式：静态源码、协议、SQL、客户端状态处理及已有 verify/构建报告核对  
范围：跳过 M3 live 验收；本报告不宣称任何 WebSocket、MySQL 或浏览器实测通过

## 1. 总体结论

**结论：CONDITIONAL（不构成 M3 发布通过，进入 M4 前需补齐阻塞实测和实现缺口）。**

静态层面确认了教程消息、`session_id`、`snapshot_version`、账号完成写入入口、游客身份分支、客户端旧快照过滤和恢复失败 UI 的基本链路。现有代码不能支持把 M3 的完整持久化/恢复/幂等要求判为 PASS：教程运行快照、恢复窗口和 `action_id` 去重均在 Erlang 教程进程/ETS 内存中；服务端重启后无法恢复进行中的会话；`tutorial_replay` 没有请求级幂等标识；MySQL 连接、账号跨重启/跨设备及浏览器故障均未实测。

静态结论规则：源码可直接证明的项目记 `PASS`；依赖运行时、数据库、进程重启、设备或浏览器的项目记 `BLOCKED`；源码已显示与 M3 要求不一致的项目记 `CONDITIONAL` 或 `BLOCKED`，不因跳过 live 而伪装通过。

## 2. 证据路径

| 证据 | 路径 | 用途 |
|---|---|---|
| 唯一协议事实来源 | `shared/protocol.md:72-79`、`:132-144` | 消息、身份、恢复窗口、版本、重玩语义 |
| 账号服务 | `server/src/tides_account.erl:74-77`、`:149-181` | 完成查询及按 `account_id` 写入 |
| 教程会话 | `server/src/tides_tutorial.erl:10-12`、`:16-35`、`:68-150` | 会话生命周期、内存快照、恢复窗口、行动去重 |
| WebSocket 路由 | `server/src/tides_ws_conn.erl:499-617`、`:620-630` | 教程路由、身份和响应封装 |
| 账号表 | `server/sql/accounts.sql:1-10` | `tutorial_completed` 列及账号键 |
| 客户端状态 | `client/src/main.ts:11-36`、`:352-365`、`:437-538`、`:605-687` | 本地键、账号状态、版本过滤、恢复错误 |
| 客户端教程 UI/类型 | `client/src/tutorial.ts:17-21`、`:171-213`；`client/src/types.ts:86-94` | 静态手册和教程状态显示 |
| M3 用例 | `tests/new_player_tutorial_m3_cases.md:105-177`、`:196-229` | 40 条用例、门槛和阻塞标准 |
| M3 最小脚本 | `tests/new_player_tutorial_m3_smoke.mjs:23-70`、`:107-167` | 静态门禁及可选 live 探测定义 |
| 历史回归 | `tests/acceptance_report_v0.3.2.md:15-28`、`:58-68` | 管理、eunit、sim、robot、stats 证据 |
| MySQL 报告 | `tests/mysql_readonly_report_2026-08-27.md:7-25` | 当前数据库验证阻塞原因 |
| verify 入口 | `server/verify.escript:5-18` | eunit + 三类 20 局模拟入口 |

本轮实际执行的静态命令：`node tests/new_player_tutorial_m3_smoke.mjs`。输出为 `PC-01..PC-06 PASS`、`IMPL-01..IMPL-06 PASS`、`ENV-WS BLOCKED`，汇总 `PASS=2 FAIL=0 BLOCKED=1`；这是静态门禁通过，不是 M3 行为验收通过。

## 3. 核对结果

### 3.1 协议与实现

| 项目 | 结论 | 静态证据 |
|---|---|---|
| 教程消息及状态字段 | PASS | `shared/protocol.md` 定义 `tutorial_status`、`tutorial_reconnect`、`tutorial_replay` 及 `tutorial_state`；`tides_ws_conn.erl:499-617` 路由并发送 `session_id`、`snapshot_version`。 |
| 状态版本递增 | PASS（源码） | `tides_tutorial.erl:119-139` 成功推进时 `snapshot_version + 1`，新建从 1 开始；客户端 `main.ts:437-449` 丢弃低版本/不同 session。乱序实测未覆盖。 |
| action_id 行动幂等 | CONDITIONAL | `tides_tutorial.erl:102-105` 以进程内 `actions` map 去重，同 ID 重放返回 ack；但去重记录不是持久化恢复点，断线/进程重启/并发行为未实测。 |
| 错误语义 | PASS（静态路径） | 非法 action、阶段不符、恢复不可用、教程状态不可用均有字符串 reason/code 路径（`tides_tutorial.erl:90-115`、`tides_ws_conn.erl:569-577`）。错误分类和下一步文案的全量覆盖未实测。 |
| 普通房隔离 | PASS（源码路径） | active tutorial 时创建/加入/普通 reconnect 返回 `tutorial_active`（`tides_ws_conn.erl:422-436`）；教程使用独立进程，不进入 lobby 路径。普通房并行广播仍需回归实测。 |

### 3.2 账号持久化与游客隔离

| 项目 | 结论 | 静态证据 |
|---|---|---|
| 账号完成事实写入路径 | CONDITIONAL | `tides_tutorial.erl:129-134,195` 仅 `{account, Id}` 调用 `tides_account:tutorial_complete(Id)`；`tides_account.erl:171-181` 执行 `UPDATE accounts SET tutorial_completed = 1 WHERE account_id = ?`；SQL `accounts.sql:1-10` 有列。未证明真实 driver/数据库可用。 |
| 账号读取路径 | CONDITIONAL | `tides_account.erl:149-169` 按 `account_id` SELECT；WS 账号身份来自连接 account map（`:549-553,580`）。数据库认证和跨重启读取未测。 |
| 游客不写账号 | PASS（源码路径） | 非 account identity 的 `complete_fact/1` 直接 `ok`（`tides_tutorial.erl:195-196`）；游客 status 返回 `{ok,false}`（`tides_ws_conn.erl:550-554`）。 |
| 游客本地隔离 | PASS（客户端键设计） | `main.ts:11-36` 按 `guest:${getPlayerToken()}` / `account:${accountName}` 分键；登录重置临时状态（`:136-145`），登出不合并游客记录（`:148-175`）。localStorage 篡改、清除和迁移行为未实测。 |
| 账号身份键 | CONDITIONAL | 服务端教程身份使用不可变 `account_id`（`tides_ws_conn.erl:580`）；但客户端本地键使用 `accountName`，且未提供真实跨账号/跨设备证据，故不能把全链路隔离判 PASS。 |

### 3.3 session_id、snapshot_version、恢复窗口、重玩、幂等

| 项目 | 结论 | 静态证据/风险 |
|---|---|---|
| session_id 归属匹配 | PASS（源码路径） | registry 以 identity 存储，`reconnect/3` 要求 identity 与 session_id 同时匹配（`tides_tutorial.erl:44-62`）。复制凭据和跨身份行为未 live 验证。 |
| 120 秒恢复窗口 | PASS（机制存在） | `GRACE_MS=120000`（`tides_tutorial.erl:10`），detach 后定时 expire，pid 未恢复则终止（`:76-82,142-149`）。窗口边界和过期响应未实测。 |
| 恢复最近稳定快照 | BLOCKED | 状态保存在 gen_server record `game/actions/stage`（`:11-12`），registry 为 ETS；没有数据库/磁盘快照。仅能推断同一进程存活时可恢复，不能证明刷新、服务端重启或未确认行动裁决。 |
| snapshot_version 单调 | CONDITIONAL | 服务端推进递增，客户端拒收旧版本；没有跨进程/持久化版本来源，乱序、多连接和重启语义未证明。 |
| 完成后重玩从 T1 | PASS（源码路径） | `tutorial_replay` 结束旧教程再 `start_tutorial`（`tides_ws_conn.erl:587-600`），新会话 `snapshot_version=1`、snapshot T1；旧完成事实不会被清除。完成账号/游客真实 fixture 未测。 |
| replay 请求幂等 | BLOCKED | `tutorial_replay` 不读取 action_id，也无 replay 去重表；重复点击/双设备可能发生多个新 session。该项直接对应 M3-W04，不能判 PASS。 |
| 完成幂等与原子性 | CONDITIONAL | 同一教程进程以 `actions` map 防止重复 action；T9 先调用持久化，成功后才置 `passed`（`tides_tutorial.erl:127-134`）。数据库失败、重试、响应丢失及跨重启未测，且无事务证据。 |

### 3.4 客户端状态恢复与错误处理

| 项目 | 结论 | 静态证据 |
|---|---|---|
| 账号先校验再查教程 | PASS（源码顺序） | `main.ts:352-365` 登录后发送 `tutorial_status`；session 恢复后 `:383-395` 同样查询状态。 |
| 恢复状态版本过滤 | PASS（源码） | `main.ts:437-449` 校验 session、有限版本并拒绝旧版本；状态应用后保存 session/version。 |
| 恢复遮罩与失败重开 | PASS（UI路径） | `main.ts:504-517,521-537,605-628` 进入恢复态，接受重连后等待完整 state，错误时清理恢复 session 并提供重试/重开；`tutorial.ts:200-212` 显示按钮。 |
| 静态手册与服务端完成区分 | PASS | `tutorial.ts:20` 明确静态阅读不代表 T1-T9；`main.ts:62-68,480-490` 分离本地完成和服务端完成。 |
| 客户端本地身份键稳定 | CONDITIONAL | 账号本地 key 使用名称而非服务端 account_id（`main.ts:13`），虽服务端事实按 ID，但名称变更/同名边界未定义，需 M4 前统一或明确约束。 |
| localStorage 异常处理 | BLOCKED | 代码直接调用 `localStorage.getItem/setItem/removeItem`，未见 try/catch 或配额/禁用/损坏专用处理；M3-A03 要求的浏览器故障未测，且静态上存在潜在异常风险。 |

### 3.5 正式流程回归证据

| 项目 | 结论 | 证据 |
|---|---|---|
| 历史正式回归 | PASS（历史证据，非本轮 M3 证据） | `acceptance_report_v0.3.2.md:52,62-68` 记录 eunit 18/18、sim 20/20、`robot.mjs` 真人/机器人冒烟、mem/stats 检查通过。 |
| 教程不污染正式统计 | BLOCKED | M3-G01/G02 需要教程完成/恢复/重玩前后 stats、排行榜和普通房帧对比；现有历史报告未覆盖教程流程。 |
| M2 教程固定任务回归 | BLOCKED | `new_player_tutorial_m2_cases.md:35-45,217-227` 全为待填写模板；本轮未执行 T1-T9 合法/非法/隐私流程。 |
| 当前构建/verify 结果 | CONDITIONAL | `server/verify.escript:5-18` 定义 eunit + easy/hard/normal 20 局模拟；既有报告有历史结果，但未见本轮针对当前教程代码的独立执行日志。客户端构建结果未见可引用的本轮产物路径。 |

## 4. 用例汇总（M3-P/I/R/W/A/G）

以下按 `tests/new_player_tutorial_m3_cases.md` 的 40 条用例给出静态验收状态。`PASS` 仅表示静态检查通过，不等同于行为验收通过。

| 分组 | PASS | CONDITIONAL | BLOCKED | NOT RUN | 说明 |
|---|---:|---:|---:|---:|---|
| M3-P01..P06 | 3 | 3 | 0 | 0 | 消息/字段/字符串路径可见；真实帧、异常和隐私未测 |
| M3-I01..I10 | 2 | 4 | 4 | 0 | SQL/服务调用可见；数据库、重启、设备和迁移实测阻塞 |
| M3-R01..R08 | 1 | 2 | 5 | 0 | session/窗口/客户端过滤部分可审；快照持久化、断线分支、乱序未覆盖 |
| M3-W01..W04 | 1 | 2 | 1 | 0 | 重玩入口/T1 可审；replay 幂等明确缺口 |
| M3-A01..A08 | 0 | 2 | 6 | 0 | 异常数据库、存储、并发和安全均无行为证据；replay/action 幂等有风险 |
| M3-G01..G04 | 1 | 1 | 2 | 0 | 历史正式回归可引用，但教程污染和 M2 全量未测 |
| **总计** | **8** | **14** | **18** | **0** | 静态分类，不是 39/40 条行为通过数 |

## 5. 明确跳过/未覆盖

本轮按用户决定跳过，以下全部不能写成 PASS：

- **M3 live：跳过。** 未运行 `node tests/new_player_tutorial_m3_smoke.mjs --live`，没有真实 WS 帧、时序、服务端错误或隔离证据。
- **MySQL 实测：未覆盖/阻塞。** `tests/mysql_readonly_report_2026-08-27.md:11-14` 记录无认证凭据、未发现 Erlang driver，schema 未验证；没有账号完成写入、读取、重启持久化证据。
- **浏览器实测：未覆盖。** 未验证刷新、关闭重开、跨设备、双标签、localStorage 禁用/配额满/损坏、游客清存储和身份切换。
- **教程完整 T1-T9：未覆盖。** 没有合法行动、非法行动、T9 写入失败、完成消息顺序或正式统计前后原始帧。
- **恢复故障注入：未覆盖。** 未验证 120 秒边界、服务端释放、ack 丢失、state 丢失、乱序、高延迟及多连接并发。
- **正式流程教程回归：未覆盖。** 历史 `robot`/eunit/sim/stats 结果不包含 M3 教程完成/恢复/重玩链路。

## 6. 阻塞与风险

1. **P0：进行中教程快照非持久化。** 会话状态、资源和 action 去重在教程 gen_server/ETS；服务端重启或进程终止后无法按 M3 要求恢复最近稳定点。证据：`server/src/tides_tutorial.erl:10-12,16-35,68-71`。
2. **P0：`tutorial_replay` 无请求幂等语义。** 协议要求重复重玩安全，代码没有 replay action_id、请求记录或并发裁决；证据：`shared/protocol.md:41`、`server/src/tides_ws_conn.erl:587-600`、`tests/new_player_tutorial_m3_cases.md:152-155`。
3. **P0：账号持久化尚未具备实测闭环。** SQL 和 UPDATE 路径存在，但 driver/凭据/schema/重启读取均未验证；不能宣称账号跨重启/跨设备通过。
4. **P0：客户端 localStorage 失败保护未见。** 直接读写 localStorage，M3-A03 要求的禁用、配额满和损坏场景没有静态防护或实测证据。
5. **P0：正式统计和 M2 回归没有教程专项证据。** 历史正式冒烟只能证明普通流程，不足以覆盖 M3-G01..G04。

## 7. 进入 M4 的前置建议

进入 M4 前建议先满足以下门槛；否则应继续以 M3 修复/验收工作处理，不应把 M4 当作已建立在 M3 PASS 之上：

1. 明确并实现教程恢复快照的存储边界：至少持久化账号所需的最近稳定阶段、资源、session/version、教程版本和 action 去重裁决；游客仍不得写账号事实。
2. 为 `tutorial_replay` 定义请求级幂等/并发裁决，覆盖重复点击、同 ID 改 payload、同账号双设备，并补充公开协议字段和错误语义。
3. 提供隔离 MySQL 凭据及兼容 Erlang driver，完成账号 A/B/C 的写入、读取、服务端重启、跨设备和不迁移证据；确认重复完成写安全且无半完成状态。
4. 为客户端 localStorage 读写增加安全降级策略，覆盖禁用、配额满、损坏和未知版本；账号事实始终优先，游客数据不可迁移。
5. 补跑并归档 live WS、浏览器、故障注入和正式回归原始证据，至少覆盖 M3 7.1/7.2 的账号重启、跨设备、游客清存储、未确认行动两支、T9 丢响应及并发 10 轮要求。
6. 完成 `M2-T01..T24` 的 P0 回归和 `M3-G01..G04`，再由测试 PM 更新行为验收报告；历史 `acceptance_report_v0.3.2.md` 只能作为普通流程基线。

## 8. 最终判定

| 验收域 | 静态结论 |
|---|---|
| 协议字段与教程路由 | PASS（静态） |
| 账号持久化路径 | CONDITIONAL，真实 MySQL/重启/跨设备 BLOCKED |
| 游客隔离 | PASS（源码路径），浏览器行为 BLOCKED |
| session/version/恢复 | CONDITIONAL；持久化恢复和断线行为 BLOCKED |
| 重玩/幂等 | CONDITIONAL；replay 幂等为 P0 BLOCKED 风险 |
| 客户端恢复/错误处理 | CONDITIONAL；版本过滤和错误 UI PASS，存储故障 BLOCKED |
| 正式流程回归 | CONDITIONAL（历史普通流程 PASS），教程专项 BLOCKED |
| **M3 总结** | **CONDITIONAL，不得发布为 M3 已验收 PASS** |
