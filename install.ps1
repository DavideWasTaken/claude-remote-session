# Installs claude-remote-session:
# - Documents\claude-remote-session\claude-session.ps1 and session-name.txt
# - Desktop\Claude Remote Session.cmd, the double-click launcher
#
# Usage:  irm https://raw.githubusercontent.com/DavideWasTaken/claude-remote-session/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repoRaw = 'https://raw.githubusercontent.com/DavideWasTaken/claude-remote-session/main'
$installDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'claude-remote-session'
$desktop = [Environment]::GetFolderPath('Desktop')
$script = Join-Path $installDir 'claude-session.ps1'
$nameFile = Join-Path $installDir 'session-name.txt'
$launcher = Join-Path $desktop 'Claude Remote Session.cmd'

Write-Host ""
Write-Host "  Claude Remote Session - installer" -ForegroundColor Cyan
Write-Host "  ---------------------------------" -ForegroundColor DarkCyan

try {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $updating = Test-Path $script
    Invoke-WebRequest "$repoRaw/claude-session.ps1" -OutFile $script -UseBasicParsing
    if ($updating) { Write-Host "  [ OK ] Script updated" -ForegroundColor Green }
    else { Write-Host "  [ OK ] Script downloaded" -ForegroundColor Green }

    # Keep the name on reinstall/update.
    if (-not (Test-Path $nameFile) -or -not (Get-Content $nameFile -Raw).Trim()) {
        Write-Host ""
        $name = (Read-Host "         Session name, e.g. the customer [Enter = $env:COMPUTERNAME]").Trim()
        if (-not $name) { $name = $env:COMPUTERNAME }
        Set-Content -Path $nameFile -Value $name -Encoding UTF8
    }
    $name = (Get-Content $nameFile -Raw).Trim()
    Write-Host "  [ OK ] Session name: $name" -ForegroundColor Green

    @"
@echo off
rem Starts a disposable Claude Code Remote Control session (claude-remote-session).
powershell -NoProfile -ExecutionPolicy Bypass -File "$script" %*
pause
"@ | Set-Content -Path $launcher -Encoding ascii
    Write-Host "  [ OK ] Desktop launcher created" -ForegroundColor Green

    Write-Host ""
    Write-Host ("         {0,-9}{1}" -f 'Script', $script) -ForegroundColor DarkGray
    Write-Host ("         {0,-9}{1}" -f 'Name', $nameFile) -ForegroundColor DarkGray
    Write-Host ("         {0,-9}{1}" -f 'Launcher', $launcher) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Double-click 'Claude Remote Session' on the Desktop to start." -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
}
