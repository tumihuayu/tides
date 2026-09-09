#!/bin/sh
# 《潮汐商会》服务端管理入口（Linux）
# 用法: tidesctl.sh <command>
set -u
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$DEPLOY_DIR/../server"
BASE="http://127.0.0.1:9500"
PID_FILE="$SERVER_DIR/tides-server.pid"

cmd="${1:-}"
case "$cmd" in
  ''|help|--help|-h)
    cat <<'EOF'
用法: tidesctl.sh <命令>

命令:
  build      编译 Erlang 服务端
  start      编译并启动服务端
  stop       停止服务端
  status     查看服务端状态
  players    查看在线玩家
  init-db    创建开发数据库与表结构
  reset-dev  清空全部开发业务数据（破坏性操作，不可恢复，仅限开发环境）
  help       显示本帮助

选项:
  -h, --help  显示本帮助
EOF
    exit 0
    ;;
esac

case "$cmd" in
  build)
    cd "$SERVER_DIR"
    erl -noshell -eval 'case make:all() of {error, _} -> halt(5); _ -> halt(0) end.' || exit 1
    ;;
  start)
    exec "$DEPLOY_DIR/start_server.sh"
    ;;
  stop)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE") 2>/dev/null" 2>/dev/null; then
      kill "$(cat "$PID_FILE")" || { echo "[ERROR] failed to stop tides server" >&2; exit 1; }
      rm -f "$PID_FILE"
      echo "[OK] tides server stopped"
      exit 0
    fi
    # pid 文件缺失时按端口找 erl 进程（防误杀：仅杀命令行含 tides/ebin 的 erl）
    PID="$(ss -ltnp 2>/dev/null | grep ':9500 ' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
    if [ -n "$PID" ] && tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null | grep -q 'erl'; then
      kill "$PID" || { echo "[ERROR] failed to stop tides server" >&2; exit 1; }
      echo "[OK] tides server stopped (pid $PID)"
    else
      echo "[INFO] tides server is not running (port 9500 free)"
    fi
    exit 0
    ;;
  status)
    curl -s --max-time 5 "$BASE/admin/status" || { echo; echo "[INFO] server not responding. Is it running? (tidesctl start)"; exit 1; }
    echo
    ;;
  players)
    curl -s --max-time 5 "$BASE/admin/players" || { echo; echo "[INFO] server not responding. Is it running? (tidesctl start)"; exit 1; }
    echo
    ;;
  init-db)
    : "${MYSQL_USER:?MYSQL_USER is required}"
    : "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
    MYSQL_DATABASE="${MYSQL_DATABASE:-tides_dev}"
    MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
    MYSQL_PORT="${MYSQL_PORT:-3306}"
    case "$MYSQL_DATABASE" in tides_dev|tides_test) ;; *) exit 4 ;; esac
    case "$MYSQL_HOST" in 127.0.0.1|localhost) ;; *) exit 4 ;; esac
    command -v mysql >/dev/null 2>&1 || exit 3
    SQL_FILE="$SERVER_DIR/sql/accounts.sql"
    test -f "$SQL_FILE" || exit 11
    export MYSQL_PWD="$MYSQL_PASSWORD"
    mysql --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -e "CREATE DATABASE IF NOT EXISTS $MYSQL_DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || exit 10
    mysql --protocol=tcp -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" "$MYSQL_DATABASE" < "$SQL_FILE" || exit 11
    echo "[OK] database initialized: $MYSQL_DATABASE"
    ;;
  reset-dev)
    if [ "${TIDES_ENV:-}" != "development" ]; then
      echo "[ERROR] reset-dev requires TIDES_ENV=development" >&2
      exit 1
    fi
    MYSQL_DATABASE="${MYSQL_DATABASE:-tides_dev}"
    MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
    case "$MYSQL_DATABASE" in tides_dev|tides_test) ;; *) echo "[ERROR] reset-dev only permits tides_dev/tides_test" >&2; exit 1 ;; esac
    case "$MYSQL_HOST" in 127.0.0.1|localhost) ;; *) echo "[ERROR] reset-dev only permits a local MySQL host" >&2; exit 1 ;; esac
    command -v mysql >/dev/null 2>&1 || { echo "[ERROR] mysql client is required; no data was deleted" >&2; exit 1; }
    : "${MYSQL_USER:?MYSQL_USER is required}"
    : "${MYSQL_PASSWORD:?MYSQL_PASSWORD is required}"
    test -d "$DEPLOY_DIR/../client/dist" || { echo "[ERROR] client/dist is missing; refusing reset" >&2; exit 1; }
    "$DEPLOY_DIR/tidesctl.sh" stop
    export MYSQL_PWD="$MYSQL_PASSWORD"
    TABLES="$(mysql --protocol=tcp -h "$MYSQL_HOST" -u "$MYSQL_USER" -N -B "$MYSQL_DATABASE" -e "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE();")" || { echo "[ERROR] MySQL is unavailable; no legacy files were removed" >&2; exit 1; }
    if [ -n "$TABLES" ]; then
      SQL="SET FOREIGN_KEY_CHECKS=0;"
      while IFS= read -r table; do SQL="$SQL TRUNCATE TABLE $table;"; done <<EOF
$TABLES
EOF
      SQL="$SQL SET FOREIGN_KEY_CHECKS=1;"
      mysql --protocol=tcp -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "$SQL" || { echo "[ERROR] MySQL reset failed; legacy files were not removed" >&2; exit 1; }
    fi
    # Only legacy server data is removed; static client assets are preserved.
    rm -f "$SERVER_DIR/data/tides_stats.dets" "$SERVER_DIR/data/tides_stats.dets."*
    echo "[OK] development database and legacy data cleared"
    ;;
  *)
    echo "用法: tidesctl.sh build|start|stop|status|players|init-db|reset-dev"
    echo "未知命令，请执行 tidesctl.sh help 查看帮助"
    exit 1
    ;;
esac
