# 首页（大厅）「个人战绩」分诊与验收标准

来源需求：在首页（大厅/lobby 首页）增加"个人战绩"功能，记录 ① 胜利次数 ② 战斗场次 ③ 胜率。
日期：2026-09-04 ｜ 产出：测试PM ｜ 状态：分诊完成，待实现

## 1. 需求拆解

| 子项 | 说明 |
| --- | --- |
| HS-1 展示胜利次数 | 大厅首页（未进房间状态）展示账号累计胜场（wins） |
| HS-2 展示战斗场次 | 展示累计对局数（games） |
| HS-3 展示胜率 | 胜率 = wins/games，按整数百分比显示（与 profile.ts:72 口径一致） |
| HS-4 数据获取时机 | 进入大厅首页时自动拉取（登录成功回到大厅 / 打完一局返回大厅），无需手动刷新 |
| HS-5 边界展示 | 未登录游客、0 场战绩、加载中均有明确 UI 表现，不报错、不显示 NaN% |

## 2. 数据链路现状

| 环节 | 现状 | 结论 |
| --- | --- | --- |
| 协议 `get_my_stats` → `my_stats` | 已存在，payload.stats 含 games/wins/top2/avg_total/ladder/ladder_max/recent（shared/protocol.md） | 协议无需改动 |
| 服务端 `tides_ws_conn.erl:403-416` | 已处理 `get_my_stats`：需认证、需 role_id，游客返回 `authentication_required`，无战绩返回 `stats: null` | 后端无需改动 |
| 类型 `PlayerStats`（client/src/types.ts:111-119） | 已含 games/wins | 类型无需改动 |
| 状态 `myStats`/`myStatsLoading`（client/src/ui.ts:35-36） | 已存在 | 状态无需新增字段 |
| 请求时机（client/src/main.ts:370-377） | 仅在 `openProfile()` 中发送 `get_my_stats`；登录成功/返回大厅时不请求 | **缺口①：大厅不请求** |
| 回包处理（client/src/main.ts:588-592） | `my_stats` 到达后仅在 `screen === 'profile'` 时 render | **缺口②：大厅收到数据不重渲染** |
| 大厅渲染（client/src/lobby.ts:93-108） | 未进房间分支只有「个人中心」「排行榜」按钮，无战绩展示区 | **缺口③：大厅无战绩渲染** |

结论：**纯前端需求**。协议、服务端、shared/ 均不需要改动；仅改 `client/src/lobby.ts`（渲染）与 `client/src/main.ts`（请求时机 + 回包渲染），复用现有 `myStats`/`myStatsLoading` 状态。

## 3. 影响面分析

| 模块 | 是否受影响 | 说明 |
| --- | --- | --- |
| client/src/lobby.ts | 是 | 大厅未进房间分支新增战绩卡片（场次/胜场/胜率），含加载中与空数据分支 |
| client/src/main.ts | 是 | ① 登录成功/回到大厅时发送 `get_my_stats`；② `my_stats` 处理器在 `screen === 'lobby'` 时也 render |
| client/src/ui.ts / types.ts | 否 | `myStats`、`myStatsLoading`、`PlayerStats` 均已就绪 |
| client/src/profile.ts | 否 | 个人中心逻辑保持不变，口径可复用（胜率 `games>0 ? Math.round(wins/games*100)+'%' : '-'`） |
| client/src/net.ts | 否 | 通用 `send` 即可 |
| server/（tides_stats.erl、tides_ws_conn.erl 等） | 否 | 接口已就绪且已由 tests/stats_check.mjs 覆盖 |
| shared/protocol.md | 否 | 协议不变 |
| docs/ | 否（可选） | 若策划要在大厅 UI 规范中补战绩区块说明，可另行补充 |
| tests/ | 是 | 新增 tests/home_stats_check.mjs（静态门禁）+ 本文件验收清单 |

## 4. 验收标准清单

功能正确性：
- [ ] HS-A01 已认证账号进入大厅首页（未进房间），可见战绩区块，展示场次、胜场、胜率三项
- [ ] HS-A02 三项数值与 `get_my_stats` 返回的 `stats.games`/`stats.wins` 一致；胜率 = `Math.round(wins/games*100)%`，与个人中心页口径一致
- [ ] HS-A03 打完一局返回大厅后（returned_to_lobby / backToLobby），重新请求 `get_my_stats`，战绩数值已更新（场次 +1）
- [ ] HS-A04 登录成功进入大厅即自动拉取战绩，无需先打开个人中心

边界情况：
- [ ] HS-B01 未登录游客：不发 `get_my_stats`（服务端会回 `authentication_required`，见 stats_check GUEST-5），大厅战绩区块显示为引导登录/注册态或不显示，不出现报错与 NaN%
- [ ] HS-B02 0 场战绩（`stats` 为 null）：显示"暂无战绩"类提示，不显示 0% 或 NaN%
- [ ] HS-B03 `stats` 非 null 但 `games=0`：场次/胜场显示 0，胜率显示 `-`（与 profile.ts:72 一致）
- [ ] HS-B04 加载中（`myStatsLoading=true` 或 `myStats` 未回包）：显示加载态占位，布局不跳动、不闪现旧数据
- [ ] HS-B05 登出后回到大厅：战绩区块清除，不残留上一账号数据

回归：
- [ ] HS-R01 个人中心页战绩展示不受影响（原有渲染与 `get_my_stats` 请求保持）
- [ ] HS-R02 排行榜面板、在线房间列表、创建/加入房间流程不受影响
- [ ] HS-R03 `node tests/home_stats_check.mjs` 全部 PASS（exit 0）
- [ ] HS-R04 `cd client && npm run build` 通过（类型与编译无错误）
- [ ] HS-R05 `node tests/robot.mjs` 冒烟不回归（SMOKE PASS 或按 fixture 约定 BLOCKED）
