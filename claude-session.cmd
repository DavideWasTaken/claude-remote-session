@echo off
rem Doppio clic per avviare una sessione Claude Code usa-e-getta nella cartella corrente.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-session.ps1" %*
pause
