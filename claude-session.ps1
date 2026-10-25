# Sessione Remote Control usa-e-getta per una VM cliente.
#
# 0. Se Claude Code non c'e', lo installa con l'installer ufficiale.
# 1. Crea una cartella temporanea e la usa come CLAUDE_CONFIG_DIR: credenziali,
#    cronologia e transcript finiscono li' e non in %USERPROFILE%\.claude.
# 2. Copia nella sessione i server MCP gia' configurati sulla VM (Claude Code e
#    Claude Desktop). Se non trova l'MCP D365 F&O lo aggiunge con -McpUrl, e se
#    non risponde lo avvia con `d365fo-mcp start`.
# 3. Login, poi `claude remote-control` con il nome scelto: la sessione compare
#    nell'app Claude del tuo PC e la usi da li'.
# 4. Quando la sessione termina (o la chiudi con "chiudi tutto") fa il logout ed
#    elimina la cartella temporanea.
#
# Uso:  doppio clic su claude-session.cmd. Il progetto lo indichi poi nella sessione
#       ("usa il progetto X in Y"): Claude puo' lavorare su tutti i dischi locali.
#       Il nome della sessione viene chiesto al primo avvio e salvato in session-name.txt.
# Opzionali: -Project <cartella iniziale> -Name <nome sessione> -ExtraDirs <cartelle>

param(
    # Cartella iniziale; vuota = %USERPROFILE%\source\repos (o il profilo utente).
    [string]$Project = '',
    # Nome mostrato nell'app; vuoto = session-name.txt, o lo chiede al primo avvio.
    [string]$Name = '',
    # Cartelle accessibili oltre a quella iniziale; vuoto = tutti i dischi locali.
    [string[]]$ExtraDirs = @(),
    # Usato solo se sulla VM non c'e' gia' una config MCP con "d365" nel nome.
    [string]$McpUrl = 'http://127.0.0.1:8080/mcp'
)

$ErrorActionPreference = 'Stop'
$prefix = 'cc-session-'

Add-Type -AssemblyName System.Web.Extensions
# JavaScriptSerializer al posto di ConvertFrom-Json: in PowerShell 5.1 ConvertFrom-Json
# fallisce su .claude.json quando ci sono progetti con lo stesso percorso in maiuscolo/minuscolo.
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength = [int]::MaxValue

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        return $json.DeserializeObject((Get-Content $path -Raw -Encoding UTF8))
    } catch {
        Write-Warning "Non riesco a leggere $path, lo salto."
        return $null
    }
}

function Write-JsonFile([string]$path, $value) {
    [IO.File]::WriteAllText($path, $json.Serialize($value))
}

# Elimina i residui di sessioni chiuse male, lasciando stare quelle ancora attive.
# Su RDP %TEMP% e' per sessione (Temp\2, Temp\3...), quindi guarda anche nelle sottocartelle.
function Remove-StaleSessions {
    $base = Join-Path $env:LOCALAPPDATA 'Temp'
    Get-ChildItem -Path "$base\$prefix*", "$base\*\$prefix*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pidFile = Join-Path $_.FullName 'rc.pid'
        if (Test-Path $pidFile) {
            $oldPid = [int](Get-Content $pidFile)
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { return }
        }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Server MCP gia' presenti sulla VM: Claude Desktop, Claude Code (utente e progetto), mcp.json dello script.
function Get-ExistingMcpServers([string]$projectKey) {
    $servers = @{}

    $desktop = Read-JsonFile (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json')
    if ($desktop -and $desktop.ContainsKey('mcpServers')) {
        foreach ($k in $desktop['mcpServers'].Keys) { $servers[$k] = $desktop['mcpServers'][$k] }
    }

    $cc = Read-JsonFile (Join-Path $env:USERPROFILE '.claude.json')
    if ($cc) {
        if ($cc.ContainsKey('mcpServers')) {
            foreach ($k in $cc['mcpServers'].Keys) { $servers[$k] = $cc['mcpServers'][$k] }
        }
        if ($cc.ContainsKey('projects')) {
            foreach ($key in $cc['projects'].Keys) {
                if ($key.TrimEnd('/') -ieq $projectKey) {
                    $proj = $cc['projects'][$key]
                    if ($proj.ContainsKey('mcpServers')) {
                        foreach ($k in $proj['mcpServers'].Keys) { $servers[$k] = $proj['mcpServers'][$k] }
                    }
                }
            }
        }
    }

    # mcp.json accanto allo script: ha la precedenza e non dipende da Claude Desktop.
    $own = Read-JsonFile (Join-Path $PSScriptRoot 'mcp.json')
    if ($own -and $own.ContainsKey('mcpServers')) {
        foreach ($k in $own['mcpServers'].Keys) { $servers[$k] = $own['mcpServers'][$k] }
    }

    return $servers
}

function Test-McpPort([string]$url) {
    $u = [Uri]$url
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        return ($client.ConnectAsync($u.Host, $u.Port).Wait(1500) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# Se l'MCP d365 non risponde lo avvia con `d365fo-mcp start` e aspetta che apra la porta.
function Start-D365Mcp([string]$url) {
    if (Test-McpPort $url) { Write-Host "MCP d365 attivo su $url"; return }

    if (-not (Get-Command d365fo-mcp -ErrorAction SilentlyContinue)) {
        Write-Warning "MCP d365 non risponde su $url e il comando d365fo-mcp non e' installato."
        return
    }

    Write-Host "MCP d365 non risponde, lo avvio con 'd365fo-mcp start'..."
    Start-Process cmd.exe -ArgumentList '/c d365fo-mcp start' -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-McpPort $url) { Write-Host "MCP d365 attivo su $url"; return }
    }
    Write-Warning "MCP d365 ancora non risponde dopo 30 secondi: prova 'd365fo-mcp start' a mano."
}

# Percorso dell'installer standalone, usato anche se il PATH della shell non e' ancora aggiornato.
$standalone = Join-Path $env:USERPROFILE '.local\bin\claude.exe'

# Il prompt "Paste code here" di Claude Code non mostra nulla mentre incolli: qui il codice
# lo legge lo script (con gli asterischi) e lo passa a `claude auth login` sullo standard input.
function Invoke-MaskedLogin {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    $psi.Arguments = 'auth login --claudeai'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    # Lascia a Claude il tempo di stampare il link.
    if ($proc.WaitForExit(4000)) { return ($proc.ExitCode -eq 0) }

    Write-Host ""
    $sec = Read-Host "Incolla qui il codice e premi Invio (vedrai degli asterischi)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $proc.StandardInput.WriteLine([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
    } catch {
        # Claude ha gia' chiuso l'input (es. login completato dal browser della VM).
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    try { $proc.StandardInput.Close() } catch { }

    # Con un codice sbagliato Claude lo richiede e resta in attesa: dopo 30 secondi si passa al login standard.
    if (-not $proc.WaitForExit(30000)) {
        $proc.Kill()
        return $false
    }
    return ($proc.ExitCode -eq 0)
}

function Test-LoggedIn {
    $status = (& $claude auth status 2>&1) -join "`n"
    return ($LASTEXITCODE -eq 0 -and $status -match '"loggedIn"\s*:\s*true')
}

# Invia Ctrl+C a tutti i processi della console: Claude si chiude in modo pulito.
Add-Type -Namespace Win32 -Name ConsoleCtrl -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
'@

$claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claude -and (Test-Path $standalone)) { $claude = $standalone }
if (-not $claude) {
    Write-Host "Claude Code non trovato: lo installo con l'installer ufficiale (claude.ai/install.ps1)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    if (-not (Test-Path $standalone)) { throw "Installazione di Claude Code non riuscita." }
    $claude = $standalone
}
Write-Host "Claude Code: $claude ($(& $claude --version))"

if (-not $Project) {
    $repos = Join-Path $env:USERPROFILE 'source\repos'
    $Project = if (Test-Path $repos) { $repos } else { $env:USERPROFILE }
}

if (-not $Name) {
    $nameFile = Join-Path $PSScriptRoot 'session-name.txt'
    if (Test-Path $nameFile) { $Name = (Get-Content $nameFile -Raw).Trim() }
    if (-not $Name) {
        $Name = (Read-Host "Nome della sessione remota, es. il cliente (Invio = $env:COMPUTERNAME)").Trim()
        if (-not $Name) { $Name = $env:COMPUTERNAME }
        Set-Content -Path $nameFile -Value $Name -Encoding UTF8
    }
}

if (-not $ExtraDirs.Count) {
    $ExtraDirs = @([IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        ForEach-Object { $_.RootDirectory.FullName })
}

$Project = (Resolve-Path $Project).Path
$projectKey = $Project.Replace('\', '/').TrimEnd('/')

Remove-StaleSessions

$dir = Join-Path $env:TEMP ($prefix + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null

$servers = Get-ExistingMcpServers $projectKey

$d365Name = @($servers.Keys | Where-Object { $_ -match 'd365' }) | Select-Object -First 1
if (-not $d365Name) {
    $d365Name = 'd365'
    $servers[$d365Name] = @{ type = 'http'; url = $McpUrl }
    Write-Host "Nessuna config MCP d365 trovata: la creo con $McpUrl"
}
$d365Url = $servers[$d365Name]['url']
if ($d365Url) { Start-D365Mcp $d365Url }
# remoteDialogSeen: non chiede "Enable Remote Control? (y/n)".
# bypassPermissionsModeAccepted: avviso della modalita' bypass gia' accettato.
Write-JsonFile (Join-Path $dir '.claude.json') @{
    hasCompletedOnboarding        = $true
    remoteDialogSeen              = $true
    bypassPermissionsModeAccepted = $true
    mcpServers                    = $servers
    projects                      = @{ $projectKey = @{ hasTrustDialogAccepted = $true } }
}
# Sessione senza richieste di permesso; accetta anche gli MCP del .mcp.json del progetto.
$permissions = @{ defaultMode = 'bypassPermissions' }
if ($ExtraDirs.Count) {
    $permissions['additionalDirectories'] = @($ExtraDirs | ForEach-Object { (Resolve-Path $_).Path })
}
Write-JsonFile (Join-Path $dir 'settings.json') @{
    enableAllProjectMcpServers        = $true
    skipDangerousModePermissionPrompt = $true
    permissions                       = $permissions
}

# "chiudi tutto" nella sessione crea stop.request: lo script lo vede e chiude Claude in modo pulito
# (Ctrl+C), cosi' la sessione viene archiviata e non resta duplicata nell'elenco dell'app.
$stopFile = Join-Path $dir 'stop.request'
$stopScript = Join-Path $dir 'stop.ps1'
"New-Item -ItemType File -Path '$stopFile' -Force | Out-Null" | Set-Content -Path $stopScript -Encoding ascii
@"
# Sessione remota temporanea
- Puoi lavorare in queste cartelle: $($ExtraDirs -join ', ').
- Quando l'utente indica un progetto o un percorso ("usa il progetto X in Y"), lavora li' usando percorsi
  assoluti per leggere, modificare e lanciare comandi. Con get_workspace_info dell'MCP d365 controlla che
  l'MCP punti allo stesso progetto, e se non e' cosi' diglielo.
- Quando l'utente scrive "chiudi tutto", rispondi in una riga che stai chiudendo, poi esegui in
  PowerShell: & '$stopScript'
  Entro pochi secondi la sessione remota termina; lo script di avvio fa poi logout e pulizia.
"@ | Set-Content -Path (Join-Path $dir 'CLAUDE.md') -Encoding UTF8

# Claude Code apre il browser con il comando in BROWSER: al posto del browser della VM
# copiamo il link negli appunti, che via RDP arrivano anche sul tuo PC.
$browserCmd = Join-Path $dir 'browser.cmd'
@'
@echo off
set "CC_LOGIN_URL=%~1"
powershell -NoProfile -NonInteractive -Command "Set-Clipboard -Value $env:CC_LOGIN_URL"
'@ | Set-Content -Path $browserCmd -Encoding ascii

$env:CLAUDE_CONFIG_DIR = $dir
$env:BROWSER = $browserCmd

try {
    Write-Host ""
    Write-Host "Server MCP caricati: $(if ($servers.Count) { $servers.Keys -join ', ' } else { 'nessuno (verranno usati solo quelli del .mcp.json del progetto)' })"
    Write-Host ""
    Write-Host "Il browser della VM non si apre: il link di login viene copiato negli appunti." -ForegroundColor Yellow
    Write-Host "Incollalo nel browser del TUO PC (o copialo da qui sotto); il codice lo incolli quando lo chiede lo script." -ForegroundColor Yellow
    Write-Host ""
    $rc = $null

    # Primo tentativo con gli asterischi; se non va, il login standard di Claude Code.
    Invoke-MaskedLogin | Out-Null
    for ($try = 1; $try -le 2 -and -not (Test-LoggedIn); $try++) {
        Write-Host ""
        Write-Host "Login non riuscito, riprovo con il login standard (qui il codice incollato non si vede)." -ForegroundColor Yellow
        & $claude auth login --claudeai
    }
    if (-not (Test-LoggedIn)) { throw "Login non riuscito." }
    Write-Host "Login riuscito." -ForegroundColor Green

    $rcArgs = "remote-control --name `"$Name`" --spawn session --permission-mode bypassPermissions"
    $rc = Start-Process -FilePath $claude -ArgumentList $rcArgs -WorkingDirectory $Project -NoNewWindow -PassThru
    $rc.Id | Set-Content -Path (Join-Path $dir 'rc.pid') -Encoding ascii

    Write-Host ""
    Write-Host "Sessione '$Name' attiva. Puoi chiudere RDP con la X (NON con Disconnetti/Esci)." -ForegroundColor Green
    Write-Host "Per terminare: scrivi 'chiudi tutto' nella sessione, chiudila dall'app, oppure Ctrl+C qui." -ForegroundColor Green

    while (-not $rc.WaitForExit(1000)) {
        if (Test-Path $stopFile) {
            Write-Host "Richiesta di chiusura ricevuta, chiudo la sessione..." -ForegroundColor Yellow
            # Ctrl+C arriva anche a questo script, che passa subito al blocco finally.
            [Win32.ConsoleCtrl]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
            $rc.WaitForExit(30000) | Out-Null
            break
        }
    }
}
finally {
    # Lascia a Claude il tempo di archiviare la sessione prima del logout; se non basta, lo termina.
    if ($rc -and -not $rc.HasExited -and -not $rc.WaitForExit(30000)) {
        taskkill /PID $rc.Id /T /F *> $null
    }
    & $claude auth logout *> $null
    Remove-Item Env:CLAUDE_CONFIG_DIR, Env:BROWSER -ErrorAction SilentlyContinue
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue

    if (Test-Path $dir) {
        Write-Host "ATTENZIONE: non sono riuscito a cancellare $dir. Eliminala a mano." -ForegroundColor Red
    } else {
        Write-Host "Sessione chiusa: logout fatto e file di sessione eliminati." -ForegroundColor Green
    }

    $local = Join-Path $Project '.claude\settings.local.json'
    if (Test-Path $local) {
        Write-Host "Nota: nel progetto esiste $local (permessi salvati con 'non chiedere piu')." -ForegroundColor Yellow
    }
}
