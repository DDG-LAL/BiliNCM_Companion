@echo off
chcp 65001 >nul
setlocal
title BiliNCM-Bot Debug Login
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BiliNCM-Launcher.ps1" -DebugLogin %*
set "RC=%ERRORLEVEL%"
echo.
echo Debug log: %~dp0login-debug.log
pause
exit /b %RC%
