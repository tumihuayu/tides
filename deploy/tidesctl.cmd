@echo off
rem Tides server control for the Windows CMD prompt.
rem Chinese help is emitted by this GBK-compatible wrapper.
setlocal
set "SCRIPT_DIR=%~dp0"

if "%~1"=="" goto help
if /i "%~1"=="help" goto help
if /i "%~1"=="--help" goto help
if /i "%~1"=="-h" goto help
if /i "%~1"=="build" goto build
if /i "%~1"=="start" goto start
if /i "%~1"=="stop" goto stop
if /i "%~1"=="status" goto status
if /i "%~1"=="players" goto players
if /i "%~1"=="init-db" goto init-db
if /i "%~1"=="reset-dev" goto reset-dev
goto unknown

:help
echo 用法: tidesctl.cmd ^<命令^>
echo.
echo 命令:
echo   build      编译 Erlang 服务端
echo   start      编译和启动服务端
echo   stop       停止服务端
echo   status     查看服务端状态
echo   players    查看在线玩家
echo   init-db    创建开发数据库与表结构
echo   reset-dev  清空全部开发业务数据（破坏性操作，不可恢复，仅限开发环境）
echo   help       显示本帮助
echo.
echo 选项:
echo   -h, --help  显示本帮助
exit /b 0

:build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" build
exit /b %ERRORLEVEL%

:start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" start
exit /b %ERRORLEVEL%

:stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" stop
exit /b %ERRORLEVEL%

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" status
exit /b %ERRORLEVEL%

:players
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" players
exit /b %ERRORLEVEL%

:init-db
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" init-db
exit /b %ERRORLEVEL%

:reset-dev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" reset-dev
exit /b %ERRORLEVEL%

:unknown
echo 用法: tidesctl.cmd build^|start^|stop^|status^|players^|init-db^|reset-dev
echo 未知命令，请执行 tidesctl.cmd help 查看帮助
exit /b 1
