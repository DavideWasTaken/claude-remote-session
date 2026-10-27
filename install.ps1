# Installs d365fo-remote-session:
# - Documents\remote-session\remote-session.ps1 and session.ini (session name and agent)
# - Desktop\Remote Session.cmd, the double-click launcher
# - Documents\remote-session\update-mcp.ps1 and Desktop\Update d365fo-mcp.cmd, when d365fo-mcp is installed
# Replaces an install of the old d365fo-claude-remote-session, keeping its session name.
#
# Usage:  irm https://raw.githubusercontent.com/DavideWasTaken/d365fo-remote-session/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repo = 'DavideWasTaken/d365fo-remote-session'
# Download from the latest commit rather than /main: raw.githubusercontent.com caches /main for a few
# minutes, so right after a push it can still serve the previous version.
try {
    $ref = (Invoke-RestMethod "https://api.github.com/repos/$repo/commits/main" -UseBasicParsing).sha
} catch {
    $ref = 'main'
}
$repoRaw = "https://raw.githubusercontent.com/$repo/$ref"
$documents = [Environment]::GetFolderPath('MyDocuments')
$desktop = [Environment]::GetFolderPath('Desktop')
$installDir = Join-Path $documents 'remote-session'
$script = Join-Path $installDir 'remote-session.ps1'
$settingsFile = Join-Path $installDir 'session.ini'
$launcher = Join-Path $desktop 'Remote Session.cmd'
$updater = Join-Path $installDir 'update-mcp.ps1'
$updaterLauncher = Join-Path $desktop 'Update d365fo-mcp.cmd'
# Where d365fo-claude-remote-session installed itself.
$oldDir = Join-Path $documents 'claude-remote-session'
$oldLauncher = Join-Path $desktop 'Claude Remote Session.cmd'

Write-Host ""
Write-Host "  D365FO Remote Session - installer" -ForegroundColor Cyan
Write-Host "  ---------------------------------" -ForegroundColor DarkCyan

try {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    $updating = (Test-Path $script) -or (Test-Path $oldDir)
    Invoke-WebRequest "$repoRaw/remote-session.ps1" -OutFile $script -UseBasicParsing
    $version = if ($ref -eq 'main') { 'main' } else { $ref.Substring(0, 7) }
    if ($updating) { Write-Host "  [ OK ] Script updated ($version)" -ForegroundColor Green }
    else { Write-Host "  [ OK ] Script downloaded ($version)" -ForegroundColor Green }

    # Keep name and agent on reinstall/update; take the name over from the old install.
    $settings = @{ name = ''; agent = '' }
    if (Test-Path $settingsFile) {
        foreach ($line in Get-Content $settingsFile -Encoding UTF8) {
            if ($line -match '^\s*(\w+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1].ToLower()] = $Matches[2] }
        }
    }
    $oldNameFile = Join-Path $oldDir 'session-name.txt'
    if (-not $settings.name -and (Test-Path $oldNameFile)) { $settings.name = (Get-Content $oldNameFile -Raw).Trim() }
    # The old install only ran Claude Code.
    if (-not $settings.agent -and (Test-Path $oldDir)) { $settings.agent = 'claude' }

    if (-not $settings.name) {
        Write-Host ""
        $settings.name = (Read-Host "         Session name, e.g. the customer [Enter = $env:COMPUTERNAME]").Trim()
        if (-not $settings.name) { $settings.name = $env:COMPUTERNAME }
    }
    if ($settings.agent -notin 'claude', 'codex') {
        Write-Host ""
        Write-Host "         Agent    [1] Claude Code   [2] Codex (experimental)"
        $choice = (Read-Host "         Choose [Enter = 1]").Trim()
        $settings.agent = if ($choice -in '2', 'codex') { 'codex' } else { 'claude' }
    }
    "name=$($settings.name)", "agent=$($settings.agent)" | Set-Content -Path $settingsFile -Encoding UTF8
    $agentName = if ($settings.agent -eq 'codex') { 'Codex' } else { 'Claude Code' }
    Write-Host "  [ OK ] Session name: $($settings.name)" -ForegroundColor Green
    Write-Host "  [ OK ] Agent: $agentName" -ForegroundColor Green

    @"
@echo off
rem Starts a disposable Claude Code or Codex remote session (d365fo-remote-session).
powershell -NoProfile -ExecutionPolicy Bypass -File "$script" %*
pause
"@ | Set-Content -Path $launcher -Encoding ascii
    Write-Host "  [ OK ] Desktop launcher created" -ForegroundColor Green

    # The d365fo-mcp updater only makes sense where the server is installed.
    $hasMcp = [bool](Get-Command d365fo-mcp -ErrorAction SilentlyContinue)
    if ($hasMcp) {
        Invoke-WebRequest "$repoRaw/update-mcp.ps1" -OutFile $updater -UseBasicParsing
        @"
@echo off
rem Updates d365fo-mcp and restarts its server (d365fo-remote-session).
powershell -NoProfile -ExecutionPolicy Bypass -File "$updater" %*
pause
"@ | Set-Content -Path $updaterLauncher -Encoding ascii
        Write-Host "  [ OK ] d365fo-mcp updater created" -ForegroundColor Green
    }

    if ((Test-Path $oldDir) -or (Test-Path $oldLauncher)) {
        # An mcp.json placed next to the old script still applies.
        $oldMcp = Join-Path $oldDir 'mcp.json'
        $newMcp = Join-Path $installDir 'mcp.json'
        if ((Test-Path $oldMcp) -and -not (Test-Path $newMcp)) { Copy-Item $oldMcp $newMcp }
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $oldLauncher -Force -ErrorAction SilentlyContinue
        Write-Host "  [ OK ] Old 'Claude Remote Session' install removed" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host ("         {0,-9}{1}" -f 'Script', $script) -ForegroundColor DarkGray
    Write-Host ("         {0,-9}{1}" -f 'Settings', $settingsFile) -ForegroundColor DarkGray
    Write-Host ("         {0,-9}{1}" -f 'Launcher', $launcher) -ForegroundColor DarkGray
    if ($hasMcp) { Write-Host ("         {0,-9}{1}" -f 'Updater', $updaterLauncher) -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  Double-click 'Remote Session' on the Desktop to start." -ForegroundColor Green
    if ($hasMcp) { Write-Host "  Double-click 'Update d365fo-mcp' to update the MCP server and restart it." -ForegroundColor Green }
    else { Write-Host "  d365fo-mcp isn't installed: run this installer again after installing it to get its updater." -ForegroundColor DarkGray }
    Write-Host "  Edit session.ini to change the name or switch between claude and codex." -ForegroundColor DarkGray
    Write-Host ""
}
catch {
    Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
}
