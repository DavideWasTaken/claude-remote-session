@echo off
rem Double-click to start a disposable Claude Code or Codex remote session (script in the same folder).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-session.ps1" %*
pause
