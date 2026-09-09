# AGENTS.md — 四 Agent 协作流程（必须遵守）

## 核心规则（用户指定，永久记住）
1. 默认由主协调（opencode 主会话）直接处理用户需求，不自动分发 agent。仅当用户本次需求明确包含触发词“多agent执行”并要求本次按该流程处理时，才启用多 agent 流程：先交给「测试PM」agent 分析，拆解需求、评估影响面、给出验收标准，再分发给对应 agent 执行。
2. 四个 agent 角色与职责（参照真实游戏项目开发）：
   - **前端 agent**：负责 `client/`（Vite + TypeScript）。页面、交互、联机协议客户端侧实现、UI 还原策划稿。只写 `client/`。
   - **后端 agent**：负责 `server/`（Erlang/OTP）。房间/大厅/协议服务端实现、性能与内存安全、稳定性。只写 `server/`。
   - **测试PM agent**：负责 `tests/`。需求分诊、测试计划、验收清单、冒烟脚本（robot.mjs 等）、回归验证、出验收报告。只写 `tests/`。
   - **策划 agent**：负责 `docs/`。玩法设计、数值、规则文档、新功能策划案。只写 `docs/`。
3. `shared/`（协议与数值，唯一事实来源）与 `README.md`/`AGENTS.md` 由主协调（opencode 主会话）修改；各 agent 需要协议/数值变更时，在报告中提出，由主协调同步。
4. 目录边界与 README「并行开发边界」一致，任何 agent 不得越界改他人目录。

## 工作流
默认流程（未明确要求多 agent 执行时）：
```
用户需求 → 主协调直接分析、实现、验证并报告用户
```

多 agent 流程（仅本次需求明确要求“多agent执行”时启用）：
```
用户需求 → 测试PM 分诊(影响面+验收标准)
         → 策划出方案(如涉及玩法) → 后端/前端实现 → 测试PM 回归验收 → 报告用户
```
- “多agent执行”是本流程唯一的显式触发词。仅在用户明确要求本次任务采用该流程且包含此短语时触发；仅在背景说明、规则引用、讨论流程或举例中提及该词，不触发。其他近义表达不自动触发。
- 多 agent 是否启用与需求是否重大是两个独立判断。重大新需求仍需先征得用户同意；未触发多 agent 流程时，由主协调负责该判断和后续处理。
- 重大新需求（新玩法、协议大改、付费/运营向功能）：**先问过用户再动手**。
- 持续迭代：每轮完成后重新分析是否有可优化项，有则处理，无则收尾；重大项先请示。

## 常用命令
```bat
:: 编译服务端
cd server && erl -noshell -eval "make:all()" -s init stop
:: 单元测试 + 20局自玩模拟
cd server && erl -noshell -pa ebin -eval 'case eunit:test([tides_json_tests, tides_game_tests]) of ok -> tides_data:ensure_loaded(), case tides_sim:run(20) of {ok,20} -> init:stop(0); _ -> init:stop(1) end; _ -> init:stop(2) end.'
:: 4人整局冒烟（需服务端已启动）
node tests\robot.mjs
:: 客户端
cd client && npm run dev / npm run build
```
