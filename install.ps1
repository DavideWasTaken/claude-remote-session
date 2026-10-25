# Installa claude-remote-session:
# - Documenti\claude-remote-session\claude-session.ps1 e session-name.txt
# - Desktop\Claude Remote Session.cmd per l'avvio con doppio clic
#
# Uso:  irm https://raw.githubusercontent.com/DavideWasTaken/claude-remote-session/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repoRaw = 'https://raw.githubusercontent.com/DavideWasTaken/claude-remote-session/main'
$installDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'claude-remote-session'
$desktop = [Environment]::GetFolderPath('Desktop')

New-Item -ItemType Directory -Path $installDir -Force | Out-Null

$script = Join-Path $installDir 'claude-session.ps1'
Invoke-WebRequest "$repoRaw/claude-session.ps1" -OutFile $script -UseBasicParsing

# Il nome resta se esiste gia' (reinstallazione o aggiornamento).
$nameFile = Join-Path $installDir 'session-name.txt'
if (-not (Test-Path $nameFile) -or -not (Get-Content $nameFile -Raw).Trim()) {
    $name = (Read-Host "Nome della sessione remota, es. il cliente (Invio = $env:COMPUTERNAME)").Trim()
    if (-not $name) { $name = $env:COMPUTERNAME }
    Set-Content -Path $nameFile -Value $name -Encoding UTF8
}

$launcher = Join-Path $desktop 'Claude Remote Session.cmd'
@"
@echo off
rem Avvia una sessione Claude Code Remote Control usa-e-getta (claude-remote-session).
powershell -NoProfile -ExecutionPolicy Bypass -File "$script" %*
pause
"@ | Set-Content -Path $launcher -Encoding ascii

Write-Host ""
Write-Host "Installato:" -ForegroundColor Green
Write-Host "  Script:       $script"
Write-Host "  Nome sessione: $((Get-Content $nameFile -Raw).Trim())  ($nameFile)"
Write-Host "  Avvio:        $launcher"
Write-Host ""
Write-Host "Fai doppio clic su 'Claude Remote Session' sul Desktop per partire." -ForegroundColor Green
