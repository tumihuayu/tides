# 入口界面（Entry Screen）需求分诊报告

日期：2026-09-04
分诊人：测试PM agent
需求：首次打开网址时展示入口界面，含三个按钮：1) 进入新手教程 2) 登录 3) 注册

## 1. 现状分析

### 1.1 当前首屏行为（client/src/main.ts:50-98）
- `render()` 根据 `state.accountStatus` 与 `state.screen` 决定首屏：
  - **未认证（signed_out/guest）**：直接渲染游客教程流（`renderTutorialIntro` / `renderGuestTutorial`，tutorial.ts），即首次打开网址看到的是「潮汐商会 · 航海手册」教程介绍页，点「开始教学」进入 3 页教程，完成后出现「注册账号并进入大厅」按钮。
  - **已认证（authenticated）**：进入大厅 `renderLobby`（lobby.ts）。
- 没有独立的「入口界面」，首屏即教程。

### 1.2 新手教程（已存在，纯客户端）
- tutorial.ts：`renderTutorialIntro`（3 页图文教程 PAGES）+ `renderGuestTutorial`（游客入口/完成页）。
- 协议明确教程为纯客户端，无服务端会话（shared/protocol.md:160-166）。
- 触发方式：未认证首屏自动进入；大厅内 `openTutorial` 也可打开（main.ts:343）。

### 1.3 登录/注册（已存在）
- 前端：`actions.registerFromTutorial`（main.ts:139-162）弹出「注册 / 登录」模态框，含账号名、密码、确认密码输入框及「登录」「注册」「退出（游客）」三个按钮；校验逻辑在 `registerAccount`（main.ts:163-199）、`loginAccount`（main.ts:200-212）。
- 会话恢复：`session` 消息 + localStorage `tides_account_session`（main.ts:404-418，net.ts:110-112）。
- 服务端协议已完整支持：`register` / `login` / `logout` / `session`（shared/protocol.md:26-29），返回 `account_registered` / `logged_in` / `logged_out` / `session`（protocol.md:72-75），错误码齐全（protocol.md:59）。

### 1.4 结论
三个按钮指向的功能全部已存在，缺口仅是**首次打开时的聚合入口界面**及其与现有教程/账号流的接线。

## 2. 影响面

| 目录/文件 | 影响 | 说明 |
|---|---|---|
| `client/src/main.ts` | 改 | 新增 `entry` screen 分支、`state.screen` 初始值/首访判断（如 localStorage 标记）、三个按钮的 action 接线 |
| `client/src/ui.ts` | 改 | `AppState.screen` 联合类型加 `'entry'`；如需新 action（如 `openEntry`）在 `AppActions` 声明 |
| `client/index.html` | 可能改 | 新增 `#screen-entry` 容器（或复用 `#screen-game`/overlay，建议新增独立容器保持边界清晰） |
| `client/src/styles.css` | 改 | 入口界面样式 |
| `client/src/entry.ts`（新文件，建议） | 新增 | `renderEntry(root, handlers)`，与 tutorial.ts 同风格 |
| `shared/protocol.md` | **不改** | 登录/注册协议已完整，无需新增消息 |
| `server/` | **不改** | 无任何协议/行为变更 |
| `tests/` | 新增 | 本分诊文档；后续测试计划与冒烟脚本 |

## 3. 实现建议

1. **纯前端改动**，不触及协议与后端。
2. 新增 `entry` screen：state 增加 `screen: 'entry'` 初始态（或独立 `entryShown` 布尔），`render()` 增加分支渲染入口界面。
3. 首访判定：localStorage 标记（如 `tides_entry_seen`）。首次打开 → 入口界面；已访问过 → 保持现有行为（未认证进游客教程流 / 已认证 session 恢复进大厅）。
4. 按钮接线（全部复用现有 action，零新协议）：
   - 进入新手教程 → 复用游客教程流（等价现有未认证首屏行为，参考 main.ts:54-64 / `enterGuest` 语义）。
   - 登录 → 打开账号模态框（复用 `registerFromTutorial` 或拆出独立 login 入口，建议拆分避免「注册/登录」混在一个模态框的歧义，亦可先复用）。
   - 注册 → 同上，聚焦注册路径。
5. 登录/注册成功路径不变：`setAuthenticated` → 大厅（main.ts:127-136）。
6. 建议把「登录」「注册」拆为两个独立模态框入口，文案与按钮主行动明确；可抽公共 `openAccountModal(mode: 'login' | 'register')`。
7. 样式遵循现有 `tutorial-*` / `btn-gold` / `btn-tide` 命名体系。

## 4. 验收标准清单

### 首屏与入口
- [ ] 清除站点数据后首次打开网址，展示入口界面，含且仅含三个主按钮：「进入新手教程」「登录」「注册」
- [ ] 入口界面不创建房间、不发送任何业务协议消息（仅 WS 连接/ping）
- [ ] 已访问过的浏览器再次打开，不强制显示入口界面，保持现有默认路径
- [ ] 持有有效 session 的浏览器打开，仍直接恢复进大厅（现有行为不回归）

### 新手教程按钮
- [ ] 点「进入新手教程」进入现有 3 页教程流，可翻页/返回/完成
- [ ] 教程完成后可到达注册引导（与现有游客完成页一致）

### 登录按钮
- [ ] 点「登录」出现登录表单（账号名+密码）
- [ ] 空账号/密码有前端提示，不发消息
- [ ] 正确凭证 → 收到 `logged_in` → 进入大厅
- [ ] 错误凭证 → 提示「账号名或密码错误。」（`invalid_credentials`），不进入大厅

### 注册按钮
- [ ] 点「注册」出现注册表单（账号名+密码+确认密码）
- [ ] 前端校验齐全：账号名 3-64 字符、仅 `[A-Za-z0-9_-]`、密码 8-256、两次密码一致（错误提示与 main.ts:163-199 一致）
- [ ] 注册成功（`account_registered` 带 session）→ 自动登录进入大厅
- [ ] 账号已存在 → 提示「账号已存在。」（`account_exists`）

### 通用与回归
- [ ] `cd client && npm run build` 通过（无 TS 类型错误）
- [ ] 断线横幅、模态框、toast 在入口界面下工作正常
- [ ] 服务端 eunit + 20 局自玩模拟通过（见 AGENTS.md 常用命令，确认无服务端回归）
- [ ] `node tests\robot.mjs` 4 人整局冒烟通过（登录→建房→整局流程不受影响）

## 5. 建议执行顺序

1. **前端 agent**：新增 entry screen 渲染（新文件 `client/src/entry.ts`）+ main.ts/ui.ts/index.html/styles.css 接线；登录/注册模态框拆分。
2. **测试PM**：按第 4 节 checklist 静态验收 + 浏览器手测首访/回访/session 恢复三条路径。
3. **回归**：`npm run build`、服务端 eunit+sim、`robot.mjs` 冒烟。
4. 出验收报告至 `tests/entry_screen_acceptance_report.md`。

> 无需策划案（无玩法/数值变更）；无需后端/协议变更。若产品后续要求「登录/注册页带美术稿」，再交策划 agent 出 UI 稿。
