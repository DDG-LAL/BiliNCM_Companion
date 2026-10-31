@echo off
chcp 65001 >nul
setlocal
title BiliNCM-Bot CDP Launcher
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BiliNCM-Launcher.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    pause
    exit /b %RC%
)
if /i "%~1"=="-CheckOnly" exit /b 0
echo.
echo 点歌机已启动。此窗口保持打开。
:ask_choice
set "ANSWER="
set /p "ANSWER=是否彻底关闭点歌机? [Y=关闭 / N=保持运行并关闭此窗口] "
if /i "%ANSWER%"=="Y" goto stop_machine
if /i "%ANSWER%"=="N" exit /b 0
if not defined ANSWER (
    echo.
    echo 没有收到有效输入；窗口将保持打开。按任意键退出。
    pause
    exit /b 0
)
echo 请输入 Y 或 N。
goto ask_choice

:stop_machine
echo.
echo 正在关闭点歌机...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BiliNCM-Launcher.ps1" -StopBot -ForceStop
set "STOPRC=%ERRORLEVEL%"
echo.
if "%STOPRC%"=="0" (echo 点歌机已关闭。) else (echo 关闭失败，错误码 %STOPRC%。)
pause
exit /b %STOPRC%
