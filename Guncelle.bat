@echo off
chcp 65001 >nul
title MTA:SA Guncelleyici - Sunucu ve Oyun
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0updater.ps1"

if %errorlevel% neq 0 (
    echo.
    echo Bir hata olustu.
    pause
)
