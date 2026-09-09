@echo off
rem Tides server control for Windows PowerShell.
rem This file is an ASCII wrapper safe in every Windows code page.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tidesctl.ps1" %*
exit /b %ERRORLEVEL%
