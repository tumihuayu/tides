# Tides server control (Windows PowerShell)
# Usage: .\deploy\tidesctl.ps1 <command>
param(
    [string]$Command = "help"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$ServerDir = Join-Path $ProjectRoot "server"
$BaseUrl = "http://127.0.0.1:9500"

function Get-ListeningPids {
    try {
        @(Get-NetTCPConnection -LocalPort 9500 -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique)
        return
    } catch {
        # Keep compatibility with Windows installations without NetTCPConnection.
        $netstatMatches = netstat -ano | Where-Object {
            $_ -match '^\s*TCP\s+\S+:9500\s+\S+\s+LISTENING\s+(\d+)\s*$'
        }
        @($netstatMatches | ForEach-Object {
            if ($_ -match '^\s*TCP\s+\S+:9500\s+\S+\s+LISTENING\s+(\d+)\s*$') { [int]$Matches[1] }
        } | Select-Object -Unique)
    }
}

function Show-Help {
    Write-Output @'
用法: tidesctl.ps1 <命令>

命令:
  build      编译 Erlang 服务端
  start      编译和启动服务端
  stop       停止服务端
  status     查看服务端状态
  players    查看在线玩家
  init-db    创建开发数据库与表结构
  reset-dev  清空全部开发业务数据（破坏性操作，不可恢复，仅限开发环境）
  help       显示本帮助

选项:
  -h, --help  显示本帮助
'@
}

switch ($Command.ToLower()) {
    "help" { Show-Help; exit 0 }
    "-h"   { Show-Help; exit 0 }
    "--help" { Show-Help; exit 0 }
    "build" {
        Push-Location $ServerDir
        & erl -noshell -eval 'case make:all() of {error, _} -> init:stop(5); _ -> init:stop(0) end.'
        $code = $LASTEXITCODE
        Pop-Location
        if ($code -ne 0) { Write-Error "编译失败"; exit 5 }
        Write-Host "[OK] 编译完成"
        exit 0
    }
    "start" {
        & "$ScriptDir\start_server.bat"
        exit $LASTEXITCODE
    }
    "stop" {
        $listenerPids = @(Get-ListeningPids)
        if ($listenerPids.Count -eq 0) {
            Write-Host "[INFO] 服务端未运行（端口 9500 空闲）"
            exit 0
        }
        foreach ($listenerPid in $listenerPids) {
            $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $listenerPid" -ErrorAction SilentlyContinue
            if (-not $proc -or $proc.ProcessName -notmatch '^(erl|werl)(\.exe)?$') {
                Write-Error "端口 9500 被非 Erlang 进程 PID $listenerPid 占用，拒绝停止"
                exit 1
            }
            if ($processInfo -and $processInfo.CommandLine -and
                $processInfo.CommandLine -notmatch '(?i)(application:ensure_all_started\(tides\)|server[\\/]ebin)') {
                Write-Error "端口 9500 的 Erlang 进程 PID $listenerPid 不是当前 Tides 服务，拒绝停止"
                exit 1
            }
            Stop-Process -Id $listenerPid -Force -ErrorAction SilentlyContinue
            if ($?) {
                # Stop-Process completed; verify the PID below because the process may exit asynchronously.
            } else {
                Write-Error "停止服务端失败 (PID $listenerPid)"
                exit 1
            }
            if (Get-Process -Id $listenerPid -ErrorAction SilentlyContinue) {
                Write-Error "停止服务端失败 (PID $listenerPid)"
                exit 1
            }
        }
        $released = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            if (@(Get-ListeningPids).Count -eq 0) { $released = $true; break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $released) {
            Write-Error "服务进程已请求停止，但端口 9500 仍在监听"
            exit 1
        }
        Write-Host "[OK] 服务端已停止 (PID $($listenerPids -join ', '))"
        exit 0
    }
    "status" {
        try {
            $r = Invoke-RestMethod -Uri "$BaseUrl/admin/status" -TimeoutSec 5
            $r | ConvertTo-Json
            exit 0
        } catch {
            Write-Host "[INFO] 服务端未响应，是否已启动？ (tidesctl.ps1 start)"
            exit 1
        }
    }
    "players" {
        try {
            $r = Invoke-RestMethod -Uri "$BaseUrl/admin/players" -TimeoutSec 5
            $r | ConvertTo-Json
            exit 0
        } catch {
            Write-Host "[INFO] 服务端未响应，是否已启动？ (tidesctl.ps1 start)"
            exit 1
        }
    }
    "init-db" {
        if (-not $env:MYSQL_USER) { Write-Error "MYSQL_USER is required"; exit 4 }
        if (-not $env:MYSQL_PASSWORD) { Write-Error "MYSQL_PASSWORD is required"; exit 4 }
        $db = if ($env:MYSQL_DATABASE) { $env:MYSQL_DATABASE } else { "tides_dev" }
        if ($db -notin @("tides_dev", "tides_test")) { Write-Error "init-db 仅允许 tides_dev 或 tides_test"; exit 4 }
        $host = if ($env:MYSQL_HOST) { $env:MYSQL_HOST } else { "127.0.0.1" }
        if ($host -notin @("127.0.0.1", "localhost")) { Write-Error "init-db 仅允许本机 MySQL"; exit 4 }
        $port = if ($env:MYSQL_PORT) { $env:MYSQL_PORT } else { "3306" }
        $sqlFile = Join-Path $ServerDir "sql\accounts.sql"
        if (-not (Test-Path $sqlFile)) { Write-Error "accounts.sql 缺失"; exit 11 }
        $mysql = Get-Command mysql -ErrorAction SilentlyContinue
        if (-not $mysql) { Write-Error "mysql 客户端缺失"; exit 3 }
        $env:MYSQL_PWD = $env:MYSQL_PASSWORD
        mysql --protocol=tcp -h $host -P $port -u $env:MYSQL_USER -e "CREATE DATABASE IF NOT EXISTS ``$db`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        if ($LASTEXITCODE -ne 0) { Write-Error "无法创建或访问数据库"; exit 10 }
        & mysql --protocol=tcp -h $host -P $port -u $env:MYSQL_USER $db -e "source $sqlFile"
        if ($LASTEXITCODE -ne 0) { Write-Error "数据库 schema 初始化失败"; exit 11 }
        Write-Host "[OK] 数据库已初始化: $db"
        exit 0
    }
    "reset-dev" {
        if ($env:TIDES_ENV -ne "development") { Write-Error "reset-dev 需要 TIDES_ENV=development"; exit 1 }
        if (-not $env:MYSQL_USER) { Write-Error "MYSQL_USER is required"; exit 1 }
        if (-not $env:MYSQL_PASSWORD) { Write-Error "MYSQL_PASSWORD is required"; exit 1 }
        $db = if ($env:MYSQL_DATABASE) { $env:MYSQL_DATABASE } else { "tides_dev" }
        if ($db -notin @("tides_dev", "tides_test")) { Write-Error "reset-dev 仅允许 tides_dev 或 tides_test"; exit 1 }
        $host = if ($env:MYSQL_HOST) { $env:MYSQL_HOST } else { "127.0.0.1" }
        if ($host -notin @("127.0.0.1", "localhost")) { Write-Error "reset-dev 仅允许本机 MySQL"; exit 1 }
        $port = if ($env:MYSQL_PORT) { $env:MYSQL_PORT } else { "3306" }
        $mysql = Get-Command mysql -ErrorAction SilentlyContinue
        if (-not $mysql) { Write-Error "mysql 客户端缺失"; exit 1 }
        if (-not (Test-Path "$ProjectRoot\client\dist")) { Write-Error "client/dist 缺失，拒绝清档"; exit 1 }
        & $MyInvocation.MyCommand.Path stop
        if ($LASTEXITCODE -ne 0) { exit 1 }
        $env:MYSQL_PWD = $env:MYSQL_PASSWORD
        $tables = mysql --protocol=tcp -h $host -P $port -u $env:MYSQL_USER -N -B $db -e "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE();"
        if ($LASTEXITCODE -ne 0) { Write-Error "MySQL 不可用，未删除旧数据"; exit 1 }
        if ($tables) {
            $truncateSql = "SET FOREIGN_KEY_CHECKS=0;"
            foreach ($t in $tables) { $truncateSql += " TRUNCATE TABLE ``$t``;" }
            $truncateSql += " SET FOREIGN_KEY_CHECKS=1;"
            mysql --protocol=tcp -h $host -P $port -u $env:MYSQL_USER $db -e $truncateSql
            if ($LASTEXITCODE -ne 0) { Write-Error "MySQL 清档失败"; exit 1 }
        }
        $dets = Join-Path $ServerDir "data\tides_stats.dets"
        if (Test-Path $dets) {
            Remove-Item -Path "$dets*" -Force -ErrorAction SilentlyContinue
            if (Test-Path $dets) { Write-Error "删除旧 DETS 失败"; exit 1 }
        }
        Write-Host "[OK] 开发数据库与旧数据已清空"
        exit 0
    }
    default {
        Write-Host "用法: tidesctl.ps1 build|start|stop|status|players|init-db|reset-dev"
        Write-Host "未知命令，请执行 tidesctl.ps1 help 查看帮助"
        exit 1
    }
}
