# 页面结构重构 + UI 改版 回归验收报告

日期：2026-09-04
验收人：测试PM agent
验收依据：tests/page_flow_analysis.md 第 5 节验收清单
实施范围：后端 change_password、前端四屏重构（entry/tutorial/lobby/profile）、协议更新、UI 深海冷色系改版

## 1. 执行命令结果

| 命令 | 结果 |
|---|---|
| `cd client && npm run build` | ✅ 通过（tsc + vite build，无类型错误；dist 生成 index-KWH9J0S2.js 46.33KB / css 21.73KB） |
| `cd server && erl -noshell -eval "make:all()" -s init stop` | ✅ 通过（无编译错误） |
| eunit `[tides_json_tests, tides_game_tests, tides_account_tests]` | ✅ **All 25 tests passed**（含 change_password 新增 7 用例） |
| `tides_sim:run(20)` | ✅ 通过（退出码 0） |
| `node tests\robot.mjs`（4 账号整局冒烟） | ✅ **SMOKE PASS**（fixture 由 `_baseline_fixture.mjs` 现场注册 4 账号；完整 4 轮 12 回合 → game_over 计分校验 → returned_to_lobby → list_rooms 全部通过） |
| `node tests\change_password_check.mjs`（本轮新增 WS 端到端脚本） | ✅ **CP_SMOKE PASS**（8/8 断言） |

服务端启动方式：`deploy\start_server.bat`（编译+后台起服，9500 端口），冒烟结束后已 `taskkill` 关闭，无端口残留。

## 2. 验收清单逐条核对

### A. 登录界面（entry）
- [x] 未认证/登出/会话失效均落登录界面：main.ts:15 首屏无 session→entry；`logged_out`→`backToEntry`（main.ts:469-471）；`session authenticated=false`→`backToEntry`（main.ts:481-483）；未认证且非 tutorial 屏强制归位 entry（main.ts:86）
- [x] 含且仅含登录/注册/新手教程三主功能（entry.ts:31-38）
- [x] 登录失败提示可见且不跳屏：模态框内 `form-error` 错误条 + `authModal.showError`，失败清密码留框（main.ts:180-187, 615-625）
- [x] 注册校验与失败提示同上（validateRegistration main.ts:223-232）
- [x] 有效 session 直接进首页（main.ts:15 + session 恢复 main.ts:477-485）

### B. 新手教程
- [x] 3 页结构保留，可翻页/上一步（tutorial.ts:13-40, 62-68）
- [x] 「完成，返回登录」与每页「返回登录」→ `tutorialBack/tutorialFinish` → entry（main.ts:431-432）
- [x] 教程纯客户端，无业务协议（renderTutorial 不触网，仅入口屏 WS 连接）

### C. 首页（lobby）
- [x] 创建房间/房间码加入/在线房间列表+刷新（lobby.ts:121-156）
- [x] 右上角顶栏含账号名 + 登出按钮（lobby.ts:78-91 `renderTopbar`，btn-danger）；登出成功回登录界面（robot 与代码路径一致）
- [x] 个人中心入口（lobby.ts:102-103 → `openProfile`）
- [x] 房间内禁止登出保护保留（main.ts:288-291）
- [x] 登录态刷新页面回首页且自动刷新房间列表（main.ts:654-656）
- [x] 服务器地址调试行移入 `?debug=1`（entry.ts:20-22, 41-60），正式首页不再出现

### D. 个人界面（profile）
- [x] 个人信息展示：账号名 + 战绩网格 + 最近 10 场（profile.ts:57-91，复用 `get_my_stats`，`openProfile` 自动拉取 main.ts:370-377）
- [x] 修改密码：前端校验齐全（空旧密码/8-256/两次一致/新旧相同，main.ts:296-314）；服务端错误码中文映射（PWD_ERROR_TEXT main.ts:248-257）；成功→`password_changed`→回登录界面 toast 提示（main.ts:473-475）
- [x] 游戏说明：个人中心卡片 + 大厅顶栏「?」均可打开 manual.ts 十章说明；「返回」按来源回到 profile/lobby（main.ts:378-387）
- [x] 「← 返回首页」→ `gotoLobby`（profile.ts:139-141）
- [x] 未认证不可达（openProfile 守卫 main.ts:371）

### E. 服务端协议（change_password）
- [x] eunit 7 用例全过：成功/旧密码错误/过短/过长/新旧相同/全 session 撤销/未认证/限流（tides_account_tests.erl）
- [x] 20 局自玩模拟通过
- [x] robot.mjs 4 人整局冒烟通过
- [x] WS 端到端（新增 tests/change_password_check.mjs）：
  - `wrong_old_password` ✅、`password_changed` ✅、旧 session 撤销 ✅、旧密码登录 `invalid_credentials` ✅、新密码登录 ✅、第 4 次尝试 `rate_limited` ✅、失败尝试不误撤当前 session ✅
- [x] 协议一致性：shared/protocol.md:30,60,61,77 与 server 实现（tides_account.erl:105-109,283-360；tides_ws_conn.erl:391-392,604-660）及前端文案三者一致；改密后撤销全部 session 并回游客态，与 protocol.md:60 描述相符

### F. UI 改版
- [x] `npm run build` 通过
- [x] 深海冷色系 token 全量落地（styles.css:1-20，`--bg-abyss/bg-deep/neon-cyan/neon-blue/danger/success` 等），纯 CSS 渐变+辉光实现，无图片资源 → 无 404 风险、无体积问题
- [x] 断线横幅/toast/模态框结构保留（main.ts:643-657，form-error 新增）
- [ ] **遗留人工项**：1366×768/1920×1080 实际渲染效果、文字对比度、hover/disabled 态需浏览器人工核对（本次为静态+构建级验证，无浏览器环境）

## 3. robot.mjs 适配情况

**无需修改**。robot.mjs 为纯 WS 协议层机器人，不依赖任何 DOM/页面结构，四屏重构对其透明；本轮直接 PASS，未改动一行。

## 4. 发现的问题

### 已修复
- 无（测试PM 本轮未改动 client/server；仅新增 tests/change_password_check.mjs 回归脚本）。

### 遗留 / 建议（不阻塞本次验收）
1. **UI 视觉人工验收待做**：F 组浏览器端实测项（分辨率破版、对比度、hover 态）需人工确认。
2. **改密限流边界**：rate_limited 为每账号 3 次/分钟且**成功也计入窗口**（实测：1 次错误+1 次成功后，第 3 次错误即触发限流），与直觉「仅防爆破」略有差异；建议主协调确认是否预期，如是则在 protocol.md 中补一句说明。
3. **首访体验变化**：`tides_entry_seen` 已移除，老用户每次无 session 均落登录界面——符合新需求，但此前「已看教程」标记不再存在；如需「登录后不再自动播教程」类行为请另行提需求。
4. 旧文档 entry_screen_acceptance.md / new_player_* 系列描述的是旧页面流，未更新；建议后续归档或标注废弃，避免误导。

## 5. 结论

**验收通过（PASS）**。页面四屏结构、流转路径、登出位置、调试行隐藏、表单校验、change_password 协议（eunit + WS 端到端 + 协议一致性）全部落实；构建、编译、eunit、20 局模拟、4 人整局冒烟全部通过。唯一遗留为非阻塞的人工 UI 视觉核对项（4.1）。
