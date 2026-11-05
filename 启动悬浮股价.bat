@echo off
chcp 65001 >nul
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0stock_float.ps1"
exit
