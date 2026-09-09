# 《潮汐商会》上线手册：从 0 到 https://tides.cn

架构：浏览器 → `https://tides.cn`（nginx/caddy 解除 TLS）→ 明文 `ws://127.0.0.1:9500/ws` → Erlang/OTP 服务端。
Erlang 侧不做 TLS；代理负责证书、`/ws` WebSocket 转发、`/healthz` 健康检查转发。

## 部署件清单（本目录）
| 文件 | 用途 |
|---|---|
| `nginx.conf` | 生产反代：443 TLS、静态站点、`/ws` 长连接反代、`/healthz`、80 跳 443 |
| `Caddyfile` | nginx 的简化替代（自动 TLS） |
| `Dockerfile.server` | Erlang 服务端镜像（erlang:24，编译+运行） |
| `docker-compose.yml` | tides-server + nginx 一键编排 |
| `start_server.bat` / `start_server.sh` | 宿主机直装时的一键编译+启动（Windows 独立操作窗口，Linux 后台日志） |

## 一、域名与服务器
1. 购买域名 `tides.cn`（任意注册商）。
2. 买一台 VPS（1C1G 即可），开放安全组/防火墙 TCP 80 与 443。
3. DNS 添加 **A 记录**：`tides.cn → VPS 公网 IP`，等待生效（`nslookup tides.cn`）。

## 二、宿主机直装（方案 A）
```sh
# 1) 装 Erlang（OTP 20+，推荐 24）与 nginx
sudo apt update && sudo apt install -y erlang nginx certbot python3-certbot-nginx

# 2) 上传代码到 VPS（server/ 与 shared/ 必需），构建前端后上传 client/dist
cd tides/client && npm install && npm run build

# 3) 前端静态文件放到 /usr/share/nginx/html（或改 nginx.conf 的 root）
sudo rsync -a tides/client/dist/ /usr/share/nginx/html/

# 4) 签发证书（80 跳转段先生效即可，certbot 会自动改好 443）
sudo cp tides/deploy/nginx.conf /etc/nginx/conf.d/tides.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d tides.cn

# 5) 启动游戏服务端
cd tides && sh deploy/start_server.sh

# 6) 健康检查
curl http://127.0.0.1:9500/healthz
curl https://tides.cn/healthz
```

### Caddy 替代（免 certbot 手动签发）
```sh
sudo apt install -y caddy
sudo cp tides/deploy/Caddyfile /etc/caddy/Caddyfile
sudo rsync -a tides/client/dist/ /var/www/tides/
sudo systemctl reload caddy   # 自动申请/续期 tides.cn 证书
```

## 三、Docker（方案 B）
```sh
# 前置：docker + docker compose 插件；client/dist 已构建；
# 宿主机已用 certbot 签好证书（certbot certonly --standalone -d tides.cn）。
cd tides
# docker 网络内 nginx 访问服务端走服务名：compose 已自动挂载 deploy/nginx.docker.conf
# （proxy_pass 指向 tides-server:9500），无需手工改配置。
docker compose -f deploy/docker-compose.yml up -d --build
curl http://127.0.0.1:9500/healthz
```
战绩持久化：compose 已挂 named volume `tides-data` 到 `/app/server/data`（dets 文件），
容器重建/升级不丢战绩；删除该卷（`docker compose down -v`）将清空全服战绩，慎操作。

## 四、验证清单
1. `curl http://127.0.0.1:9500/healthz` → `200 {"ok":true,"service":"tides","version":...}`，version 应与 `tides_server:version()` 当前值一致
2. `curl -o /dev/null -w '%{http_code}' http://127.0.0.1:9500/` → `404`
3. `curl https://tides.cn/healthz` → 同上 200（走代理）
4. `curl -I https://tides.cn` → 200，首页加载正常；http:// 自动跳 https
5. wss 连接：`node tests/robot.mjs wss://tides.cn/ws` → `SMOKE PASS`
6. 浏览器打开 `https://tides.cn`，服务器地址填 `wss://tides.cn/ws`，建房跑一局

## 五、内外网两套访问
- **内网/开发模式**：无需代理与证书。直接启动服务端（`start_server.bat/.sh` 或
  `erl -pa ebin -eval "tides_app:start()."`），客户端服务器地址填 `ws://<主机IP>:9500/ws`。
  客户端 dev 用 `npm run dev`（已 `--host`）。
- **外网/生产模式**：一律走 `https://tides.cn` + `wss://tides.cn/ws`。
  服务端只监听本机（compose 已把 9500 绑到 `127.0.0.1`；如需更严格可在
  `shared/data/config.json` 设 `"bind_ip": "127.0.0.1"`，非法值会告警并回退 0.0.0.0）。

## 五点五、日常管理命令（tidesctl）
```bat
:: Windows
deploy\tidesctl.bat start     :: 编译并在独立 Erlang 操作窗口启动
deploy\tidesctl.bat stop      :: 停止（防误杀：仅杀 erl 进程）
deploy\tidesctl.bat status    :: 版本/运行时长/房间数/在线人数/内存
deploy\tidesctl.bat players   :: 在线玩家列表（含人机/托管标记）
```
Linux 用 `deploy/tidesctl.sh`，参数相同。
管理接口为 HTTP `/admin/status`、`/admin/players`，仅 localhost 可访问；
远程管理需在 `shared/data/config.json` 配 `"admin_token"` 并携 `X-Admin-Token` 头。
**反代不得暴露 `/admin/*`**（现有 nginx.conf/nginx.docker.conf/Caddyfile 均未反代该路径，勿新增）。

## 六、运维要点
- 证书续期：certbot 装好后 `certbot renew` 由 systemd timer 自动跑；Caddy 全自动。
- 健康检查：外部监控探 `https://tides.cn/healthz`，内部探 `http://127.0.0.1:9500/healthz`。
- 日志：Windows 直装模式查看独立 Erlang 操作窗口；Linux 直装模式看 `server/tides-server.log`（nohup）；docker 用
  `docker compose -f deploy/docker-compose.yml logs -f tides-server`。
- WebSocket 长连接：nginx 已设 `proxy_read_timeout 3600s`；客户端有 ping/pong 心跳兜底。
