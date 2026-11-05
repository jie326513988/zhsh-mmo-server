@echo off
rem Ollama installer for E: drive, with resumable download.
rem Download the 1.5GB installer overnight if your link is slow; re-run to resume.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ollama-install.ps1"
echo.
pause
