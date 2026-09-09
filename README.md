# 潮汐商会（Tides）

《潮汐商会》是一个 2-4 人远程联机的轻中策卡牌桌游 MVP。浏览器客户端负责界面与输入，Erlang/OTP 服务端负责大厅、房间、规则裁定、断线托管和结算；联机传输使用 WebSocket + JSON。

本文是首次接手项目的入口。按“准备环境 → 启动服务 → 打开客户端 → 注册并建房”即可完成本地试玩；深入开发时再按文末索引阅读规则、协议、测试和部署手册。

## 1. 能力与当前版本

- 服务端版本：`0.3.2`
- 客户端：Vite + TypeScript，无前端框架和运行时第三方依赖
- 服务端：Erlang/OTP，源码内含 JSON、WebSocket 和 MySQL 适配模块
- 对局：2-4 人，房主创建房间，玩家准备后开始；支持房间内 Bot
- 账号：注册、登录、session 恢复、修改密码
- 对局保障：权威服务端裁定、行动去重、断线重连、超时和断线 AI 托管
- 数据：卡牌/港口/事件/规则配置在 `shared/data/`；战绩默认使用服务端 DETS 文件持久化

## 2. 环境要求

| 组件 | 最低要求 | 用途 |
|---|---|---|
| Windows 或 Linux/macOS | 可运行脚本和命令行 | 开发环境 |
| Erlang/OTP | 20+，推荐 24 | 编译和运行服务端 |
| Node.js | 22+，推荐 24 | 客户端构建；测试脚本使用原生 WebSocket |
| npm | 随 Node.js 安装 | 安装客户端依赖 |
| MySQL | 仅账号/数据库功能需要 | 注册、登录、账号统计持久化 |
| MySQL CLI | 仅执行 `init-db` 需要 | 创建数据库和表 |

验证安装：

```powershell
erl -version
node --version
npm --version
mysql --version       # 仅使用数据库功能时检查
```

服务端不需要额外下载 Erlang 库。客户端依赖锁定在 `client/package-lock.json`，不要直接提交 `node_modules/`。

## 3. 五分钟本地启动

### Windows

在仓库根目录执行：

```bat
deploy\start_server.bat
cd client
npm install
npm run dev
```

然后浏览器打开 <http://localhost:5173>。首次使用流程为：完成客户端教程 → 注册账号 → 登录 → 创建房间 → 添加 Bot 或邀请玩家 → 全员准备 → 房主开始。

服务端脚本会自动编译、生成 `server/ebin/tides.app` 并在独立 Erlang 窗口启动。健康检查：

```bat
curl http://127.0.0.1:9500/healthz
```

### Linux/macOS

```sh
./deploy/start_server.sh
cd client
npm install
npm run dev
```

浏览器打开 <http://localhost:5173>。服务端日志在 `server/tides-server.log`，PID 在 `server/tides-server.pid`；可按脚本输出的命令停止进程。

### 手动启动服务端

```sh
cd server
erl -noshell -eval 'case make:all() of {error, _} -> halt(1); _ -> halt(0) end.'
cp src/tides.app.src ebin/tides.app       # Windows 使用 copy
erl -pa ebin -eval 'tides_app:start().'
```

服务端从 `shared/data/config.json` 读取端口和游戏参数。服务端启动目录应为 `server/`，这样数据目录探测最可靠。

## 4. 数据库配置（账号功能）

不配置 MySQL 时，服务端仍可编译、启动，并可运行规则单元测试和自玩模拟；但客户端的注册/登录/正式房间流程需要账号服务，因此首次完整试玩应准备一个本地 MySQL 数据库。

1. 复制配置模板并填写本机开发库凭据：

   ```bat
   copy config\database.env.example config\database.env
   ```

2. `config/database.env` 已被 `.gitignore` 忽略，禁止提交真实密码。服务端会自动读取 `MYSQL_*` 配置；环境变量优先级为 `TIDES_MYSQL_*` > `MYSQL_*` > `config/database.env`。

3. 初始化数据库。Windows PowerShell 可先加载配置：

   ```powershell
   Get-Content .\config\database.env | ForEach-Object {
       if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
           [Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), 'Process')
       }
   }
   deploy\tidesctl.bat init-db
   ```

   Linux/macOS：

   ```sh
   set -a; . ./config/database.env; set +a
   ./deploy/tidesctl.sh init-db
   ```

`init-db` 只允许本机 MySQL 和 `tides_dev`/`tides_test` 数据库，并使用 `server/sql/accounts.sql` 创建基础表。历史数据库的升级脚本见 `server/sql/migrations/`。开发清档命令 `reset-dev` 会删除全部开发数据，必须显式设置 `TIDES_ENV=development`，使用前确认数据库名称。

## 5. 地址、端口与客户端配置

| 服务 | 默认地址 | 说明 |
|---|---|---|
| 游戏服务端 | `0.0.0.0:9500` | WebSocket ` /ws`，HTTP ` /healthz` |
| Vite 开发服 | `0.0.0.0:5173` | `npm run dev` |
| Vite 预览服 | `0.0.0.0:4173` | `npm run preview` |

客户端 WebSocket 地址按以下优先级解析：

1. URL 参数：`http://localhost:5173/?ws=ws://host:9500/ws`
2. 大厅手动填写并应用的地址（保存在浏览器 `localStorage`）
3. 构建环境变量 `VITE_WS_URL`
4. 根据页面地址自动推导：本机页面使用 `ws://localhost:9500/ws`，局域网页面使用 `ws://<页面主机>:9500/ws`，HTTPS 页面使用 `wss://<域名>/ws`

局域网联机时，主机启动两个服务，其他设备打开 `http://<主机IP>:5173`。确认 Windows 防火墙放行 TCP `9500` 和 `5173`。生产 HTTPS 页面不能连接明文 `ws://`，必须由 nginx/Caddy 反代为 `wss://`。

## 6. 编译、测试与验收

服务端编译：

```sh
cd server
erl -noshell -eval 'case make:all() of {error, _} -> halt(1); _ -> halt(0) end.'
```

服务端单元测试和 20 局自玩模拟：

```sh
cd server
erl -noshell -pa ebin -eval 'case eunit:test([tides_json_tests, tides_game_tests]) of ok -> tides_data:ensure_loaded(), case tides_sim:run(20) of {ok,20} -> init:stop(0); _ -> init:stop(1) end; _ -> init:stop(2) end.'
```

客户端类型检查和生产构建：

```sh
cd client
npm install
npm run build
```

端到端机器人要求服务端已启动，并提供隔离的账号 fixture；没有 fixture 时应输出 `BLOCKED`，不会以游客身份创建正式房间：

```sh
node tests/robot.mjs
node tests/robot.mjs --bots=3
```

完整测试资产、退出码、账号 fixture、代理模拟和验收流程见 [`tests/README.md`](tests/README.md)。

## 7. 项目结构

```text
tides/
├─ client/                 Web 客户端
│  ├─ src/                  页面、网络、游戏、教程和样式
│  ├─ package.json          npm 脚本与依赖
│  └─ DEPLOY.md             客户端部署和 WS 地址规则
├─ server/                 Erlang/OTP 服务端
│  ├─ src/                  应用、监督树、大厅、房间、规则、账号、统计、WebSocket
│  ├─ sql/                  账号 schema 和数据库迁移
│  ├─ ebin/                 编译产物，不是源码
│  └─ data/                 DETS 战绩文件
├─ shared/                 客户端与服务端共同依赖的事实源
│  ├─ data/                 config/cards/contracts/events/ports JSON
│  └─ protocol.md           WebSocket JSON 协议，协议修改的最高依据
├─ docs/                   规则、数值、UI、美术和玩法设计
├─ tests/                  单元/验收计划、冒烟和回归脚本
├─ config/                 本地环境配置模板；真实 database.env 不提交
├─ deploy/                 启动、运维、Docker、nginx/Caddy 配置
├─ RUNBOOK.md              日常运行、排障和运维速查
└─ AGENTS.md               协作角色和目录写入边界
```

### 代码阅读顺序

1. [`shared/protocol.md`](shared/protocol.md)：消息信封、认证、房间和对局协议。
2. [`shared/data/config.json`](shared/data/config.json)：端口、人数、回合、超时和数值配置。
3. `server/src/tides_app.erl`、`tides_sup.erl`、`tides_ws_conn.erl`：服务启动和请求入口。
4. `server/src/tides_lobby.erl`、`tides_room.erl`、`tides_game.erl`：大厅、房间和规则核心。
5. `client/src/main.ts`、`net.ts`、`lobby.ts`、`game.ts`：客户端状态、网络和页面流程。

## 8. 部署与运维入口

- 生产部署：[`deploy/README.md`](deploy/README.md)，包含 VPS、nginx、Caddy、Docker Compose、TLS 和健康检查。
- 客户端单独部署：[`client/DEPLOY.md`](client/DEPLOY.md)。
- 日常启动/停止/状态/在线玩家：`deploy/tidesctl.bat`（Windows）或 `deploy/tidesctl.sh`（Linux）。
- 快速排障：[`RUNBOOK.md`](RUNBOOK.md)。
- 账号和统计使用 MySQL；对局统计另有服务端 DETS 文件，生产 Docker 使用 named volume 持久化。

管理接口 `/admin/status` 和 `/admin/players` 默认仅供 localhost 使用。反向代理不得暴露 `/admin/*`；需要远程管理时必须配置 token，并同步检查代理规则。

## 9. 开发约定

- `shared/` 是协议和数值的唯一事实来源。修改后需同步检查服务端、客户端和测试脚本。
- 服务端是对局权威，客户端输入不能视为可信状态。
- 不提交 `config/database.env`、密码、session、房间 token 或运行时数据。
- 修改服务端后至少执行编译、服务端单元测试和自玩模拟；修改客户端后至少执行 `npm run build`。
- 目录协作边界和“多 agent 执行”触发规则以 [`AGENTS.md`](AGENTS.md) 为准。
