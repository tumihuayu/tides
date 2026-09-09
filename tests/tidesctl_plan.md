# tidesctl 测试计划

本计划由测试PM维护。`tidesctl_static_check.mjs` 是只读静态门禁，扫描
`deploy/tidesctl.bat`（PowerShell 窗口 ASCII 转发入口）、`deploy/tidesctl.ps1`
（Windows 主入口，PowerShell 5.1）、`deploy/tidesctl.cmd`（CMD 窗口 GBK/CRLF
入口，help 本地显示中文，业务命令转发 ps1）和 `deploy/tidesctl.sh`（POSIX sh），不启动服务、不连接 MySQL、
不执行 `build`、`init-db`、`reset-dev`，也不删除文件。门禁失败时不能以“未测”
冒充通过。

## 静态门禁

| 编号 | 检查 | 验收标准 |
|---|---|---|
| CTL-01 | 入口命令存在 | `.ps1` 与 `.sh` 暴露完整七命令；`.cmd` 为每个业务命令转发 `.ps1`，`.bat` 转发全部参数 |
| CTL-09 | 中文帮助 | `.ps1`、`.cmd` 本地 help 和 `.sh` 帮助均含 `用法`/`命令`/`选项` 标签，逐命令中文描述（命令名保持英文）；`.sh` 另需识别 `help`、`--help`、`-h` 且帮助返回码 0、无副作用；`.bat` 仅负责 ASCII 转发，不重复实现帮助 |
| CTL-13 | reset-dev 警告 | `.ps1`、`.cmd` 本地 help 和 `.sh` 帮助中 `reset-dev` 行含中文破坏性警告（破坏性/危险/不可逆/谨慎） |
| CTL-11 | 脚本编码与换行 | `.bat` 为 ASCII + CRLF；`.ps1` 为 UTF-8 **带 BOM**（PS5.1 无 BOM 会按 ANSI 误读中文）；`.cmd` 为 GBK + CRLF + 无 BOM，且全文件不得出现 `chcp 65001`（cmd 按当前代码页逐字节解析，UTF-8 会截断误执行）；`.sh` 为 UTF-8 + LF + 无 BOM |
| CTL-12 | ps1 PS5.1 兼容 | `.ps1` 非注释行不得出现 PS7+ 语法：`??`、`?.`、`&&`、`||`、`ForEach-Object -Parallel` |
| CTL-02 | 构建/启动错误传播 | 编译器失败、启动失败、端口占用均非 0；`.bat`/`.cmd` 转发入口不吞 `.ps1` 退出码，`.ps1`/`.sh` 保持失败传播 |
| CTL-03 | 停止错误传播 | `taskkill`/`kill` 失败非 0；未运行时可按约定幂等返回 |
| CTL-04 | MySQL 凭据安全 | `.sh` mysql argv 不含密码、`MYSQL_PASSWORD`、`--password` 或 `-p...`；密码只经环境变量继承 |
| CTL-05 | init-db 不清档 | `.sh` `init-db` 只允许初始化 schema/建库所需操作，不得出现 `DROP`、`TRUNCATE`、`DELETE`、`rm` 或 `del` |
| CTL-06 | reset-dev 开发保护 | `.sh` 必须精确为 `TIDES_ENV=development`，数据库仅允许 `tides_dev`/`tides_test`，MySQL host 仅允许 localhost |
| CTL-07 | reset-dev 失败关闭 | MySQL 不可用、认证失败或清档失败时非 0，且在数据库成功前不得删除 legacy DETS |
| CTL-08 | reset-dev 不清静态文件 | `.sh` 要求检查 `client/dist` 存在；只允许删除 `tides_stats.dets` 及其备份，不得删除 `client/dist` |

说明：CTL-02/03 及 CTL-04~08 的 Windows 侧安全约束由行为回归矩阵 RT-01~08
在 ps1/cmd 上实测覆盖；静态门禁只检查 `.bat`/`.cmd` 的转发与退出码传播，不以
wrapper 文本冒充业务安全实现。

运行：

```text
node tests/tidesctl_static_check.mjs
```

## 行为回归矩阵

| 编号 | 平台 | 步骤 | 预期 |
|---|---|---|---|
| RT-01 | Windows(bat+ps1+cmd)/Linux | 执行 `tidesctl build` | 编译成功为 0；故意让编译失败时为非 0 |
| RT-02 | Windows(ps1+cmd)/Linux | 执行 `tidesctl start`，再重复执行 | 首次启动成功；重复启动发现 9500 占用并非 0 |
| RT-03 | Windows(ps1+cmd)/Linux | 服务运行时执行 `stop`；未运行时再次执行 | 正常停止为 0；未运行符合脚本约定且不误杀其他进程 |
| RT-04 | Windows(ps1+cmd)/Linux | 执行 `init-db`，记录数据库表与 DETS、`client/dist` 快照 | 仅完成 schema 初始化；不清空业务表、不删除 DETS 或静态文件 |
| RT-05 | Windows(ps1+cmd)/Linux | 缺少凭据、错误凭据、不可达 MySQL 下执行 `init-db`/`reset-dev` | 非 0；错误向上传播；密码不出现在进程命令行、日志或输出 |
| RT-06 | Windows(ps1+cmd)/Linux | `TIDES_ENV` 设为缺失、production、Development、development | 仅精确 development 允许进入 reset-dev；其余零数据/文件变化 |
| RT-07 | Windows(ps1+cmd)/Linux | development 下分别设置生产数据库名、远程 host | 均在连接/删除前拒绝，非 0，静态资源和 legacy DETS 不变 |
| RT-08 | Windows(ps1+cmd)/Linux | development + 本地隔离库成功 reset-dev | 业务表清空；`client/dist` 内容/校验值不变；仅 legacy DETS 被删除；成功为 0 |
| RT-09 | Windows | 在 PS5.1（`powershell.exe -Version 2` 不可用，需真实 5.1 宿主）执行 `tidesctl.ps1 help` 及各命令，并经 `.bat` 转发执行 | 无解析错误；中文帮助显示正常无乱码；退出码保持一致 |
| RT-10 | Windows | 在 cmd（代码页 936）执行 `tidesctl.cmd help` | 中文帮助显示正常无乱码；无 `chcp` 副作用残留 |

## 通过标准

- `node --check tests/tidesctl_static_check.mjs` 通过。
- `node tests/tidesctl_static_check.mjs` 全部 PASS。
- CTL-01/09/11/12/13 在 ps1、cmd、sh 三个实现/帮助脚本文本上通过，另需 BAT 转发与编码门禁通过；本项为静态门禁，不以当前运行平台代替其他平台结论。
- Windows（ps1 与 cmd 均需）与 Linux 的 RT-01~10 均需在对应原生 shell 实测；本机无法提供 Linux 时标记为待 Linux/VPS，不得将静态 PASS 作为行为 PASS。
