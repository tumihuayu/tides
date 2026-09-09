# 登录/登出功能测试计划 v1.0

> 日期：2026-09-03；负责：测试PM agent；范围：register / login / logout / session 四协议 + 客户端身份入口
> 依据：docs/08_account_system_and_dev_reset_v1.0.md（策划唯一口径）、现有代码勘察

## 1. 需求拆解

按"网上常规游戏做法"+ 策划冻结口径，登录/登出包含：

1. 注册：账号名+密码，校验格式，重复名拒绝，注册成功自动登录并下发 session。
2. 登录：账号名+密码，错误凭据统一返回 `invalid_credentials`（不区分"不存在"与"密码错"，防枚举）。
3. 登出：撤销服务端 session（ETS + MySQL `sessions.revoked=1`），连接回到未认证态，客户端清除本地 session 并回登录页。
4. 会话恢复：客户端持 localStorage session，刷新/断线重连后用 `session` 消息恢复身份。
5. 多设备：允许同账号多连接同时登录（不互踢）；同账号单房间限制由 `already_in_room` 保证（已有，非本期范围但需回归）。
6. 游客：纯客户端教程，无服务端会话（已有，需回归不受登录改动影响）。

## 2. 现状分诊

### 服务端（server/）— 主体已实现，含 2 个疑似缺陷

已实现：
- `tides_account.erl`：register/login/logout/session/role 完整；PBKDF2-SHA256(120k) 盐哈希；session 30 天有效；MySQL 主库 + ETS 缓存；`session_mysql` 可从库恢复（含 revoked/expiry 校验）。
- `tides_ws_conn.erl:380-619`：四类消息路由齐全；`auth_required` 门禁覆盖建房/入房/重连/战绩/排行榜；错误码完整（invalid_credentials / name_too_short / password_too_short / account_exists / already_authenticated / not_authenticated 等）。
- `tides_sup.erl` 已挂 tides_account（permanent）。

疑似缺陷（需后端 agent 确认修复）：
- **S1（高）**：`tides_account.erl:88-91` MySQL 未启用时 `logout` 返回 `{error, mysql_not_configured}`，但 `tides_ws_conn.erl:569` 用 `ok = tides_account:logout(Session)` 匹配 → 连接进程直接崩溃。与今日两份 erl_crash.dump（根目录 16:45、server/ 16:54）时间吻合，疑似半成品会话中断原因。
- **S2（中）**：`tides_ws_conn.erl:570` 登出时 `maps:get(player_pid, St, undefined)` 取的是连接 State 顶层，但 `player_pid` 实际存于 `account` map 内 → detach 永远走不到，登出后 PlayerProcess 可能仍挂接旧连接。
- **S3（低）**：并发注册同名账号时，双方都可能先 `lookup_user` not_found 再 insert，撞 UNIQUE 的一方拿到的是裸 MySQL 错误而非 `account_exists`，错误码不稳定。
- **S4（低/性能）**：tides_account 为单 gen_server，login 内做 120k 轮 PBKDF2，并发登录全部串行排队（30s call 超时）。本期可接受，需记录。

### 客户端（client/）— 主体已实现，含 1 个小缺陷

已实现：
- `lobby.ts:166-218`：登录/注册表单、确认密码、游客入口、登出按钮、身份状态标签。
- `main.ts:127-136` setAuthenticated、`363-401` logged_in/account_registered/logged_out/session 处理；`516-541` 账号错误码 → 中文提示映射完整。
- `net.ts:110-112` session 持久化；`main.ts:580-588` 重连 hook 自动发 `session` 恢复身份 + 房间 reconnect。
- 房间内登出被客户端拦截 + 服务端 `already_in_room` 双重防护。

缺陷/缺口：
- **C1（低）**：`main.ts:210-211` `net.send('logout', {}) === null`（连接断开）时为空 if，无任何提示或本地状态回退，用户点登出没反应。
- **C2（低）**：`net.ts:233-234` 每条消息附带 `account_session` 字段，服务端从不读取（grep 仅 390/581 两处路由）→ 事实上的死字段；要么服务端校验，要么客户端停发，需主协调在协议中定性。

### 协议文档（shared/protocol.md）— 缺失，主协调负责

- 仅在第 19、147、148 行提及"account_session 鉴权口径"与"注册后自动建 session"，**消息表中没有** `register`/`login`/`logout`/`session` 请求与 `account_registered`/`logged_in`/`logged_out`/`session` 响应的条目，错误码表也没有账号类错误码。
- 需补：4 条请求 + 4 条响应的字段表、错误码清单、登出/失效语义、"多设备登录不互踢"与"同账号单房间"交叉引用。

### 测试（tests/）— 冒烟认证已具备，负路径缺失

- `robot.mjs` 已支持 `TEST_ACCOUNTS`（account_name/password 或 session）认证，可作为正向回归基底。
- `identity_lifecycle_skeleton.mjs` 7 个用例全部 BLOCKED（等最终契约），其中 ROLE-06 覆盖登录/登出/过期生命周期。
- 缺口：**无任何针对登录/登出负路径与生命周期的可执行冒烟**（错误密码、不存在账号、重复登录、登出后 session 失效、并发登录）。
- 前置依赖：登录注册强依赖 MySQL（mysql_not_configured 时 register/login/logout 全部失败/崩溃），测试环境必须先起 MySQL 并应用 `server/sql/accounts.sql` + `migrations/001`。

## 3. 验收标准（逐条可验证）

| 编号 | 场景 | 步骤 | 期望 |
|---|---|---|---|
| LG-01 | 正常注册 | ws 发 `register` 合法账号名(3-64字符,[A-Za-z0-9_-])+密码(8-256) | 收 `account_registered`，含 session/account_id/account_name/role_id；MySQL accounts 有该行，hash≠明文 |
| LG-02 | 正常登录 | 注册后新连接发 `login` 正确凭据 | 收 `logged_in`，含 session/role_id；随后 `list_rooms` 成功 |
| LG-03 | 错误密码 | `login` 正确名+错误密码 | 收 `error` code=`invalid_credentials`，不泄露"密码错" |
| LG-04 | 不存在账号 | `login` 未注册名 | 收 `error` code=`invalid_credentials`，与 LG-03 文案一致（防枚举） |
| LG-05 | 重名注册 | 同名二次 `register` | 收 `error` code=`account_exists` |
| LG-06 | 格式校验 | 名过短/过长/非法字符、密码过短/过长 | 分别收 name_too_short / name_too_long / name_invalid_chars / password_too_short / password_too_long |
| LG-07 | 同连接重复登录 | 已认证连接再发 `login`/`register` | 收 `error` code=`already_authenticated`，原 session 不受影响 |
| LG-08 | 正常登出 | 已登录连接发 `logout` | 收 `logged_out`；MySQL sessions.revoked=1；连接回未认证态 |
| LG-09 | 登出后 session 失效 | 新连接用 LG-08 已登出的 session 发 `session` | 收 `session` authenticated=false |
| LG-10 | 登出后旧 session 不能建房 | LG-09 的连接发 `create_room` | 收 `error` code=`authentication_required`，不产生房间 |
| LG-11 | 登出后同连接不能建房 | 原连接（已 logged_out）发 `create_room` | 同上 `authentication_required` |
| LG-12 | 未认证直接登出 | 未登录连接发 `logout` | 收 `error` code=`not_authenticated` |
| LG-13 | 断线重连 session 恢复 | 登录后断线重连，发 `session` 带原 token | 收 `session` authenticated=true + role_id；`get_my_stats` 可用 |
| LG-14 | 伪造/过期 session | 发 `session` 带随机 64 hex token | authenticated=false |
| LG-15 | 并发登录（多设备） | 两条连接同时 `login` 同账号 | 均收 `logged_in`，session 不同，role_id 相同；不互踢 |
| LG-16 | 并发注册同名 | 两条连接同时 `register` 同名 | 恰好一条 `account_registered`，另一条收 error（稳定为 `account_exists`，若修 S3） |
| LG-17 | 房间内禁止登出/登录 | 入房后发 `logout`/`login` | 收 `already_in_room`，房间席位不变 |
| LG-18 | 游客回归 | 无 session 直接 `create_room`/`list_rooms` | 收 `authentication_required` |
| LG-19 | MySQL 未启用降级 | 停 MySQL 后发 `login`/`logout` | 收明确 error 且**连接不崩溃、无 erl_crash.dump**（验证 S1 修复） |
| LG-20 | 服务端重启后 session 恢复 | 登录→重启服务端→新连接发 `session` | 从 MySQL 恢复，authenticated=true |

客户端手工/UI 验收：

| 编号 | 场景 | 期望 |
|---|---|---|
| UI-01 | 登录表单提交 | 成功后进大厅，显示"当前账号：xxx"与登出按钮；localStorage `tides_account_session` 已写 |
| UI-02 | 刷新页面 | 自动用本地 session 恢复，直接进大厅，无需重输密码 |
| UI-03 | 登出按钮 | 回登录页，localStorage session 已清；再刷新不自动登录 |
| UI-04 | 服务端 session 被撤销后刷新 | 提示"会话已失效，请重新登录"，本地 session 被清 |
| UI-05 | 错误密码/不存在账号 | 提示统一为"账号名或密码错误。" |
| UI-06 | 断网时点登出 | 有明确提示（验证 C1 修复），不得无反应 |

## 4. 测试方式

- **新建 `tests/login_logout_smoke.mjs`**（主要交付物）：独立 ws 冒烟，覆盖 LG-01~LG-20 全部协议用例；账号名加时间戳前缀避免脏数据；依赖环境变量 `WS_URL`（默认 ws://127.0.0.1:9500/ws）与 `TEST_MYSQL_DSN`/现有注入方式做 revoked/expiry 断言（LG-08/LG-20）；MySQL 不可用时 LG-08/LG-20 标 BLOCKED 而非 FAIL（与 identity_lifecycle_skeleton.mjs 退出码 2 约定一致）。
- **复用 `robot.mjs`**：LG-02/LG-13 的正向回归已由其实名认证覆盖，跑一局 4 账号冒烟即回归；新增 `--bots=1` 场景验证"账号+bot"不受登录改动影响。
- **`identity_lifecycle_skeleton.mjs`**：协议文档补齐后，将 ROLE-06 从 BLOCKED 落地为引用 login_logout_smoke 结果。
- **UI-01~06**：手工验收清单，纳入 `acceptance_checklist.md` 下一轮。
- 运行前提：MySQL 已启动且应用 accounts.sql + migrations/001；服务端 `erl -noshell -eval "make:all()"` 编译通过；冒烟前删除既有 erl_crash.dump 以便观察新崩溃。

## 5. 风险点

1. **S1 崩溃优先**：当前 MySQL 掉线时点登出即崩连接进程，可能正是今日 erl_crash.dump 来源；修复前任何登出用例（LG-08~12）都不稳定，必须后端先修。
2. **并发语义依赖 MySQL 约束**：LG-15/LG-16 正确性靠 UNIQUE 与 revoked 更新，ETS 缓存与库不一致（重启、多节点）是薄弱面；本期单节点可接受。
3. **登录串行化**：单 gen_server + 120k PBKDF2，压测/批量机器人登录会排队；robot 4 账号尚可，更大并发需关注 30s call 超时。
4. **测试环境污染**：冒烟会产生真实账号/session 行，需约定前缀并建议配合开发清档（docs/08 §5）执行。
5. **协议未定稿**：shared/protocol.md 补齐前，错误码/字段名以代码现状为准固化为测试断言；文档与代码冲突时以策划文档 + 代码为准并回报主协调。
6. **session 30 天过期无法用例化**：LG-14 只覆盖伪造 token；真实过期需 DB 改 expires_at 或等后端提供测试钩子，暂列手工项。
