@echo off
rem Double-click to update d365fo-mcp and restart its server (script in the same folder).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-mcp.ps1" %*
pause
