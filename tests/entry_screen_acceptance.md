# 入口界面（Entry Screen）回归验收报告

日期：2026-09-04
验收人：测试PM agent
依据：tests/entry_screen_triage.md 验收 checklist
范围：client/ 入口界面实现（entry.ts / main.ts / ui.ts / index.html / styles.css）；server/shared 未改动。

## 验收结论：通过（静态验收 + 构建/单测/模拟全部通过；robot.mjs 因服务端未启动未执行，见遗留风险）

## 一、Checklist 逐项核验

### 首屏与入口
- [x] 清除站点数据后首次打开网址展示入口界面，含且仅含三个主按钮「进入新手教程」「登录」「注册」
  - 依据：main.ts:15 `screen: localStorage.getItem(LS_ENTRY_SEEN) || loadAccountSession() ? 'lobby' : 'entry'`；entry.ts:17-22 恰好三个按钮。
- [x] 入口界面不创建房间、不发送任何业务协议消息（仅 WS 连接/ping）
  - 依据：renderEntry 仅绑定三个 onclick；三个 handler 只做 markEntrySeen / render / openAccountModal，无 net.send；net.connect() 仅建立连接与 20s ping（net.ts:170）。
- [x] 已访问过的浏览器再次打开不强制显示入口界面，保持现有默认路径
  - 依据：`tides_entry_seen=1` 时初始 screen='lobby'，未认证回落到游客教程流（main.ts:77-90），与旧行为一致。
- [x] 持有有效 session 的浏览器打开仍直接恢复进大厅（不回归）
  - 依据：main.ts:15 有 session 时直接 'lobby'；setReconnectHook 发送 `session`（main.ts:644-652），session handler → setAuthenticated → 大厅（main.ts:451-465, 153-162）。

### 新手教程按钮
- [x] 点「进入新手教程」进入现有教程流，可翻页/返回/完成
  - 依据：main.ts:65-71 置 tutorialPage=-1 后 render → 未认证分支渲染 renderTutorialIntro 介绍页 →「开始教学」进入 3 页（tutorial.ts:15-19, 46-51）。
- [x] 教程完成后可到达注册引导
  - 依据：tutorialFinish → tutorialCompleted → renderGuestTutorial(completed=true)「注册账号并进入大厅」→ registerFromTutorial → openAccountModal('register', true)（main.ts:402-406, 207-209）。

### 登录按钮
- [x] 点「登录」出现登录表单（账号名+密码）
  - 依据：openAccountModal('login')，仅账号名+密码两个输入框（main.ts:167-174）。
- [x] 空账号/密码有前端提示，不发消息
  - 依据：loginAccount 空值校验（main.ts:248-253）在 net.send 之前。
- [ ] 正确凭证 → 收到 `logged_in` → 进入大厅（静态路径已核对 main.ts:427-429→setAuthenticated，联机项待手测/冒烟）
- [ ] 错误凭证 → 提示「账号名或密码错误。」（`invalid_credentials`）（错误码映射已核对 main.ts:589-599，联机项待手测/冒烟）

### 注册按钮
- [x] 点「注册」出现注册表单（账号名+密码+确认密码）
  - 依据：openAccountModal('register') 含 confirm 输入框（main.ts:171-174）。
- [x] 前端校验齐全：账号名 3-64 字符、仅 `[A-Za-z0-9_-]`、密码 8-256、两次密码一致，提示文案与校验顺序和此前一致
  - 依据：registerAccount（main.ts:210-246）逻辑未变。
- [ ] 注册成功（`account_registered` 带 session）→ 自动登录进入大厅（静态路径已核对 main.ts:430-440，联机项待手测/冒烟）
- [ ] 账号已存在 → 提示「账号已存在。」（`account_exists`）（映射已核对，联机项待手测/冒烟）

### 通用与回归
- [x] `cd client && npm run build` 通过（tsc + vite build，0 错误；dist 产物正常）
- [x] 断线横幅、模态框、toast 在入口界面下工作正常（静态）
  - 依据：banner/toast/modal 均为独立 root（index.html:10,15-16），不受 screen 分支影响；net.onConn 逻辑不变（main.ts:627-642）。
- [x] 服务端 eunit + 20 局自玩模拟通过
  - 结果：`All 18 tests passed`，eval 退出码 0（sim {ok,20}）。
- [ ] `node tests\robot.mjs` 4 人整局冒烟 —— **未执行**：本机 9500 端口无服务端监听（Test-NetConnection 失败），环境不具备。

## 二、自动验证记录

| 项 | 命令 | 结果 |
|---|---|---|
| 客户端构建 | `cd client && npm run build` | 通过（tsc + vite，282ms） |
| 服务端单测+模拟 | `cd server && erl -noshell -pa ebin -eval '...'`（AGENTS.md） | 通过（18 tests，exit=0） |
| 4 人整局冒烟 | `node tests\robot.mjs` | 未执行（服务端未启动） |

## 三、遗留风险 / 待办

1. **联机路径未实机验证**：登录成功/失败、注册成功/重复账号 4 条联机 checklist 仅做静态核对。建议服务端可用时执行 `tests\login_logout_smoke.mjs`（已有脚本覆盖登录登出）+ 浏览器手测入口屏三按钮，并在本报告补勾。
2. **robot.mjs 冒烟未执行**：本次为纯前端改动，协议层无变更，回归风险低，但建议下次服务端联调窗口补跑。
3. **已知设计行为（非缺陷）**：
   - 登录模态框在发送后立即关闭，错误以 toast 呈现（沿用旧交互）。
   - 用户在入口屏直接关闭页面未点任何按钮时，下次打开仍显示入口屏（未标记 seen），符合「首次打开」语义。
   - 持有失效 session 且未访问过入口屏的极端组合：初始进 lobby→session 被拒后回落游客教程流而非入口屏，属可接受边缘行为。

## 四、后续建议

- 服务端联调窗口：跑 `login_logout_smoke.mjs` + `robot.mjs`，手测三按钮，补勾后关闭本需求。
