# Updates d365fo-mcp on this VM and puts the server back up, with one double-click.
#
# 1. Finds the installation behind the global `d365fo-mcp` command: an npm install from the
#    registry, or a git checkout linked with `npm link` (any fork, on the branch it tracks).
# 2. Checks whether there is anything to update: a newer release on npm, new commits upstream,
#    or a C# bridge built from older sources. If not, it leaves the server alone.
# 3. Stops the server running from that installation (and its bridge), since Windows won't let
#    npm or dotnet replace files a running process holds open.
# 4. Runs `d365fo-mcp update --yes`, which pulls or reinstalls, builds and rebuilds the bridge.
# 5. Starts the server again with `d365fo-mcp start` if it was running, and waits for its port.
#
# Usage:    double-click the launcher. Optional: -McpUrl <url> (default http://127.0.0.1:8080/mcp)

param(
    # Where the HTTP server answers; used to tell whether it was running and to wait for it.
    [string]$McpUrl = 'http://127.0.0.1:8080/mcp'
)

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'
$npmLink = Join-Path $env:APPDATA 'npm\node_modules\d365fo-mcp'

# ---------------------------------------------------------------- output

function Write-Ok([string]$text)   { Write-Host "  [ OK ] $text" -ForegroundColor Green }
function Write-Warn([string]$text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Fail([string]$text) { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Info([string]$text) { Write-Host "         $text" -ForegroundColor Gray }
function Write-Dim([string]$text)  { Write-Host "         $text" -ForegroundColor DarkGray }

function Write-Field([string]$label, [string]$value) {
    Write-Host ("         {0,-9}" -f $label) -NoNewline -ForegroundColor DarkGray
    Write-Host $value
}

# ---------------------------------------------------------------- helpers

# In PowerShell 5.1 the stderr lines of native commands become ErrorRecords: turn them back into text.
function ConvertTo-Text { process { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } }

function Invoke-Git {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git.exe -C $root @args 2>&1 | ConvertTo-Text } finally { $ErrorActionPreference = $saved }
}

function Get-InstalledVersion {
    (Get-Content (Join-Path $root 'package.json') -Raw | ConvertFrom-Json).version
}

# missing | current | stale | unstamped, from the same check `d365fo-mcp update` uses.
function Get-BridgeFreshness {
    $module = Join-Path $root 'dist\cli\bridgeSources.js'
    if (-not (Test-Path $module)) { return 'unknown' }
    $url = 'file:///' + $module.Replace('\', '/')
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return (& node.exe --input-type=module -e "const m = await import('$url'); console.log(m.bridgeFreshness());" 2>&1 |
            ConvertTo-Text | Select-Object -Last 1)
    } finally { $ErrorActionPreference = $saved }
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

# node processes running from the installation (the HTTP server, and stdio servers VS Code or
# Visual Studio keep alive) and a bridge built inside it. The npm link path counts too: for a
# checkout, the command line can name the junction rather than the folder it points to.
function Get-ServerProcesses {
    $paths = @($root.TrimEnd('\'), $npmLink) | Select-Object -Unique
    Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='D365MetadataBridge.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $text = "$($_.CommandLine) $($_.ExecutablePath)".Replace('\\', '\')
            foreach ($p in $paths) { if ($text -like "*$p\*") { return $true } }
            return $false
        }
}

# Stops a process together with everything it started (the bridge is a child of the server).
function Stop-ProcessTree([int]$id) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-ProcessTree $_.ProcessId }
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
}

function Start-D365Mcp([string]$url) {
    Write-Info "Starting the server with 'd365fo-mcp start'"
    Start-Process cmd.exe -ArgumentList '/c d365fo-mcp start' -WorkingDirectory $env:USERPROFILE -WindowStyle Hidden | Out-Null
    Write-Host "         waiting " -NoNewline -ForegroundColor DarkGray
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        if (Test-McpPort $url) { Write-Host ""; Write-Ok "d365 is up at $url"; return $true }
    }
    Write-Host ""
    Write-Warn "d365 still isn't answering after 30 seconds - try 'd365fo-mcp start' by hand."
    return $false
}

# ---------------------------------------------------------------- main

function Update-D365Mcp {
    Write-Host ""
    Write-Host "  d365fo-mcp update" -ForegroundColor Cyan
    Write-Host "  -----------------" -ForegroundColor DarkCyan

    if (-not (Get-Command d365fo-mcp -ErrorAction SilentlyContinue) -or -not (Test-Path $npmLink)) {
        Write-Fail "'d365fo-mcp' is not installed globally."
        Write-Dim "Install it from https://github.com/dynamics365ninja/d365fo-mcp-server"
        return $false
    }

    # An `npm link`ed checkout is a junction to its folder; an npm install is the package itself.
    $link = Get-Item $npmLink
    $script:root = if ($link.LinkType -and $link.Target) { (@($link.Target)[0]).TrimEnd('\') } else { $npmLink }
    $isGit = Test-Path (Join-Path $root '.git')

    Write-Host ""
    Write-Field 'Install' $(if ($isGit) { 'git checkout' } else { 'npm package' })
    Write-Field 'Folder' $root
    $version = Get-InstalledVersion
    Write-Field 'Version' $version

    # ---- anything to update?
    $reasons = @()
    if ($isGit) {
        $out = Invoke-Git fetch --prune
        if ($LASTEXITCODE -ne 0) { Write-Fail "git fetch failed: $($out -join ' ')"; return $false }
        $upstream = (Invoke-Git rev-parse --abbrev-ref --symbolic-full-name '@{u}' | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "The branch '$(Invoke-Git rev-parse --abbrev-ref HEAD)' tracks no remote branch, so there is nothing to pull."
            return $false
        }
        Write-Field 'Branch' "$(Invoke-Git rev-parse --abbrev-ref HEAD) <- $upstream"
        if (Invoke-Git status --porcelain --untracked-files=no) {
            Write-Fail 'The checkout has uncommitted changes: commit or stash them, then run this again.'
            return $false
        }
        $behind = [int](Invoke-Git rev-list --count 'HEAD..@{u}' | Select-Object -First 1)
        if ($behind -gt 0) {
            $reasons += "$behind new commit(s) on $upstream"
            Invoke-Git log --oneline 'HEAD..@{u}' | Select-Object -First 20 | ForEach-Object { Write-Dim $_ }
            if ($behind -gt 20) { Write-Dim "... and $($behind - 20) more" }
        }
    } else {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $latest = (& npm.cmd view d365fo-mcp version 2>$null | Select-Object -Last 1)
        $ErrorActionPreference = $saved
        if (-not $latest) {
            Write-Warn "The npm registry is unreachable: can't tell whether there is a newer release."
        } elseif ($latest.Trim() -ne $version) {
            $reasons += "release $($latest.Trim()) is out"
        }
    }
    $bridge = Get-BridgeFreshness
    if ($bridge -in 'stale', 'unstamped') { $reasons += "the C# bridge is $bridge" }

    Write-Host ""
    if (-not $reasons) {
        Write-Ok "Already up to date: $version."
        return $true
    }
    Write-Info "Updating: $($reasons -join ', ')."

    # ---- stop the server
    $wasUp = Test-McpPort $McpUrl
    $procs = @(Get-ServerProcesses)
    if ($procs) {
        Write-Info "Stopping the server (PID $(($procs | ForEach-Object ProcessId) -join ', '))"
        $procs | ForEach-Object { Stop-ProcessTree $_.ProcessId }
        Start-Sleep -Seconds 2
        Write-Ok 'Server stopped'
    } elseif ($wasUp) {
        Write-Warn "Something else answers at $McpUrl, not this installation: leaving it running."
        $wasUp = $false
    }

    # ---- update; not from inside the package, which npm renames aside while it reinstalls
    Write-Host ""
    Push-Location $env:USERPROFILE
    # Out-Host: inside a function the output would become its return value instead of reaching the console.
    try { & cmd.exe /c d365fo-mcp update --yes | Out-Host; $rc = $LASTEXITCODE } finally { Pop-Location }
    Write-Host ""
    if ($rc -eq 0) {
        Write-Ok "d365fo-mcp updated: $version -> $(Get-InstalledVersion)"
    } else {
        Write-Fail "'d365fo-mcp update' failed (exit code $rc): see the messages above."
    }

    # ---- put the server back, also after a failed update: a failed pull leaves the old code in place
    if ($wasUp) { if (-not (Start-D365Mcp $McpUrl)) { return $false } }
    else { Write-Dim "The server wasn't running: the next Remote Session starts it." }
    return ($rc -eq 0)
}

try {
    $ok = Update-D365Mcp
} catch {
    Write-Fail $_.Exception.Message
    $ok = $false
}
Write-Host ""
if (-not $ok) { exit 1 }
