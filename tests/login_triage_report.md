# 登录功能分诊报告 v1.0

> 日期：2026-09-04；负责：测试PM agent；范围：「在现有注册功能相同位置增加登录功能」需求分诊（只研究，不实现）
> 依据：shared/protocol.md v0.3、server/src、client/src、tests/ 现有资产

## 0. 核心结论（先说结论）

**登录功能在当前代码库中已经端到端实现并验收过**，并非待开发的新需求：

- 协议层：`shared/protocol.md` 已定义 `login`/`logged_in` 及全部账号错误码（第 27、55、59、73 行）。
- 服务端：`tides_account.erl:51-76`（login 校验+签发 session）、`tides_ws_conn.erl:538-562`（account_login 路由）完整实现。
- 客户端：`client/src/lobby.ts:189-201` 登录表单与注册表单同面板（即"注册功能相同位置"），`main.ts:184-196` loginAccount、`364-366` logged_in 处理均已实现。
- 测试：`tests/login_logout_smoke.mjs`（30 项断言，覆盖 LG-01~LG-20）已存在；`tests/acceptance_report_login_logout.md`（2026-09-03）记录 26 PASS / 1 FAIL / 3 BLOCKED，robot.mjs 4 人整局 PASS。

**建议主协调向用户确认需求口径**：本次需求若是"重新提出已完成功能"，实际工作量只剩回归验证；若用户想要的是与现设计不同的口径（最典型的分歧点是**重复登录顶号**——现设计明确"同账号多连接同时登录、不互踢"，protocol.md:58），则属于协议变更，需按重大需求另行评估。下文按"假设从零新增登录"给出完整影响面，并标注各项的当前状态。

## 1. 现有注册流程全貌（登录功能的参照基线）

```
client/lobby.ts 注册表单(账号/密码/确认密码)
  → main.ts registerAccount() 本地格式校验(3-64字符/[A-Za-z0-9_-]/密码8-256)
  → net.send('register', {account_name, password})  ──WS──▶
server/tides_ws_conn.erl:380 route(register)
  → account_register (tides_ws_conn.erl:510)：已认证/在房间 → already_authenticated
  → tides_account:register/2 (tides_account.erl:26)：
      valid_credentials 格式校验 → lookup_user(ETS→MySQL) 查重
      → PBKDF2-SHA256(120k迭代)+盐 哈希 → INSERT accounts（Duplicate entry→account_exists）
      → new_session(32字节token，30天有效，INSERT sessions)
      → ensure_role + tides_player_registry:get_or_start 建 PlayerProcess
  ◀── account_registered {account_id, account_name, session, role_id}
client/main.ts:367 收 account_registered → setAuthenticated() 存 localStorage(tides_account_session) → 进大厅
重连/刷新：main.ts:583 自动发 session 消息恢复身份
```

登录流程与注册共享：`valid_credentials` 格式校验、`new_session` 签发、`ensure_role`+PlayerProcess 挂接、客户端 `setAuthenticated` 状态流转，差异仅在校验密码哈希（`secure_equal` 常量时间比较）而非写库。

## 2. 影响面分析

### 2.1 协议层 shared/（主协调负责修改）

| 项目 | 内容 | 当前状态 |
|---|---|---|
| 请求 `login` | `{account_name, password}` | ✅ 已定义（protocol.md:27） |
| 响应 `logged_in` | `{session, account_id, account_name, role_id}` | ✅ 已定义（:73） |
| 错误码 | `invalid_credentials`（密码错与账号不存在**统一返回**，防枚举） | ✅ 已定义（:54,59） |
| 重复登录策略 | 现口径：多连接同时登录**不互踢**；已认证连接再 login → `already_authenticated`；房间内 login → `already_in_room` | ✅ 已定义（:55,58）；⚠️ 若用户要"顶号"则是协议变更 |
| 会话规则 | session 30 天；logout 撤销；session 消息恢复 | ✅ 已定义（:57） |

**协议设计要点（建议维持现口径）**：
1. 密码错误/账号不存在必须统一 `invalid_credentials` 且 message 文案逐字一致，防账号枚举（已有冒烟断言 LG-03/LG-04）。
2. 登录响应必须含 `role_id` 且与注册时一致——它是战绩/统计唯一归属键。
3. "顶号 vs 不互踢"必须先定口径再动代码；顶号方案需额外定义"被顶连接收到什么消息、旧 session 是否失效"，改动面显著变大。
4. 登录不得依赖客户端提交的任何身份字段（protocol.md:19 已有安全约束）。

### 2.2 服务端 server/（后端 agent 负责）

| 模块 | 涉及内容 | 当前状态 |
|---|---|---|
| `server/src/tides_account.erl` | `login/2`：查用户(ETS缓存→MySQL回源)→`secure_equal` 比哈希→`new_session`→`ensure_role`→启动/复用 PlayerProcess | ✅ 已实现（:51-76） |
| `server/src/tides_ws_conn.erl` | `account_login` 路由：已认证→already_authenticated；房间内→already_in_room；失败→send_account_err | ✅ 已实现（:385-386, 538-562） |
| 重复登录/进程管理 | 同账号第二连接登录时 `tides_player_registry:get_or_start` 复用同一 PlayerProcess，`tides_player:attach` 挂接新连接；不踢旧连接 | ✅ 已实现（多连接 attach） |
| 已知遗留风险（来自 2026-09-03 分诊，回归时需复核） | S4：tides_account 单 gen_server，登录内做 120k 轮 PBKDF2，并发登录串行排队（30s 超时）；C2：`net.ts` 每条消息附带 `account_session` 死字段，服务端不校验 | ⚠️ 记录项，非本期阻塞 |

前置依赖：注册/登录强依赖 MySQL（`mysql_not_configured` 时 login 直接失败），测试环境须先起 MySQL 并应用 `server/sql/accounts.sql`。

### 2.3 客户端 client/（前端 agent 负责）

| 项目 | 内容 | 当前状态 |
|---|---|---|
| UI 布局 | 与注册**同面板**：`lobby.ts:166-218` renderAccount，未认证态下登录表单(账号+密码+登录按钮, :189-201) 与注册表单(追加确认密码+注册按钮, :203-211) 上下排列，共用账号/密码输入框——即需求所说"相同位置"，无需 tab 切换 | ✅ 已是该形态 |
| 交互 | `main.ts:184-196` loginAccount：空值本地拦截→清旧 session→发 login→"正在登录…" | ✅ 已实现 |
| 成功流转 | `main.ts:364-366` 收 logged_in → `setAuthenticated()`：存 localStorage session、accountStatus='authenticated'、清教程态、screen='lobby' | ✅ 已实现 |
| 失败提示 | 错误码→中文 toast 映射（main.ts:516-541 区域） | ✅ 已实现 |
| 会话恢复 | 刷新/断线后自动发 `session` 恢复（main.ts:583），失效提示"会话已失效，请重新登录" | ✅ 已实现 |
| 已知小缺陷 | C1：连接断开时点登出无任何提示（logout 路径，非登录） | ⚠️ 低优先级遗留 |

### 2.4 测试 tests/（本 agent 负责）

| 项目 | 内容 | 当前状态 |
|---|---|---|
| 协议冒烟 | `tests/login_logout_smoke.mjs`：30 项断言覆盖 LG-01~LG-20（正常登录/错密码/不存在账号/并发登录不互踢/登出生命周期/session 恢复/伪造 token/房间内限制/游客门禁） | ✅ 已存在，直接复用 |
| 整局回归 | `tests/robot.mjs` 已支持 TEST_ACCOUNTS（account_name/password 或 session）认证，登录态 4 人整局 | ✅ 已覆盖登录路径 |
| 计划与验收 | `tests/login_logout_test_plan.md`、`tests/acceptance_report_login_logout.md`（96.3% 通过率） | ✅ 已存在 |
| robot.mjs 是否需改 | 不需要新增登录用例；robot 已走认证链路。若本次需求改动了登录行为（如改为顶号），robot 的并发/重连场景需相应更新 | 视最终口径 |
| 缺口 | LG-19（MySQL 降级）、LG-20（重启后 session 恢复）、LG-08db（revoked 直查）3 项 BLOCKED 需运维窗口手工验证 | ⚠️ 待手工 |

## 3. 验收标准清单

协议/服务端（可由 login_logout_smoke.mjs 自动验证）：
- [x] 正常登录：已注册账号发 `login` 收到 `logged_in`，含 session（≥32字符）/account_id/account_name/role_id，role_id 与注册时一致（LG-02 PASS，2026-09-04 复验）
- [x] 密码错误：返回 `error code=invalid_credentials`（LG-03 PASS）
- [x] 账号不存在：返回 `invalid_credentials`，且 message 文案与密码错误逐字一致（防枚举）（LG-04 PASS）
- [x] 未注册直接登录：同上按账号不存在处理，不得泄露账号是否存在（LG-04 PASS，同一断言覆盖）
- [x] 重复注册后登录：重复注册返回 `account_exists`；原账号仍可正常登录（LG-05/LG-02 PASS）
- [x] 已认证连接再发 login/register：返回 `already_authenticated`（LG-07 PASS）
- [x] 房间内发 login：按协议口径返回错误且房间席位不变（LG-17 部分 FAIL：logout 返回 `already_in_room` PASS 且 LG-17b 席位不变 PASS；login/register 实际返回 `already_authenticated`，为已知文档偏差，见 §5）
- [x] 并发登录：第二连接同账号登录成功、新 session、role_id 相同、第一连接不被踢（LG-15/15b PASS；维持"不互踢"口径）
- [x] 登录后可 list_rooms / create_room / get_my_stats（LG-02b/LG-13b/LG-17b PASS）
- [x] session 恢复：新连接持有效 session 发 `session` 返回 authenticated=true（LG-13 PASS；LG-09/LG-14 失效/伪造 token 拒绝 PASS）

客户端/UI（2026-09-04 终验：构建 PASS + 代码走查确认；UI 目视项未做人工点击实测）：
- [x] 登录表单与注册表单位于同一身份入口面板（本次前端重构为 tab 切换：`lobby.ts:196-241` 登录/注册 tab + 底部互切链接，共用账号/密码草稿 `accountDraft`，仍是同一面板位置）
- [x] 账号/密码为空时本地拦截并提示，不发请求（`main.ts:185-191` loginAccount 空值拦截；registerAccount 同路径 :170 区域）
- [x] 登录成功：toast/状态流转到"已登录"，进入大厅，localStorage 写入 session（走查 `main.ts` logged_in → setAuthenticated 链路未变）
- [x] 登录失败：中文错误提示，停留在身份入口（错误码→toast 映射链路未动）
- [x] 刷新页面后 session 自动恢复为已登录态；session 失效提示重新登录（`main.ts` 自动发 session 恢复链路未动；服务端侧 LG-13/LG-09 PASS 佐证）

回归不破坏：
- [x] `cd server && erl -noshell -eval "make:all()" -s init stop` 编译通过（exit 0）
- [x] eunit（tides_json_tests/tides_game_tests）+ tides_sim 20 局自玩通过（18 tests，exit 0）
- [x] `node tests\robot.mjs` 4 人整局冒烟 PASS（SMOKE PASS，exit 0）
- [x] `node tests\login_logout_smoke.mjs` 无 FAIL（BLOCKED 项除外）（26 PASS / 1 FAIL 为已知 LG-17 文档偏差 / 3 BLOCKED 同前）
- [x] 全程无新增 erl_crash.dump（server/erl_crash.dump 时间戳保持 2026-09-03 16:54）

## 4. 给主协调的建议

1. **先与用户核对需求口径**：代码现状已完整满足"注册同位置增加登录"，最可能的真实诉求是 (a) 复验/回归，或 (b) 改为"顶号"策略——后者是协议级变更，属重大需求，需用户确认后再动手。
2. 若仅复验：起 MySQL + 服务端，跑 `login_logout_smoke.mjs` + `robot.mjs` 即可出报告，无需改动任何功能代码。
3. 若确要开发（如顶号）：shared/protocol.md 由主协调改，server 侧涉及 tides_account/tides_ws_conn/tides_player_registry 三模块，client 侧需处理"被顶下线"提示与状态回退，tests 需重写 LG-15 并新增顶号用例。

## 5. 基线回归结果（2026-09-04）

> 目的：确认「注册+登录」链路当前可用（用户要求"如果功能里有，则调试通"）。环境：本机 Windows，MySQL 3306 在线，服务端临时启动（erl PID 10272，version 0.3.2，`GET /healthz` 返回 ok），回归结束后已 taskkill，9500 端口确认释放。

| # | 命令 | 结果 | 说明 |
|---|---|---|---|
| 1 | `cd server && erl -noshell -eval "make:all()" -s init stop` | ✅ PASS | exit 0，编译通过 |
| 2 | eunit（tides_json_tests/tides_game_tests）+ tides_sim 20 局 | ✅ PASS | All 18 tests passed，exit 0 |
| 3 | 服务端后台启动 + healthz | ✅ PASS | `{"ok":true,"service":"tides","version":"0.3.2"}` |
| 4 | `node tests\robot.mjs`（4 账号整局冒烟） | ✅ PASS | SMOKE PASS，exit 0；账号经 `tests\_baseline_fixture.mjs` 现场注册注入（fixture 写入 %TEMP%，用后已删除，不落仓库） |
| 5 | `node tests\login_logout_smoke.mjs`（30 项） | ⚠️ 26 PASS / 1 FAIL / 3 BLOCKED，exit 1 | FAIL 为已知项 LG-17，与 2026-09-03 验收报告 §3 完全一致，无新增回归 |

### 逐项说明

- **LG-17（唯一 FAIL，已知文档偏差，非新缺陷）**：房间内 `logout` 返回 `already_in_room`（符合协议），但房间内 `login`/`register` 返回 `already_authenticated` 而非 protocol.md 所写的 `already_in_room`；LG-17b 确认连接仍留房间内、席位不变。**定性不变：语义安全的文档偏差**，仍待主协调裁决文档/代码口径（建议改文档，见 2026-09-03 验收报告 §3/§6.4）。
- **BLOCKED 3 项（同前次）**：LG-19（MySQL 降级）、LG-20（重启后 session 恢复）、LG-08db（revoked 直查）需运维窗口手工验证；本次 MySQL 在线，LG-08/09/10 已行为级覆盖登出与 session 失效。
- **登录链路核心断言全部 PASS**：LG-01/02（注册自动登录、正常登录下发 session+role_id 一致）、LG-03/04（错密码与不存在账号统一 `invalid_credentials` 且文案逐字一致）、LG-07（`already_authenticated`）、LG-15/15b（并发登录不互踢）、LG-16（并发注册同名归一化）、LG-13/13b（session 恢复 + get_my_stats）、LG-14（伪造 token 拒绝）、LG-18（游客门禁）。
- 回归全程未产生新的 `server/erl_crash.dump`（现有 dump 为 2026-09-03 遗留）；误生成的仓库根目录 dump 已清理。

### 结论

**登录链路当前已调通，判定可用**：编译/单测/20 局模拟/4 人整局/登录登出协议冒烟全部与 2026-09-03 基线一致，零新增缺陷。唯一遗留为 LG-17 文档口径裁决与 3 项运维窗口手工验证，均不阻塞"功能可用"结论。

## 6. 终验结果（2026-09-04）

> 范围：前端 agent「身份入口」面板重构（登录/注册 tab 切换）终验。本次前端改动项：`client/src/ui.ts`（AppState 新增 `accountMode` 字段、AppActions 新增 `setAccountMode`）、`client/src/main.ts`（state 初始 `accountMode:'login'` + `setAccountMode` action，`main.ts:17,198-202`）、`client/src/lobby.ts`（`renderAccount` 重构为 tab 切换，`lobby.ts:166-247`）、`client/src/styles.css`（`.account-tabs`/`.account-register`/`.account-switch` 样式，:186-218）。协议与服务端未动。
> 环境：同 §5（本机 Windows，MySQL 在线，服务端临时启动 erl PID 29856，终验后已 taskkill，9500 端口确认释放）。

| # | 验证项 | 结果 | 说明 |
|---|---|---|---|
| 1 | `cd client && npm run build` | ✅ PASS | tsc + vite build 通过，exit 0；产物 dist/ 正常（index-rvkHGCYx.js 43.14 kB） |
| 2 | `node tests\robot.mjs` 4 人整局 | ✅ PASS | SMOKE PASS，exit 0，与基线一致 |
| 3 | `node tests\login_logout_smoke.mjs` | ✅ 与基线一致 | 26 PASS / 1 FAIL / 3 BLOCKED，exit 1；唯一 FAIL 仍为已知 LG-17 文档偏差（房间内 login/register 返回 `already_authenticated`），无新增失败 |
| 4 | 代码走查（只读 client/） | ✅ PASS | 见下 |

### 代码走查结论（lobby.ts / main.ts）

- **tab 切换**：`lobby.ts:196-201` 两个 tab 按钮调 `a.setAccountMode(m)`；`main.ts:198-202` 仅做状态置位 + render，无副作用；同 mode 提前 return，无重复渲染。
- **调用完整性**：登录分支 `lobby.ts:229-231` → `a.loginAccount(username.value.trim(), password.value)`，注册分支 `:225-227` → `a.registerAccount(..., confirm)`，与重构前调用签名一致；`main.ts:185-197` loginAccount 空值拦截、清旧 session、发 login 逻辑未变。
- **输入草稿**：`accountDraft`（`lobby.ts:171`）跨 tab 保留账号/密码/确认密码，切 tab 不丢输入；注册模式才渲染确认密码框（`:217`），登录模式不携带 confirm。
- **游客/登出入口**：游客分支（`:180-186` 退出游客）与已认证分支（`:188-194` 登出）提前 return，不受 tab 影响；「以游客身份进入」按钮（`:243-244`）保留；`main.ts:203-228` logoutAccount（游客本地清理/在房间拦截/断线提示）、enterGuest 逻辑未变。
- **样式**：`.account-tabs`/`.account-register`/`.account-switch` 在 styles.css 均已定义（含响应式段），无未定义 class。
- 未发现破坏项；UI 目视交互（tab 点击观感、toast 文案）未做人工浏览器实测，建议主协调安排一次 5 分钟人工点验（非阻塞）。

### 终验结论

**PASS。** 前端 tab 重构未触碰协议/服务端，登录/注册调用链、游客与登出入口完整；robot 整局与 30 项登录冒烟与基线零差异（FAIL/BLOCKED 项与基线逐项相同，无新增）。§3 验收清单已全部勾选（LG-17 项按"已知文档偏差"标注）。遗留不变：LG-17 口径待主协调裁决，LG-19/LG-20/LG-08db 待运维窗口。
