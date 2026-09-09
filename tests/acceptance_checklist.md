# 《潮汐商会》MVP 验收清单

## 0. 新身份模型门禁

- [ ] GUEST-01 游客无 `role_id`/`PlayerProcess`，只能运行纯客户端教程；`create_room`/`join_room`/`reconnect`/`start_practice`/真实对战均禁止
- [ ] GUEST-02 游客不能读取/修改账号统计或教程状态；游客不产生 games/wins/ladder/recent 等统计
- [ ] GUEST-03 教程结束游客只能注册或退出；注册成功后才成为账号，游客教程状态不自动迁移到账号
- [ ] BOT-13 Bot 仅为房间临时数据；房间关闭即释放 Bot、房间、定时器和相关状态
- [ ] ROLE-01 账号 role 生命周期（注册、登录、登出、过期、重登）及游客/普通账号/管理员权限边界可由隔离 fixture 复现
- [ ] LEGACY-01 旧 `player_token` 统计仅做兼容/迁移专项；不得作为游客账号、role 或教程状态的归属键

验收方式：✅ 通过 / ❌ 不通过（附原因）/ ⬜ 未测。每项需记录验收日期与版本号。

## 1. 核心功能

- [ ] 2-4 人可完成建房 → 加入 → 准备 → 开局全流程
- [ ] **4 名玩家在不同网络环境（至少 2 个不同外网/运营商）完成一整局（4 轮 × 3 回合）**
- [ ] 六种行动（sail / trade / deliver / post / tidecraft / tailwind）及 cargo / tide 两种副模式均可正常提交与结算
- [ ] 全部非法行动（手牌不存在、钱不够、非相邻港口、订单缺货、阶段错误等）被服务端拒绝且不影响对局
- [ ] action_id 去重生效：重复提交不产生重复结算
- [ ] 终局计分正确：breakdown 各项与 total 一致，分数符合 config.json 数值
- [ ] `node tests/robot.mjs` 使用账号 fixture 输出 `SMOKE PASS`（exit 0）；无账号 fixture 必须 `BLOCKED`（exit 2）
- [x] PC-09 healthz：`GET /healthz` → 200 且 `{"ok":true,"service":"tides"}`；`GET /` → 404；非 Upgrade `GET /ws` → 400（2026-08-26 本机实测通过）
- [x] PC-10 反代隧道：`tests/proxy_sim.mjs`（127.0.0.1:18080）静态托管 + `/ws` Upgrade 隧道转发 9500，`node tests/robot.mjs ws://127.0.0.1:18080/ws` 完整 4 人局 SMOKE PASS（2026-08-26 实测通过）

## 2. 稳定性

- [ ] 整局过程中**无致命崩溃**（服务端无异常退出，无需人工重启）
- [ ] 断线玩家 60s 内可通过 `reconnect` 恢复，状态完整（手牌/金币/货物/位置正确）
- [x] 断线 >60s 的玩家（v0.3 修订）由 AI 托管接管（auto_pilot=true）不阻塞其他玩家，重连可夺回控制权（2026-08-26 stats_check --autopilot PASS；旧措辞"按超时自动行动处理"作废，见 test_plan DC-03/MEM-07）
- [ ] 45s 未提交自动弃手牌第 1 张（mode=tide），回合正常推进
- [ ] **10 个并发房间**同时进行完整对局，互不串扰、无卡死
- [ ] 连续运行 2 小时（多局轮换）无内存/进程泄漏导致的退化

## 3. 安全与隐藏信息

- [ ] 任一玩家收到的 state_sync / game_started 中不含他人手牌与他人隐藏订单
- [ ] reveal_cards 不提前暴露未亮出的手牌
- [ ] 伪造 token / 他人 player_id 的 reconnect 被拒绝
- [ ] 畸形消息（非法 JSON、超长字段、未知 type）不导致崩溃，error code 为字符串

## 4. 体验指标

- [ ] **新玩家规则讲解 ≤ 10 分钟**即可上手完成首次行动（以 2 名未玩过桌游的受试者验证）
- [ ] **单局时长 ≤ 60 分钟**（4 人正常对局实测）
- [ ] 局域网内行动反馈延迟 P95 < 500ms
- [ ] 断线重连 UI 有明确提示（谁掉线、是否可重连）
- [ ] 结算日志（action_log）可读，玩家能理解每回合发生了什么

## 4.5 网络与部署接入

- [x] LAN-01 本机自证：服务端监听 0.0.0.0:9500；防火墙 9500/5173 入站允许规则存在且启用；`Test-NetConnection 192.168.20.238 -Port 9500` → True（2026-08-26 实测通过）
- [ ] LAN-01 人工项：第二台设备经 `http://<主机IP>:5173` + `ws://<主机IP>:9500/ws` 完成整局（**待人工现场验证**）
- [ ] LAN-02 外网经代理：VPS 部署后 `node tests/robot.mjs wss://<域名>/ws` SMOKE PASS，浏览器 https 整局无断连（**待人工/VPS 验证**）

## 4.6 v0.2 内存安全回归

- [x] v0.2 准入：eunit 16 项全过 + `tides_sim:run(20)` = `{ok,20}` + `robot.mjs` SMOKE PASS（2026-08-26 实测，见 acceptance_report_v0.2.md）
- [ ] MEM-01 分片缓冲上限：恶意永不结束的分片帧不导致内存增长，连接被关闭（⬜ 未测，需 raw 分片帧工具）
- [x] MEM-02/04 重复建房不泄漏：`mem_check.mjs` 50 次重复 create_room 全部 `already_in_room`，`list_rooms` 房间实例=1，断开后无孤儿房间（2026-08-26 PASS）；MEM-03 join 分支未单独验证
- [x] MEM-05 accept 错误不忙循环：`mem_check.mjs` 200 次异常 TCP 连接（含握手中途断开）后监听器存活、可正常建房（2026-08-26 PASS）
- [x] MEM-08 lobby 房主离开：单人房主断线房间立即消失；2 人房主断线转移给真人（2026-08-26 mem_check.mjs PASS）
- [ ] MEM-09 慢消费者背压：慢连接不导致服务端信箱无限堆积，其他玩家不受影响（⬜ 未测）
- [ ] MEM-12 连续 5 局 robot 冒烟后内存/进程数回落至基线，无单调爬升（⬜ 未测，需 erlang:memory 采样）
- [x] v0.1 抽测回归：eunit + 4 真人冒烟 + PC-09/PC-10 全 PASS，无协议行为回退（2026-08-26；RJ/DC/TO/SC 手工项未全量重跑）

## 4.7 v0.2 人机功能

- [x] BOT-01/02 1 真人 + 3 人机组队成功并开局：`room_update` 中 bot `is_bot=true`、恒 ready、非房主（2026-08-26 robot --bots=3 PASS；客户端按钮属前端人工项）
- [x] BOT-03 1 真人 + 3 人机完整打完一局并收到正确 `game_over`（scores=4，bot 每回合 2-3s 内自动合法提交，2026-08-26 PASS）
- [ ] BOT-04 1 真人 + 1 人机（2 人下限）可完整对局（⬜ 未测，robot 已支持 `--bots=1`）
- [ ] BOT-05/06/07 非房主/满员/游戏中添加人机均被拒绝（⬜ 未测）
- [ ] BOT-08 真人断线 60s 内重连，人机局状态完整恢复（⬜ 未测）
- [ ] BOT-09 房主离开后带人机的房间正常回收，无泄漏（⬜ 未实测）
- [ ] BOT-11 人机无 token 泄漏，伪造人机 reconnect 被拒绝（⬜ 未测）
- [x] BOT-12 `node tests/robot.mjs --bots=3` 人机场景 SMOKE PASS（2026-08-26 实测通过）

## 4.8 v0.3 战绩与排行榜（LDR）

- [x] LDR-01 纯真人局终局后战绩正确落盘（games/wins 归属正确）（2026-08-26 stats_check：game_over scores 含 rank+ladder_delta，战绩 games+1）
- [x] LDR-02 服务端重启后战绩不丢失、不回退（2026-08-26 taskkill 重启后 games/ladder 与重启前一致，dets 生效）
- [ ] LDR-03 天梯分变化方向与量值符合最终账号公式（低天梯 ×1.2；Bot 不减半；并列分支需 live 覆盖）
- [x] LDR-04 排行榜 top10 查询排序与字段正确，含人数 <10 边界（2026-08-26 双 board 字段/self_rank/非法参数 PASS；entries 因 games≥5 门槛为空，排序未实测）
- [ ] LDR-05 含人机局照常计分且 Bot 不减半，recent 标 `has_bot=true`；bot 名下无记录（旧 ×0.5 记录作废）
- [ ] LDR-06 个人战绩仅对账号验证；游客统计必须为零；旧“无 token 必须 `stats_token_required`”只保留 LEGACY 记录
- [ ] LDR-07 身份归并/隔离正确——隔离已验证（新 token stats=null），同身份跨房归并未测（2026-08-26 部分）
- [ ] LDR-08 掉线未归玩家战绩结算符合决策——托管按实际名次计分已由 BOT2-06 覆盖；rage_quit 末名分支未测（2026-08-26 部分）
- [ ] LDR-09 3 房并发终局落盘无丢失无串数据（⬜ 未测）
- [x] LDR-10 战绩文件缺失/损坏时服务端可启动且按容错策略处理（2026-08-26 eunit 28 项含损坏 dets 重建用例 PASS；删除文件场景未单独实测）
- [ ] LDR-11 反作弊：并行计分策略生效、无刷分路径（⬜ 未测）
- [x] LDR-12 新协议消息非法输入返回字符串 code error，不崩溃（2026-08-26 invalid_board/invalid_limit/stats_token_required 全 PASS）

## 4.9 v0.3 人机进阶（BOT2）

- [x] BOT2-01/02 `add_bot` 支持 easy/hard 难度且整局行为合法（2026-08-26 stats_check + robot --bots=3 + sim 双难度各 20 局 PASS）
- [x] BOT2-03 非法 difficulty 值被拒绝或按协议回落，不崩溃（2026-08-26 invalid_difficulty PASS）
- [x] BOT2-04 真人掉线超宽限期后由人机托管接管（AI 决策，非简单弃牌）（2026-08-26 --autopilot：60s 整托管接管，托管出牌含 action）
- [x] BOT2-05 托管中真人重连可夺回控制权，无托管残留（不双提交）（2026-08-26 PASS：auto_pilot=false 广播 + 挂起托管动作撤销）
- [x] BOT2-06 托管至终局正常计分，战绩按 LDR-08 规则结算（2026-08-26 托管-夺回混合局 game_over scores=4）
- [x] BOT2-07 托管状态按协议呈现，不泄漏 AI 决策信息（room_update/public_state auto_pilot 呈现 PASS；伪造 token 拒绝未实测，2026-08-26 部分）
- [x] BOT2-08 托管与既有 bot 混合调度不冲突，整局收束正常（2026-08-26 2 真人含 1 托管 + 2 bot 局 PASS）
- [x] BOT2-09 托管决策在约定时限内提交，不依赖 45s 兜底（2026-08-26 托管后回合 1-3s 推进）
- [x] BOT2-10 `tides_sim` easy/hard 各 20 局 `{ok,20}`（2026-08-26 PASS）

## 4.10 v0.3.1 上线部署演练（DEP）

- [x] DEP-01 deploy/ 差距清单闭环：数据卷、镜像版本 0.3.1、healthz 期望版本、healthcheck、docker 形态 proxy_pass（2026-08-26 PASS；遗留：`server/erl_crash.dump` 未删，已提请主协调）
- [x] DEP-02 生产等价形态 healthz：200 且 version=0.3.0，`/` → 404（2026-08-26 PASS）
- [x] DEP-03 代理形态整局：proxy_sim + `robot.mjs ws://127.0.0.1:18080/ws`（4 真人）与 `--bots=3` 均 SMOKE PASS（2026-08-26 PASS）
- [ ] DEP-04 生产形态仅验证账号终局落盘；游客不进入服务端真实对局且不产生统计
- [x] DEP-05 重启（等价容器重建、数据目录保留）后战绩不丢：`--verify-persist` games=1/ladder=995 一致（2026-08-26 PASS）
- [x] DEP-06 dets 文件删除后重启：空库容错启动、dets 自动重建、可建房打完一局（2026-08-26 PASS；旧库备份于 %TEMP%\opencode\tides_stats.dets.dep06bak）
- [ ] DEP-07 docker compose 真实编排：config 校验 + up -d + dets 落在挂载卷（⬜ **待部署环境**，本机无 docker）
- [ ] DEP-08 容器 force-recreate 重建后战绩仍在（R6 终极验证，⬜ **待部署环境**）
- [ ] DEP-09 真 nginx（docker 形态 proxy_pass=tides-server:9500）反代整局 SMOKE PASS（⬜ **待部署环境**）
- [ ] DEP-10 wss 真链路：`robot.mjs wss://<域名>/ws` + 浏览器 https 整局（⬜ **待公网**，本机不可真验）

本机演练结论（2026-08-26）：DEP-01~06 全 PASS，本机演练通过；DEP-07~10 为 VPS 现场上线门槛，阻塞「生产就绪」。明细见 `acceptance_report_v0.3.1.md`。

## 4.11 v0.3.2 服务端管理（ADM）

- [ ] ADM-01 `tidesctl.bat start` 一键编译+后台启动，重复执行有端口占用保护（2026-08-26：原脚本 **FAIL**，阻塞于 D1 LF-only 换行；CRLF 修复副本行为 PASS，重复 start 端口占用保护 exit=1）
- [x] ADM-02 `tidesctl.bat status` 字段完整（version/uptime_sec/rooms_online/players_online/memory_mb）（2026-08-26 PASS；字段齐全，uptime 27→30 递增；另含 connections_online；version 值仍 0.3.0 见 D2）
- [x] ADM-03 `tidesctl.bat players` 在线玩家列表与实际房间成员一致（含 is_bot/connected）（2026-08-26 PASS；`adm_players_check.mjs` 对拍 room_update/list_rooms 一致，断线后同步清空）
- [ ] ADM-04 `tidesctl.bat stop` 正常停止：进程退出、9500 端口释放、无 crash dump、战绩不损坏（2026-08-26：原脚本 **FAIL**（D1）；修复副本 PASS：PID 退出、端口释放、healthz 连接失败、crash dump 未新增、重启后 verify-persist 7/7）
- [ ] ADM-05 服务端未运行时 status/players 友好提示，退出码非 0（2026-08-26：原脚本 **FAIL**（D1）；修复副本 PASS：`[INFO] server not responding...`，exit=1）
- [ ] ADM-06 未运行时 stop 幂等且不误杀其他进程（2026-08-26：原脚本 **FAIL**（D1）；修复副本 PASS：幂等提示 exit=0；代码审查确认仅杀 9500 监听且 tasklist 校验为 erl；实测未触碰同机另一 erl(25924)）
- [x] ADM-07 管理接口安全：非 localhost 拒绝；配置 admin_token 后缺/错 token 返回 401/403（2026-08-26 PASS：场景A 经 LAN IP 192.168.20.238 实测 /admin/status → 403 且 healthz 仍 200；场景B 当前未配置 admin_token，代码审查 tides_ws_conn.erl:85-118 确认缺/错头→403，localhost 恒放行）
- [x] ADM-08 管理接口接入后全量回归：robot.mjs SMOKE PASS + PC-09 healthz 不变（2026-08-26 PASS：eunit 18/18、sim 20/20、robot ×2、--bots=3 ×3、mem_check 5/5、stats_check 14/14+7/7；healthz 200/version 不变、`/` 404）
- [x] ADM-09 对局中并发调用 status/players 不阻塞对局、P95 < 500ms（2026-08-26 PASS：`adm_concurrent_check.mjs` 对局中并发各 20 次全 200，P95 ≤ 41.8ms，同局 robot SMOKE PASS）
- [x] ADM-10 连续 50 次调用响应正确（200/合法 JSON/Connection close），无泄漏（2026-08-26 PASS：100 次全 200/JSON/close/Content-Length 正确，P95 ≤ 1.8ms，memory 平稳）
- [ ] Linux `tidesctl.sh` 四命令等价可用（⬜ **待 Linux/VPS 环境**）

本机验收结论（2026-08-26）：**有条件通过** —— 服务端管理接口行为级全部 PASS；`deploy\tidesctl.bat`/`start_server.bat` 存在 P0 缺陷 D1（LF-only + UTF-8 中文注释，CP936 下不可解析），修复后重跑脚本链即可转全通过。明细与缺陷 D1~D5 见 `acceptance_report_v0.3.2.md`。

## 4.12 v0.5 主动退出对局（LQ）

- [x] LQ-01 lobby 阶段 `leave_game` 返回 `not_in_game`（2026-09-04 quit_game_check 场景 B / B1 PASS）
- [x] LQ-02 4 人局第 2 回合退出：退出者收 `ack` + `returned_to_lobby`（2026-09-04 场景 A / A1-A2 PASS ×2 轮）
- [x] LQ-03 其余 3 人收 `player_left{reason="quit"}`，座位 `connected=false/auto_pilot=true`（2026-09-04 A3-A4 PASS）
- [x] LQ-04 退出者 reconnect 原房间被拒；可立即 `list_rooms`/`create_room`（2026-09-04 A5-A7 PASS；reconnect 拒绝为通用 error code + message "player has left the game"，见报告 Q1）
- [x] LQ-05 其余 3 人不中断打完收 `game_over` + `returned_to_lobby`（2026-09-04 A8/A10 PASS）
- [x] LQ-06 退出者 `rage_quit=true`、`rank=4`（两轮实测退出者 total 分别为 6/10，均为全场较高仍强制末名）、`ladder_delta=-20`（2026-09-04 A9 PASS）
- [x] LQ-07 退出者 `get_my_stats`：games+1、wins 不变、win_streak=0、recent[0] rank=4/delta=-20（2026-09-04 A11 PASS）
- [x] LQ-08 2 人局退出立即按当前比分终局：scores=2，退出者 rank=2/rage_quit/delta=-10，剩余 rank=1（2026-09-04 场景 B / B2-B5 PASS ×2 轮）
- [x] LQ-09 game_over 阶段 `leave_game` 返回 `already_game_over` 不重复结算（2026-09-04 eunit `leave_game_last_human_finishes_test` PASS）
- [x] LQ-10 断线 grace 到期托管广播 `player_left{reason="disconnect"}`（2026-09-04 代码走查 tides_room.erl:169-172 确认；与 quit 路径同函数广播）
- [x] LQ-11 客户端退出按钮 + 二次确认 + 结算「退出」标记（2026-09-04 代码走查 + `npm run build`（tsc+vite）通过；未做浏览器人工点击）
- [x] v0.5 准入回归：eunit 22/22（含 leave_game 4 用例）+ `tides_sim:run(20)`=`{ok,20}` + `robot.mjs` SMOKE PASS（2026-09-04 全 PASS）

本机验收结论（2026-09-04）：**通过** —— LQ-01~11 全 PASS，无服务端/客户端 bug；遗留观察项 Q1（reconnect 拒绝无专用错误码）与 Q2（eunit 环境噪音日志），均不阻塞。明细见 `acceptance_report_v0.5.md`。

## 5. 交付物

- [ ] 服务端一键启动说明可用（README 快速开始节实测通过）
- [ ] 客户端 `npm install && npm run dev` 可运行并连上服务端
- [ ] 协议文档（shared/protocol.md）与实际行为一致，无文档外隐藏行为

## 验收结论

- 验收版本：________  日期：________  验收人：________
- 结论：⬜ 通过 / ⬜ 有条件通过（遗留问题清单附后）/ ⬜ 不通过
