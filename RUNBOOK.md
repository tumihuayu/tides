# 《潮汐商会》运行手册 v1.0（2026-08-26）

适用版本：服务端 0.3.2 / 客户端 dist 最新构建。
仓库根：当前 Git 仓库目录（以下命令均以仓库根为基准）

## 0. 端口与地址总览
| 用途 | 端口 | 说明 |
|---|---|---|
| 游戏服务端 (WebSocket+HTTP) | 9500 | `/ws` 握手，`GET /healthz` 健康检查 |
| 客户端开发服 | 5173 | `npm run dev`（已带 --host） |
| 客户端预览服 | 4173 | `npm run preview` |
| 代理模拟器（测试） | 18080 | `tests/proxy_sim.mjs` |

## 1. 环境要求
- Erlang/OTP 20+（推荐 24，`erl -version` 可验证）
- Node.js 22+（推荐 24，robot 依赖内置 WebSocket）
- Windows 防火墙入站规则（本机已配置）：TCP 9500 / 5173 / 4173

## 2. 快速开始（本机试玩）
```bat
:: 1. 启动服务端（自动编译+后台运行，含端口占用检测）
deploy\start_server.bat

:: 2. 启动客户端
cd client
npm install    :: 首次
npm run dev

:: 3. 浏览器打开
http://localhost:5173
```
首次访问先完成客户端教程并注册账号；登录后创建房间 → 邀请其他已登录玩家加入 → 全员准备 → 房主开始。

## 3. 局域网多人
1. 主机按第 2 节启动服务端与客户端。
2. 主机查 IP：`ipconfig`（当前为 192.168.20.238，变化时以实际为准）。
3. 其他玩家浏览器打开 `http://<主机IP>:5173`。
   - WS 地址**自动推导**为 `ws://<主机IP>:9500/ws`，无需手填；大厅地址行会显示"生效地址（自动）"。
4. 加入方式二选一：输入房间码，或在"在线房间"列表点"加入"。

连不上时按第 6 节 FAQ 排查。

## 4. 外网 / 正式上线（https://tides.cn）
详细手册：`deploy/README.md`。概要：
1. 购买域名（如 tides.cn）+ 一台公网 VPS。
2. DNS A 记录指向 VPS。
3. VPS 上放置：`client/dist`（执行 `npm run build` 生成）、`server/`、`shared/data/`。
4. 方式一（推荐）：`docker compose up -d`（使用 `deploy/docker-compose.yml`，nginx 自动反代）。
   方式二：手动 nginx + certbot（配置见 `deploy/nginx.conf`），或 Caddy（`deploy/Caddyfile`，自动 TLS）。
5. 玩家只需打开 `https://tides.cn`，客户端自动走 `wss://tides.cn/ws`，无需任何设置。
6. 验收：`curl https://tides.cn/healthz` 返回 ok；`node tests/robot.mjs wss://tides.cn/ws` PASS。

> 注意：https 页面无法使用 `ws://`（浏览器混合内容限制），外网必须经代理走 wss。

## 5. 日常运维
```bat
:: 查看服务端是否在运行
netstat -ano | findstr ":9500" | findstr "LISTENING"

:: 健康检查（应返回 {"ok":true,...}）
curl http://127.0.0.1:9500/healthz

:: 停止服务端（PID 从上一条命令查出）
taskkill /PID <PID> /F

:: 重新编译（修改 server/src 后）
cd server
erl -noshell -eval "make:all()" -s init stop

:: 单元测试 + 20局自玩模拟（退出码 0 即通过）
erl -noshell -pa ebin -eval 'case eunit:test([tides_json_tests, tides_game_tests]) of ok -> tides_data:ensure_loaded(), case tides_sim:run(20) of {ok,20} -> init:stop(0); _ -> init:stop(1) end; _ -> init:stop(2) end.'

:: 4人整局冒烟（需服务端已启动及账号测试 fixture）
node tests\robot.mjs

:: 反代形态验证（模拟 nginx，需先 build 客户端）
node tests\proxy_sim.mjs
node tests\robot.mjs ws://127.0.0.1:18080/ws
```

## 6. FAQ（连不上排查决策树）
1. **先确认服务端活着**：`netstat -ano | findstr ":9500"` 无 LISTENING → 服务端没启动或已崩溃，重新跑 `start_server.bat`。
   - 这是最常见原因（上次局域网失败即此因）。
2. **端口被旧进程占用**：start 脚本会提示 PID；`taskkill /PID <PID> /F` 后重启。残留旧 erl 会导致新代码不生效（曾发生连到旧 VM 的事故）。
3. **本机能连、别的设备不能连**：检查防火墙规则是否存在 `netsh advfirewall firewall show rule name="Tides Game Server 9500"`；确认客户端是 `npm run dev`（带 --host）而非只监听 localhost。
4. **页面能开但提示连接失败**：看大厅"服务器地址"行的生效地址与来源；手滑填错过就点"恢复自动"。
5. **https 页面连不上 ws**：混合内容限制，必须 wss（外网走代理，见第 4 节）。
6. **robot 失败但真人能玩**：先看失败行原因；`consecutive errors` 多为协议字段变更，需同步 robot 与服务端。

## 7. 相关文档索引
| 文档 | 内容 |
|---|---|
| `shared/protocol.md` | 联机协议（含仲裁细则，最高优先级） |
| `deploy/README.md` | 上线手册（域名/VPS/nginx/docker） |
| `client/DEPLOY.md` | 客户端三种部署形态与地址推导规则 |
| `docs/01_rulebook_v1.0.md` | 游戏规则书 |
| `tests/test_plan.md` | 60 条测试用例 |
| `tests/acceptance_checklist.md` | MVP 验收清单 |
