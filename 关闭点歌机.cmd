@echo off
chcp 65001 >nul
setlocal
title 关闭 BiliNCM-Bot
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BiliNCM-Launcher.ps1" -StopBot %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo 关闭过程返回错误码 %RC%。
pause
exit /b %RC%
