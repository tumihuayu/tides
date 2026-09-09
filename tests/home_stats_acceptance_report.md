# 首页「个人战绩」验收报告 — HS-A01~R05

- 验收日期：2026-09-04
- 验收人：测试PM
- 被测改动：前端 agent 实现（client/src/lobby.ts 新增 renderMyStatsCard；client/src/main.ts 新增 requestMyStats 并接入 setAuthenticated / backToLobby / returned_to_lobby / backToEntry）
- 环境：本机 Windows，node 脚本 + 静态代码核对；服务端未启动（healthz curl exit=7），robot.mjs 本轮不执行
- 依据：tests/home_stats_triage.md §4 验收清单

## 0. 总体结论

**通过（PASS）。** 功能项 HS-A01~A04、边界项 HS-B01~B05 全部按代码核对通过；静态门禁 `tests/home_stats_check.mjs` 8/8 PASS；`npm run build` 编译通过。唯一未执行项 HS-R05（robot.mjs 整局冒烟）因服务端未启动跳过，属环境限制而非缺陷，建议下轮有服务端环境时补跑。

## 1. 功能正确性

| 用例 | 结果 | 证据 |
|---|---|---|
| HS-A01 大厅首页（未进房间）展示战绩区块（场次/胜场/胜率） | ✅ PASS | lobby.ts:131 无房间分支渲染 `renderMyStatsCard(s)`；lobby.ts:108-112 三项为 战斗场次/胜利次数/胜率 |
| HS-A02 数值与 my_stats 一致、胜率口径与个人中心一致 | ✅ PASS | lobby.ts:106 `st.games > 0 ? Math.round((st.wins/st.games)*100)+'%' : '-'`，与 profile.ts:72 逐字一致 |
| HS-A03 打完一局返回大厅后数据刷新 | ✅ PASS | main.ts:497-502 `returned_to_lobby` 处理器调用 `requestMyStats()`；main.ts:368-371 `backToLobby()` 同样调用 |
| HS-A04 登录成功进大厅即自动拉取 | ✅ PASS | main.ts:144-152 `setAuthenticated()` 内置 `requestMyStats()`；main.ts:604 `my_stats` 在 lobby/profile 页均 render |

## 2. 边界情况

| 用例 | 结果 | 证据 |
|---|---|---|
| HS-B01 未登录游客不发请求、无报错无 NaN% | ✅ PASS | main.ts:139 `requestMyStats` 首行 `accountStatus !== 'authenticated'` 直接 return；游客停留在 entry 屏（main.ts:169），不渲染大厅战绩卡 |
| HS-B02 stats 为 null 显示暂无战绩 | ✅ PASS | lobby.ts:101-104 空数据分支「暂无战绩记录，完成一局对战后自动建档。」 |
| HS-B03 stats 非 null 但 games=0：场次/胜场 0、胜率 '-' | ✅ PASS | lobby.ts:106 胜率三元运算 `games > 0 ? ... : '-'` |
| HS-B04 加载中占位 | ✅ PASS | lobby.ts:97-99 `myStatsLoading` 分支显示「战绩加载中…」，卡片容器先渲染、无布局跳动 |
| HS-B05 登出后清除战绩 | ✅ PASS | main.ts:165-166 `backToEntry()` 置 `myStats=null`、`myStatsLoading=false` |

## 3. 回归

| 用例 | 结果 | 证据 |
|---|---|---|
| HS-R01 个人中心页不受影响 | ✅ PASS | main.ts:384-385 `openProfile()` 保留原内联 `get_my_stats` 发送；profile.ts 未改动 |
| HS-R02 排行榜/在线房间/建房加房流程不受影响 | ✅ PASS | lobby.ts 战绩卡为新增插入（line 131），排行榜面板、在线房间列表与按钮逻辑未触碰 |
| HS-R03 home_stats_check.mjs 全 PASS | ✅ PASS | 8/8 PASS，exit=0 |
| HS-R04 npm run build 通过 | ✅ PASS | `tsc && vite build` 成功，无类型/编译错误 |
| HS-R05 robot.mjs 冒烟不回归 | ⬜ 未测（环境） | 服务端未启动（healthz 连接拒绝）；本改动纯前端、协议未变，预计不影响；建议下轮补跑 |

## 4. 遗留事项

- HS-R05 待服务端环境补跑 `node tests/robot.mjs`（有账号 fixture 时应 SMOKE PASS）。
- 建议后续真机手测一次「打完一局返回大厅战绩 +1」的端到端刷新路径（HS-A03 行为级确认）。
