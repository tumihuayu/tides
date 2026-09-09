# v0.3.1 验收报告 — 上线部署演练（DEP-01~06，本机可验级）

- 验收日期：2026-08-26
- 验收人：测试PM（本机部署演练）
- 被测版本：服务端 healthz 上报 `version: "0.3.0"`；部署件镜像 tag `tides-server:0.3.1`
- 环境：本机 Windows，**无 docker/无公网**。按 test_plan.md §9 分诊的「本机可验级」路径执行：宿主机直装形态（等价容器内单进程）+ `tests/proxy_sim.mjs` 反代隧道（127.0.0.1:18080 → 127.0.0.1:9500，等价 nginx `/ws`）。
- 演练进程：服务端 PID 28012（DEP-02 起）→ 30252（DEP-05 重启）→ 10440（DEP-06 重启，演练结束保留运行）；proxy_sim PID 18200（演练结束已关闭）。

## 1. DEP 明细

| 用例 | 结果 | 证据 |
|---|---|---|
| DEP-01 deploy/ 差距闭环 | ✅ PASS（附 1 项遗留，见 §3-R1） | 静态审查：`docker-compose.yml` 含 named volume `tides-data:/app/server/data`、healthcheck 段（erl httpc 探 healthz）、`image: tides-server:0.3.1`、9500 仅绑 127.0.0.1；`Dockerfile.server` 含 `RUN mkdir -p /app/server/data`；新增 `nginx.docker.conf`（proxy_pass=`http://tides-server:9500`）并已由 compose 挂载；`deploy/README.md` 已更新（nginx.docker.conf 说明、数据卷持久化与 `down -v` 清库警示） |
| DEP-02 生产等价形态 healthz | ✅ PASS | taskkill 旧 erl(13212) → 重新编译 `make:all()` up_to_date → 新 beam 后台启动(28012)；`curl http://127.0.0.1:9500/healthz` → `{"ok":true,"service":"tides","version":"0.3.0"}`；`GET /` → 404 |
| DEP-03 代理形态整局 | ✅ PASS | client/dist 已 build（17:38，未重建）；proxy_sim 起 18080；`robot.mjs ws://127.0.0.1:18080/ws`（4 真人，房 UWXC）SMOKE PASS；`robot.mjs --bots=3 ws://127.0.0.1:18080/ws`（房 WV2L）SMOKE PASS |
| DEP-04 终局落盘 | ✅ PASS（账号历史口径） | 旧记录仅证明带账号身份的 `stats_check.mjs`（1 账号 + 3 Bot）落盘。最终身份模型下游客无 `role_id`/`PlayerProcess`、不进入真实对战且统计为零；该历史记录不作为游客验收证据。 |
| DEP-05 重启不丢 | ✅ PASS | taskkill 28012 → 重启(30252) → healthz 200 → `stats_check.mjs --verify-persist ws://127.0.0.1:18080/ws`：LDR-02 PASS，同 token games=1/ladder=995 与重启前一致，7/7 PASS（等价「容器重建但数据卷保留不丢战绩」） |
| DEP-06 删库容错 | ✅ PASS | 停服 → dets 备份至 `%TEMP%\opencode\tides_stats.dets.dep06bak` 后删除 → 重启(10440)：healthz 200（空库不崩溃）、`server/data/tides_stats.dets` 自动重建；经代理 `robot.mjs --bots=3` 整局 SMOKE PASS（房 9WW2），局后 dets mtime 更新（19:16:41）——等价容器无卷重建灾难容错路径 |

## 2. 结论

- **本机演练（DEP-01~06）：全部 PASS，本机演练通过。**
- 本结论不覆盖「生产就绪」：DEP-07~10 需 VPS/docker 现场执行，见 §4 门槛清单。
- 演练后状态：proxy_sim 已关闭；服务端保留运行（PID 10440）；当前 `server/data/tides_stats.dets` 为 DEP-06 自动重建的演练库（旧演练数据备份在 `%TEMP%\opencode\tides_stats.dets.dep06bak`，如需可回拷）。
- 注意：DEP-06 删库后，`.stats_check_state.json` 中的 token 在新库无数据；下次跑 `stats_check.mjs` 全量会自动重写 state 文件，不影响后续回归。

## 3. 遗留与观察

- **R1（DEP-01 遗留，提请主协调）**：主协调称 `erl_crash.dump` 已删，但 `server/erl_crash.dump`（147698 字节，mtime 2026-08-26 18:32）仍存在。属 server/ 目录，测试PM 无权代删，请主协调清理（不影响部署件正确性，DEP-01 其余项全闭环）。
- **R2（观察，非缺陷）**：演练中 leaderboard `entries=0` 一度引起注意——已核源码 `tides_stats.erl:150`，入榜门槛 `?MIN_GAMES_BOARD`（games≥5，与 LDR-04 既定语义一致），演练账号 games=1 不入榜属预期行为。
- **R3（已知限制）**：DEP-03 的 proxy_sim 为 http 明文隧道；wss/TLS 真链路本机不可验（无公网域名无法签发受信证书），由 DEP-10 覆盖。

## 4. DEP-07~10：VPS 现场上线门槛清单（阻塞「生产就绪」）

| 项 | 前置 | 现场动作 | 通过标准 |
|---|---|---|---|
| DEP-07 | VPS 装好 docker + compose 插件；client/dist 已 build | `docker compose -f deploy/docker-compose.yml config` 校验；`up -d --build`；`curl http://127.0.0.1:9500/healthz`；`docker exec` 查挂载卷 | config 校验通过；容器内 healthz 200；`/app/server/data/tides_stats.dets` 位于 named volume（非容器层） |
| DEP-08 | DEP-07 后 | 打一局 → `docker compose up -d --build --force-recreate` 重建 tides-server → 同 token 查战绩 | 重建后战绩仍在（R6 修复的终极验证，DEP-05 的真实形态） |
| DEP-09 | DEP-07 后 | 真 nginx（容器或宿主机，proxy_pass=tides-server:9500）下 `node tests/robot.mjs http://<nginx>/ws` | SMOKE PASS，复现 DEP-03 结论 |
| DEP-10 | 域名 A 记录生效 + 证书已签 | `node tests/robot.mjs wss://tides.cn/ws`；浏览器打开 `https://tides.cn` 填 `wss://tides.cn/ws` 跑一局 | SMOKE PASS；浏览器 https 整局无断连；http:// 自动跳 https |
