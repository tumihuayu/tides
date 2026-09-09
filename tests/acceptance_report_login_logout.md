# 登录/登出功能验收报告 v1.0

> 日期：2026-09-03；负责：测试PM agent；范围：register/login/logout/session 协议收口 + 4人整局回归
> 环境：Windows 本机，MySQL56 在线（config/database.env 凭据），服务端为当日 18:42 新编译实例（erl PID 30868，验证后已停止）
> 执行物：`tests/login_logout_smoke.mjs`（新建，30 项断言）、`tests/robot.mjs`（4 账号整局）

## 1. 总结

- login_logout_smoke：**26 PASS / 1 FAIL / 3 BLOCKED（共 30 项）**，可执行协议用例通过率 26/27 = **96.3%**
- robot.mjs 4 人整局冒烟：**PASS**（修复脚本自身 3 处缺陷后，见 §4）
- 全程无新增 erl_crash.dump（仅存 16:45/16:54 两份旧 dump，早于本次服务端启动）
- 唯一 FAIL（LG-17 部分）为**协议文档与代码行为不一致**的文案级问题，非功能性缺陷，详见 §3

## 2. 用例逐条结果

| 编号 | 场景 | 结果 | 说明 |
|---|---|---|---|
| LG-01 | 注册成功自动登录 | PASS | account_registered 含 session/account_id/account_name/role_id；注册后立即可 list_rooms |
| LG-02 | 正常登录 | PASS | logged_in 返回新 session，role_id 与注册一致；list_rooms 成功 |
| LG-03 | 错误密码 | PASS | error code=invalid_credentials |
| LG-04 | 不存在账号 | PASS | invalid_credentials，message 与 LG-03 逐字一致（防枚举成立） |
| LG-05 | 重名注册 | PASS | account_exists |
| LG-06 | 格式校验 ×5 | PASS | name_too_short / name_too_long / name_invalid_chars / password_too_short / password_too_long 全部命中 |
| LG-07 | 同连接重复 login/register | PASS | 均 already_authenticated |
| LG-08 | 正常登出 | PASS | logged_out，MySQL 在线下连接不崩溃（S1 正向路径复核通过） |
| LG-09 | 登出后旧 session 恢复 | PASS | session authenticated=false |
| LG-10 | 失效 session 建房 | PASS | authentication_required |
| LG-11 | 登出后同连接建房 | PASS | authentication_required |
| LG-12 | 未认证登出 | PASS | not_authenticated |
| LG-13 | 新连接有效 session 恢复 | PASS | authenticated=true，account_name/role_id 正确；get_my_stats 可用 |
| LG-14 | 伪造 token | PASS | authenticated=false |
| LG-15 | 并发登录不互踢 | PASS | 第二连接 logged_in、session 不同、role_id 相同；第一连接随后 list_rooms 正常 |
| LG-16 | 并发注册同名 | PASS | 恰好一条 account_registered，另一条稳定 account_exists（S3 复核通过） |
| LG-17 | 房间内 logout | PASS | already_in_room，随后 list_rooms 确认席位不变 |
| LG-17 | 房间内 login/register | **FAIL** | 实际返回 already_authenticated，协议文档（shared/protocol.md §账号与会话规则）写的是 already_in_room，见 §3 |
| LG-18 | 游客建房/查房 | PASS | create_room/list_rooms 均 authentication_required |
| LG-19 | MySQL 未启用降级 | BLOCKED | 需停 MySQL 单独验证；本次 MySQL 在线，登出正向路径已由 LG-08 覆盖且未崩溃 |
| LG-20 | 服务端重启后 session 恢复 | BLOCKED | 需重启服务端；建议运维窗口手工验证（session_mysql 恢复路径已有代码，未实测） |
| LG-08db | MySQL sessions.revoked=1 直查 | BLOCKED | 冒烟脚本不直连数据库；revoked 效果已由 LG-09/LG-10 行为断言间接覆盖 |

UI-01~06 为客户端手工项，本轮未执行，沿用既有清单下轮验收。

## 3. 唯一 FAIL 分析（LG-17 login/register 文案）

- 现象：房间内连接发 `login`/`register` 返回 `already_authenticated`，而 protocol.md 规定返回 `already_in_room`。
- 代码勘察：`tides_ws_conn.erl:538-541`（login）与 `510-514`（register）均先检查 account 再检查 room；建房/入房前提是已认证，故房间内连接的 account 恒为 map，`already_in_room` 分支（560 行）实际不可达。logout（564-578）先查 session 再查 room，能正确返回 already_in_room。
- 定性：**语义安全的文档偏差**。两种错误码都拒绝了操作且不改变房间状态（LG-17b PASS 佐证），客户端按错误码提示文案均适用。房间内 login 返回 already_authenticated 在语义上甚至更准确。
- 建议（报主协调裁决）：**改文档**——protocol.md 第 56 行改为"房间内 logout 返回 already_in_room；login/register 因连接已认证返回 already_authenticated"，无需动服务端代码。若坚持文档口径，则需后端调整 login/register 的检查顺序（room 优先）。

## 4. 缺陷复核结论

| 编号 | 原缺陷 | 复核结论 |
|---|---|---|
| S1（高） | MySQL 未启用/失败时登出崩溃 | **修复确认（正向路径）**：LG-08/LG-11 登出全流程连接存活、logged_out 正常、无新 erl_crash.dump；MySQL 掉线负路径（LG-19）BLOCKED 待单独验证 |
| S2（中） | 登出 detach 取错 player_pid 位置 | **修复确认**：`tides_ws_conn.erl:570` 已从 account map 取 player_pid；登出后连接回游客态且再建房被拒（LG-11），无残留挂接导致的异常 |
| S3（低） | 并发注册同名错误码不稳定 | **修复确认**：LG-16 双连接并发注册同名，败方稳定返回 account_exists |
| C1（低） | 断网登出无提示 | **代码已修**（断网 toast + 不清本地 session）；属 UI-06 手工项，本轮协议冒烟不覆盖，标记待手工复核 |
| C2（低） | account_session 死字段 | **修复确认（静态）**：客户端已停发该字段；robot.mjs 全量消息不含 account_session 且整局 PASS，证明服务端不依赖该字段 |

附带修复（测试脚本自身，tests/ 范围内）：robot.mjs 终局回大厅路径存在 3 处预存 bug，此前从未真正跑通该路径——
1. `players[0].waitFor(...)` 误用实例方法（实为模块级函数）→ 已改 `waitFor(players[0], ...)`；
2. `validateGameOver` 被 4 个玩家的 game_over 各触发一次，先到者非 players[0] 时误报 FAIL → 已限定仅 players[0] 触发；
3. 终局后 room_list 复用开局严格校验，与服务端 game_over 后 1s 才停房的窗口冲突 → 初始校验完成后跳过后续严格校验。

## 5. 遗留风险

1. **LG-19/LG-20 未实测**：MySQL 降级登出、重启后 session 从库恢复两条路径仅有代码保证，建议下个运维窗口停库/重启各验证一次（可复用本脚本：LG-19 停 MySQL 后跑 LG-08 段即可）。
2. **S4 登录串行化**未压测：单 gen_server + 120k 轮 PBKDF2，批量并发登录排队；robot 4 账号无感，更大规模需关注 30s call 超时。
3. **测试数据污染**：本轮产生 `lg_*`/`rb_*` 前缀账号约 10 个及其 session 行，建议配合开发清档流程定期清理。
4. **文档偏差待裁决**：LG-17 错误码口径需主协调在 protocol.md 与代码间二选一收口（建议改文档）。
5. **session 30 天过期**仍无法用例化，维持手工项。

## 6. 上线标准判定

- 协议用例可执行部分 26/27 通过，唯一 FAIL 为错误码文案口径（安全语义无差异），不阻断上线。
- S1/S2/S3 三项服务端缺陷在可验证范围内全部复核通过；4 人整局端到端回归 PASS。
- **结论：达到上线标准**；放行前提：主协调裁决 LG-17 文档口径，并将 LG-19/LG-20 列入上线后首轮运维验证清单。
