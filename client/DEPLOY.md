# 《潮汐商会》客户端部署说明

同一个 `npm run build` 产物（`dist/`）同时支持以下三种部署形态，无需重新构建。客户端按优先级解析 WS 地址：`?ws=` URL 参数 > 页面手动填写（localStorage）> 构建期 `VITE_WS_URL` > 按页面地址自动推导。静态资源使用相对/根路径，部署在域名根路径即可，`base` 无需特殊设置。

## A. 外网 nginx 同域反代（推荐，开箱即用）

`dist/` 由 nginx 托管在 `https://tides.cn`，并将 `/ws` 反代到服务端 `127.0.0.1:9500`：

```nginx
server {
    listen 443 ssl;
    server_name tides.cn;
    root /var/www/tides/dist;

    location /ws {
        proxy_pass http://127.0.0.1:9500;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }
}
```

页面以 https 打开，客户端自动推导为 `wss://tides.cn/ws`，**无需任何配置**。

## B. 内网直连

- 开发：`npm run dev --host`（已默认带 `--host`），其他设备访问 `http://<IP>:5173`，自动推导 `ws://<IP>:9500/ws`。
- 或任意静态服务托管 `dist/`（如 `npm run preview --host`、nginx、python -m http.server），访问 `http://<IP>:<端口>` 同样自动推导。
- 需放行 TCP 9500 与页面端口。
- 自动推导例外：页面 hostname 为 localhost/127.0.0.1 时固定用 `ws://localhost:9500/ws`。

## C. WS 与页面分离（不同域）

页面在 A 域、WS 在 B 域时，构建前设置：

```bat
copy .env.production.example .env.production
:: 编辑 .env.production: VITE_WS_URL=wss://ws.tides.cn/ws
npm run build
```

此时所有用户默认连接该地址（来源显示"构建"）。

## 调试与手动覆盖

- 任意环境可用 `?ws=ws://host:9500/ws` URL 参数临时指定（最高优先级，来源显示"调试参数"）。
- 大厅"服务器地址"输入框可手动填写并"应用"（来源显示"手动"）；点"恢复自动"清除手动覆盖并按当前页面重新推导、自动重连。
