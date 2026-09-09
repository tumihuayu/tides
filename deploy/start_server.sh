#!/bin/sh
# 《潮汐商会》服务端一键编译+后台启动（Linux）
set -e
cd "$(dirname "$0")/../server"

PORT=9500

# 端口占用检测
if command -v ss >/dev/null 2>&1; then
    if ss -ltn | grep -q ":$PORT "; then
        echo "[ERROR] port $PORT already in use:"
        ss -ltnp | grep ":$PORT " || true
        exit 1
    fi
elif command -v netstat >/dev/null 2>&1; then
    if netstat -ltn | grep -q ":$PORT "; then
        echo "[ERROR] port $PORT already in use:"
        netstat -ltnp 2>/dev/null | grep ":$PORT " || true
        exit 1
    fi
fi

echo "[1/2] compiling..."
erl -noshell -eval 'case make:all() of {error, _} -> halt(5); _ -> halt(0) end.'
cp src/tides.app.src ebin/tides.app

echo "[2/2] starting in background (port from shared/data/config.json, default $PORT)..."
nohup erl -noshell -pa ebin -eval "tides_app:start()." > tides-server.log 2>&1 &
echo $! > tides-server.pid
sleep 2

if kill -0 "$(cat tides-server.pid)" 2>/dev/null; then
    echo "[OK] tides server is up (pid $(cat tides-server.pid)). healthz: curl http://127.0.0.1:$PORT/healthz"
    echo "     stop with: kill $(cat tides-server.pid)"
else
    echo "[ERROR] server failed to start, see tides-server.log"
    exit 1
fi
