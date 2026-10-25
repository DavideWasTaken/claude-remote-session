@echo off
rem Double-click to start a disposable Claude Code Remote Control session (script in the same folder).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-session.ps1" %*
pause
