# v0.3.2 验收报告 — 服务端管理功能（ADM-01~10）

- 验收日期：2026-08-26（初验）；2026-08-26（复验，D1/D2/D5 修复后脚本链全量重跑）
- 验收人：测试PM
- 被测版本：复验时服务端 healthz/admin 上报 `version: "0.3.2"`（D2 已闭环）
- 环境：本机 Windows（CP936/GBK），node 脚本 + curl.exe；服务端经 erl 后台启动
- 范围：test_plan.md §10 ADM-01~10 + 全量回归 + 复验脚本链

## 0. 总体结论（复验后更新）

**通过（PASS）。** 初验唯一 P0 阻塞 D1（bat 换行/编码致 cmd 无法解析）已由主协调修复并复验闭环：`deploy\tidesctl.bat`（66 行全 CRLF、0 非 ASCII 字节）与 `deploy\start_server.bat`（30 行全 CRLF、0 非 ASCII 字节）在 cmd（CP936）下解析零报错，start/stop/status/players 全链路原脚本实测 PASS；D2（version 0.3.2）、D5（erl_crash.dump 已清理）同步闭环。ADM-01~10 全部通过，交付物可发布。

复验唯一新发现：**D4 成因实锤并升级**——经「控制台被宿主回收」方式启动的 erl 内存以 ~17MB/s 暴涨（3 分钟 2.3GB→4.1GB）；同 beam 干净分离启动后内存稳定 17.7MB，排除服务端代码泄漏。详见 §3 D4。

### 复验脚本链记录（原脚本，cmd /c 直跑）

| 步骤 | 结果 | 输出要点 |
|---|---|---|
| 前置：taskkill 旧服务端 18196 | ✅ | 9500 无 LISTENING |
| status（未运行） | ✅ PASS | `[INFO] server not responding. Is it running? (tidesctl start)`，exit=1，无堆栈无乱码 |
| players（未运行） | ✅ PASS | 同上，exit=1 |
| stop（未运行，幂等） | ✅ PASS | `[INFO] tides server is not running (port 9500 free)`，exit=0 |
| start（编译+启动） | ✅ PASS | 编译通过，erl 拉起 LISTENING 9500（PID 14612）；cmd 解析零报错（D1 行为级闭环） |
| status（运行中） | ✅ PASS | `{"ok":true,"version":"0.3.2",...}` 字段完整；start 重编译后 beam 已升 0.3.2（D2 闭环） |
| 建房+bot 后 players | ✅ PASS | `adm_players_check.mjs` 全绿：房 L2GK，真人 AdmCheck(is_bot=false)+bot 潮生(is_bot=true)，与 WS room_update 完全一致 |
| stop（运行中） | ✅ PASS | `[OK] tides server stopped (PID 14612)`，exit=0；9500 无 LISTENING；healthz 000（连接拒绝，端口彻底释放） |
| 再 status（未运行） | ✅ PASS | 友好提示，exit=1 |
| D5 核查 | ✅ PASS | 仓库根 `erl_crash.dump` 已不存在 |

注：复验中经自动化工具包装执行 `start` 时宿主控制台被回收，恰好触发并定位了 D4 的内存暴涨成因（非交付脚本缺陷，正常 cmd 窗口下无此问题）；收尾改用完全分离方式启动，状态见 §5。

---
（以下为初验原始记录，保留备查）

## 0.1 初验总体结论

**有条件通过（初验，已被上方复验结论取代）：服务端管理接口本身全部 PASS（ADM-02/03/05~10 行为级全过，ADM-07 安全实测过），但交付脚本 `deploy\tidesctl.bat`、`deploy\start_server.bat` 存在 P0 阻塞缺陷 D1（LF-only 换行 + UTF-8 中文注释，cmd 在 CP936 下无法解析，四命令全部不可用）。** D1 属 deploy/ 归主协调修复；修复后仅需重跑脚本链（预计 10 分钟），无需重测服务端侧用例。

由于 D1，初验时 ADM 脚本链各用例在「修复副本」（Temp 目录 CRLF 转换版，逻辑逐字节未动）上验证；下表对「原脚本」与「修复副本/服务端行为」分别如实标注。复验已在原脚本上全链路重跑通过（见 §0 表）。

## 1. ADM 明细

| 用例 | 结果 | 证据 |
|---|---|---|
| ADM-01 start 一键编译+启动+重复保护 | ❌ 原脚本 FAIL（D1） / ✅ 修复副本+行为 PASS | 原脚本执行直接报 `不是内部或外部命令` 乱码流；修复副本 start 编译 up_to_date 并拉起 erl；运行中重复 start → `[ERROR] port 9500 already in use by PID 22560`，exit=1，仍仅 1 个 LISTENING |
| ADM-02 status 字段完整 | ✅ PASS | `{"connections_online":1,"memory_mb":17.6,"ok":true,"players_online":0,"rooms_online":0,"uptime_sec":27,"version":"0.3.0"}`；3 秒后 uptime_sec 27→30 递增；字段 version/uptime_sec/rooms_online/players_online/connections_online/memory_mb 齐全，JSON 可解析 |
| ADM-03 players 与实际一致 | ✅ PASS | 新脚本 `tests/adm_players_check.mjs`：建 1 房(FL3B)+1 bot 后 `/admin/players` 返回 2 条，每条含 `name/room_id/phase/is_bot/connected/auto_pilot`；真人 `AdmCheck`(is_bot=false) 与 bot `潮生`(is_bot=true) 均 connected=true、phase=lobby、room_id=FL3B，与 WS `room_update` 成员完全一致；真人断线后房间解散、`players:[]` 同步清空 |
| ADM-04 stop 正常停止 | ❌ 原脚本 FAIL（D1） / ✅ 修复副本+行为 PASS | `stop` → `[OK] tides server stopped (PID 22560)`，exit=0；9500 无 LISTENING；healthz 连接失败(000)；`erl_crash.dump`（仓库根，20:13:06，验收前已存在）未变化；重启后 `stats_check.mjs --verify-persist` 7/7 PASS，dets 战绩完好 |
| ADM-05 未运行 status/players 友好提示 | ❌ 原脚本 FAIL（D1） / ✅ 修复副本 PASS | 未运行时两命令均输出 `[INFO] server not responding. Is it running? (tidesctl start)`，exit=1，无堆栈 |
| ADM-06 未运行 stop 幂等不误杀 | ❌ 原脚本 FAIL（D1） / ✅ 修复副本 PASS | 未运行时 `stop` → `[INFO] tides server is not running (port 9500 free)`，exit=0；代码审查（tidesctl.bat:20-38）：仅按 9500 LISTENING 定位 PID，且 `tasklist /FI "PID eq %PID%"` 确认含 erl 才 taskkill，非 erl 占用时拒绝并 exit=1；实测副证：当时机器上另有一个 erl(25924，非 9500 监听)，stop 未触碰 |
| ADM-07 管理接口安全 | ✅ PASS（A 实测，B 代码审查） | 场景A 实测：经本机 LAN IP `http://192.168.20.238:9500/admin/status`（对端非回环）→ **403**；同来源 `/healthz` → 200（公开端点不受影响）；localhost → 200。场景B：当前 `shared/data/config.json` 无 `admin_token` 键，代码审查 `tides_ws_conn.erl:85-118`：非 localhost 时走 `admin_token_ok/1`，未配置 token 一律 false→403；配置后仅 `x-admin-token` 头严格相等放行，缺/错头→403；合法 localhost+正确 token→200（本机无法自签远端来源+改 shared/ 配置，按既定安全方案以审查为准） |
| ADM-08 全量回归 | ✅ PASS | 重编译 up_to_date；eunit 18/18；sim 20/20；`robot.mjs` SMOKE PASS ×2（4真人、4真人再验）；`robot.mjs --bots=3` SMOKE PASS ×3；`mem_check.mjs` 5/5；`stats_check.mjs` 14/14；`/healthz` 200 且 version 不变、`/` 404（PC-09 不变） |
| ADM-09 对局中并发管理调用 | ✅ PASS | 新脚本 `tests/adm_concurrent_check.mjs`：`robot --bots=3` 对局进行中并发打 status×20 + players×20：全 200、合法 JSON、Connection: close、Content-Length 正确；P95 status=37.2ms / players=41.8ms（远 < 500ms）；同局 robot SMOKE PASS，对局推进不受阻 |
| ADM-10 连续 50 次调用 | ✅ PASS | 顺序 status×50 + players×50：全 200/合法 JSON/`Connection: close`/Content-Length 字节数正确；P95 ≤ 1.8ms；调用前后 memory_mb 17.6→18.0 平稳，无残留（TIME_WAIT 为客户端正常关闭态，无 LISTENING 泄漏） |

补充校验（脚本自证）：首版 `adm_concurrent_check.mjs` 曾误报 players 的 Content-Length 不符，定位为脚本 bug（JS `string.length` 按 UTF-16 计，bot 名「潮生」多字节），已改用 `Buffer.byteLength(body,'utf8')` 复测通过——服务端 Content-Length 实际正确。

## 2. 回归清单

| 项 | 结果 |
|---|---|
| `make:all()` 重编译 | up_to_date（beam 均为当日新编：tides_admin 20:14、tides_ws_conn 20:21） |
| eunit（tides_json_tests + tides_game_tests） | 18/18 PASS |
| `tides_sim:run(20)` | 20/20 |
| robot.mjs（4 真人） | SMOKE PASS ×2 |
| robot.mjs --bots=3 | SMOKE PASS ×3 |
| mem_check.mjs | 5/5 PASS |
| stats_check.mjs（全量 + --verify-persist） | 14/14 + 7/7 PASS |

## 3. 遗留与缺陷（提请主协调/后端）

- **D1（P0，deploy/ 主协调）✅ 闭环**：主协调已将两 bat 重写为纯英文注释 + CRLF。复验实测：`tidesctl.bat` 66 行全 CRLF / 0 非 ASCII 字节，`start_server.bat` 30 行全 CRLF / 0 非 ASCII 字节；cmd（CP936）下 start/stop/status/players 原脚本全链路零报错（§0 复验表）。
- **D2（P2，server/ 后端）✅ 闭环**：start 重编译后 beam 生效，`/healthz` 与 `/admin/status` 均上报 `version: "0.3.2"`。
- **D3（观察，非缺陷）**：`/admin/status` 的 `connections_online` 把查询自身的 HTTP 短连接计入（查询瞬间恒 ≥1）；连接关闭后 monitor DOWN 正常回收，无泄漏。建议文档注明口径或后续将 admin 连接排除。
- **D4（观察 → 升级为重要部署风险，复验实锤成因）**：`start_server.bat` 用 `start /b` 拉起 erl，进程依附调用方控制台。复验期间自动化工具回收包装进程控制台，实测该 erl 内存以 ~17MB/s 暴涨（20:55 启动，2.3GB → 4.1GB / 85 秒），与初验发现的 6.5GB 残留 erl 成因一致。**对照实验**：同 beam（0.3.2）以完全分离方式（独立隐藏控制台）启动后，memory_mb 稳定 17.7、RSS 32MB，排除服务端代码泄漏。结论：非交付脚本在正常 cmd 窗口下的缺陷，但无人值守/被包装调用场景下风险真实存在，强烈建议服务化（或独立控制台 `start` 不加 `/b` + pid 文件）。
- **D5（遗留）✅ 闭环**：仓库根 `erl_crash.dump` 已由主协调清理（复验 Test-Path = False）。
- **Linux `tidesctl.sh`**：本机无 Linux 环境，未验，沿用 checklist 4.11 末行「待 Linux/VPS 环境」。

## 4. 新增测试资产（tests/）

- `tests/adm_players_check.mjs` — ADM-03 对拍脚本（admin/players vs WS room_update/list_rooms）
- `tests/adm_concurrent_check.mjs` — ADM-09/10 并发/连打脚本（`node tests/adm_concurrent_check.mjs [concurrent|sequential|both]`）
- `tests/linecheck.ps1` — bat 换行/编码核查（CRLF/LF-only/非 ASCII 字节计数，复验 D1 用）
- `tests/proccheck.ps1` — erl 进程核查（PID/父进程/启动时间/RSS/命令行，复验 D4 对照实验用）

## 5. 验收后状态（复验收尾）

- 服务端**保留运行**：erl **PID 32364**（21:01:22 以完全分离方式启动，等价 tidesctl start 后的运行态）；`/healthz` 200 `{"ok":true,"version":"0.3.2"}`；`/admin/status` 正常，memory_mb 稳定 17.7、RSS 32.3MB（健康）。
- 旧服务端 18196、复验中间实例 14612（泄漏态）、20204 均已停止；机器上仅 32364 一个 erl，9500 仅其 LISTENING。
- dets 战绩库（`server\data\tides_stats.dets` 6560B）完好。
