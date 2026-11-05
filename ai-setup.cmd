@echo off
rem 纵横四海 · 打开 AI 设置窗口（可选本地/联网/关闭，保存后可一键重启游戏）
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0ai-setup.ps1" -Mode Settings
