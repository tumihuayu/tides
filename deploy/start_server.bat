@echo off
rem Tides server one-click build and start (Windows)
setlocal
set "SERVER_DIR=%~dp0..\server"
cd /d "%SERVER_DIR%"

rem Check only a local TCP listener whose local port is 9500.
for /f "tokens=5" %%a in ('netstat -ano ^| findstr /r /c:"^[ ]*TCP[ ]\+[^ ]*:9500[ ]" ^| findstr "LISTENING"') do (
    echo [ERROR] port 9500 already in use by PID %%a
    echo         stop it first: taskkill /PID %%a /F
    exit /b 1
)

echo [1/2] compiling...
erl -noshell -eval "case make:all() of {error, _} -> init:stop(5); _ -> init:stop(0) end."
if errorlevel 1 (
    echo [ERROR] compile failed
    exit /b 1
)
copy /Y "src\tides.app.src" "ebin\tides.app" >nul
if errorlevel 1 (
    echo [ERROR] application spec generation failed
    exit /b 1
)

echo [2/2] starting in a separate Erlang console (port from shared\data\config.json, default 9500)...
rem Do not use /b or -noshell: the separate window is the operator console.
start "tides-server" erl -pa "%SERVER_DIR%\ebin" -eval "application:ensure_all_started(tides)."
set "LISTENING="
for /l %%i in (1,1,30) do (
    for /f "tokens=5" %%a in ('netstat -ano ^| findstr /r /c:"^[ ]*TCP[ ]\+[^ ]*:9500[ ]" ^| findstr "LISTENING"') do set "LISTENING=%%a"
    if defined LISTENING goto :server_ready
    rem timeout.exe fails instantly when stdin is redirected (e.g. under PowerShell
    rem wrappers), so the wait loop would finish without waiting. ping always sleeps ~1s.
    ping -n 2 127.0.0.1 >nul
)
if not defined LISTENING (
    echo [ERROR] server did not start listening on 9500
    exit /b 1
)
:server_ready
echo [OK] tides server is up. healthz: curl http://127.0.0.1:9500/healthz
endlocal
