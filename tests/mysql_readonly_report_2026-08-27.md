# MySQL 只读检查报告

日期：2026-08-27

## 结果

| 项目 | 结果 | 证据/说明 |
|---|---|---|
| MySQL client driver | 通过 | 本机发现 MySQL client 5.6.39：`mysql.exe` 可执行 |
| MySQL 服务/网络 | 通过 | `MySQL56` 服务为 Running；`127.0.0.1:3306` TCP 可达 |
| MySQL 认证连接 | 阻塞 | 当前进程未提供 `MYSQL_USER`、`MYSQL_DATABASE`、`MYSQL_PASSWORD`；无凭据不能安全完成认证 |
| Erlang MySQL driver | 未通过 | 未发现 `mysql*.beam` 或依赖配置；`tides_mysql` 仅运行时调用 `mysql:query/2`，应用未声明 driver 依赖 |
| Schema | 未验证 | 因认证凭据缺失未执行 schema 查询；仓库仅发现 `server/sql/accounts.sql`，定义 `accounts` 五个字段 |

## 安全边界

- 本次未执行 `reset-dev`、`TRUNCATE`、`DELETE`、`DROP` 或其他写操作。
- 未输出、保存或提交密码；未将密码放入命令行参数。
- 使用 `tests/mysql_readonly_check.mjs` 时，凭据必须由调用进程环境注入；脚本只执行 `SELECT` 和 `information_schema` 元数据查询。

## 阻塞项

1. 由用户/本地运行环境提供隔离开发库的 `MYSQL_USER`、`MYSQL_DATABASE`、`MYSQL_PASSWORD`（必要时 `MYSQL_HOST`、`MYSQL_PORT`）。
2. 为 Erlang 服务端提供并验证兼容的 `mysql` driver；当前 `tides_mysql.erl` 不会自行建立连接，仅消费外部连接配置。
3. 凭据可用后运行 `node tests\\mysql_readonly_check.mjs`，再补充实际版本、认证和 `accounts` schema 结果。
