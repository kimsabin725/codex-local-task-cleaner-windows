@echo off
setlocal
chcp 65001 >nul
title Codex Local Task Cleaner
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CodexTaskCleaner.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" echo Cleaner stopped with exit code %EXIT_CODE%.
pause
exit /b %EXIT_CODE%
