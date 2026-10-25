# d365fo-claude-remote-session: a disposable Claude Code Remote Control session for a customer VM.
#
# 1. Installs Claude Code with the official installer if it is missing.
# 2. Points CLAUDE_CONFIG_DIR at a throwaway folder in %TEMP%: credentials, history and
#    transcripts go there instead of %USERPROFILE%\.claude.
# 3. Copies the MCP servers already configured on the VM (Claude Code and Claude Desktop).
#    If there is no d365 server it adds -McpUrl; if it doesn't answer, runs `d365fo-mcp start`.
# 4. Signs in without opening the VM's browser: the link goes to the clipboard and the code
#    is read here, masked.
# 5. Starts `claude remote-control` under the chosen name, in bypass-permissions mode.
# 6. When the session ends ("stop session", archived in the app, or Ctrl+C) it signs out and
#    deletes the throwaway folder.
#
# Usage:    double-click the launcher. Tell Claude which project to use from the chat
#           ("use project X in Y"): it can access every local drive.
#           The session name comes from session-name.txt next to this script (asked once).
# Optional: -Project <start folder> -Name <session name> -ExtraDirs <folders> -McpUrl <url>

param(
    # Start folder; empty = %USERPROFILE%\source\repos (or the user profile).
    [string]$Project = '',
    # Name shown in the Claude app; empty = session-name.txt, asked on first run.
    [string]$Name = '',
    # Folders Claude may access besides the start folder; empty = every local fixed drive.
    [string[]]$ExtraDirs = @(),
    # Used only when no MCP server with "d365" in its name is configured on the VM.
    [string]$McpUrl = 'http://127.0.0.1:8080/mcp'
)

$ErrorActionPreference = 'Stop'
$prefix = 'cc-session-'
$totalSteps = 5

Add-Type -AssemblyName System.Web.Extensions
# JavaScriptSerializer instead of ConvertFrom-Json: in PowerShell 5.1 ConvertFrom-Json fails on
# .claude.json when two project paths differ only by case.
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength = [int]::MaxValue

# Sends Ctrl+C to every process on this console, so Claude shuts down cleanly.
Add-Type -Namespace Win32 -Name ConsoleCtrl -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
'@

# ---------------------------------------------------------------- output

function Write-Banner {
    Write-Host ""
    Write-Host "  Claude Remote Session" -ForegroundColor Cyan
    Write-Host "  ---------------------" -ForegroundColor DarkCyan
    Write-Host "  Disposable Claude Code Remote Control session - nothing of your account stays here." -ForegroundColor DarkGray
}

$script:step = 0
function Write-Step([string]$text) {
    $script:step++
    Write-Host ""
    Write-Host "[$($script:step)/$totalSteps] $text" -ForegroundColor Cyan
}

function Write-Section([string]$text) {
    Write-Host ""
    Write-Host "$text" -ForegroundColor Cyan
}

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

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        return $json.DeserializeObject((Get-Content $path -Raw -Encoding UTF8))
    } catch {
        Write-Warn "Could not read $path, skipping it."
        return $null
    }
}

function Write-JsonFile([string]$path, $value) {
    [IO.File]::WriteAllText($path, $json.Serialize($value))
}

# Removes leftovers of sessions that ended badly, leaving running ones alone.
# Over RDP %TEMP% is per session (Temp\2, Temp\3...), so look in the subfolders too.
function Remove-StaleSessions {
    $base = Join-Path $env:LOCALAPPDATA 'Temp'
    $removed = 0
    Get-ChildItem -Path "$base\$prefix*", "$base\*\$prefix*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pidFile = Join-Path $_.FullName 'rc.pid'
        if (Test-Path $pidFile) {
            $oldPid = [int](Get-Content $pidFile)
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { return }
        }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    return $removed
}

# MCP servers already on the VM: Claude Desktop, Claude Code (user and project), then mcp.json
# next to this script, which wins.
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

# Starts the d365 MCP server with `d365fo-mcp start` if it doesn't answer, and waits for its port.
function Start-D365Mcp([string]$url) {
    if (Test-McpPort $url) { Write-Ok "d365 is up at $url"; return }

    if (-not (Get-Command d365fo-mcp -ErrorAction SilentlyContinue)) {
        Write-Warn "d365 is not answering at $url and 'd365fo-mcp' is not installed."
        Write-Dim "Install it from https://github.com/dynamics365ninja/d365fo-mcp-server"
        return
    }

    Write-Info "d365 is not answering - starting it with 'd365fo-mcp start'"
    Start-Process cmd.exe -ArgumentList '/c d365fo-mcp start' -WindowStyle Hidden | Out-Null
    Write-Host "         waiting " -NoNewline -ForegroundColor DarkGray
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        Write-Host "." -NoNewline -ForegroundColor DarkGray
        if (Test-McpPort $url) { Write-Host ""; Write-Ok "d365 is up at $url"; return }
    }
    Write-Host ""
    Write-Warn "d365 still isn't answering after 30 seconds - try 'd365fo-mcp start' by hand."
}

# Processes Claude started (the session remote-control spawns, MCP servers, shells) can outlive it
# for a moment and keep files in the config folder open. Only children created while the parent
# was alive are touched, so a reused PID never takes an unrelated process down with it.
function Stop-ChildProcesses([int]$parentId, [datetime]$from, [datetime]$until) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationDate -ge $from -and $_.CreationDate -le $until } |
        ForEach-Object {
            Stop-ChildProcesses $_.ProcessId $_.CreationDate ([datetime]::Now)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

# Files can stay locked for a moment after their process exits (or while antivirus scans them).
function Remove-Folder([string]$path) {
    for ($i = 0; $i -lt 10; $i++) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $path)) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Get-ClaudeStatus {
    # In PowerShell 5.1 a native command's stderr becomes an error record: don't let it throw.
    $ErrorActionPreference = 'Continue'
    $text = (& $claude auth status 2>&1) -join "`n"
    $status = @{ LoggedIn = ($LASTEXITCODE -eq 0 -and $text -match '"loggedIn"\s*:\s*true'); Email = ''; Plan = '' }
    if ($text -match '"email"\s*:\s*"([^"]*)"') { $status.Email = $Matches[1] }
    if ($text -match '"subscriptionType"\s*:\s*"([^"]*)"') { $status.Plan = $Matches[1] }
    return $status
}

# Runs `claude auth login` with its output hidden. Claude prints two links: the one it hands to
# BROWSER redirects to localhost on this VM, the one it prints ("visit: ...") shows a code to
# paste - that's the one we want. The code is read here masked and passed on stdin.
# Returns ok, invalid, failed or nolink.
function Invoke-MaskedLogin {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude
    $psi.Arguments = 'auth login --claudeai'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stderr = $proc.StandardError.ReadToEndAsync()

    $url = $null
    $seen = ''
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $url -and (Get-Date) -lt $deadline) {
        $line = $proc.StandardOutput.ReadLineAsync()
        if (-not $line.Wait([Math]::Max(1, [int]($deadline - (Get-Date)).TotalMilliseconds))) { break }
        if ($null -eq $line.Result) { break }
        $seen += $line.Result + "`n"
        if ($line.Result -match '(https://\S+)' -and $Matches[1] -notmatch 'localhost') { $url = $Matches[1] }
    }
    if (-not $url) {
        try { $proc.Kill() } catch { }
        $proc.WaitForExit()
        return 'nolink'
    }
    # Keep draining the output so Claude never blocks on a full pipe.
    $stdout = $proc.StandardOutput.ReadToEndAsync()

    Set-Clipboard -Value $url
    Write-Ok "Sign-in link copied to the clipboard"
    Write-Info "Open it in the browser on YOUR computer, sign in and copy the code you get."
    Write-Dim $url
    Write-Host ""
    try {
        $sec = Read-Host "         Paste the code" -AsSecureString
    } catch {
        # Prompt interrupted: don't leave `claude auth login` running in the background.
        try { $proc.Kill() } catch { }
        throw
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $proc.StandardInput.WriteLine([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
    } catch {
        # Claude already closed its input (e.g. sign-in completed some other way).
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    try { $proc.StandardInput.Close() } catch { }

    # With a wrong code Claude asks again and keeps waiting.
    if (-not $proc.WaitForExit(30000)) {
        try { $proc.Kill() } catch { }
        $proc.WaitForExit()
    }
    if (($seen + $stdout.Result + $stderr.Result) -match 'Invalid code') { return 'invalid' }
    if ($proc.ExitCode -eq 0) { return 'ok' }
    return 'failed'
}

# ---------------------------------------------------------------- main

$dir = $null
$rc = $null
$claude = $null
$justInstalled = $false
$signInStarted = $false

Write-Banner

try {
    # -------------------------------------------------------------- 1. Claude Code
    Write-Step "Claude Code"

    # Where the official installer puts it, also used when this shell's PATH isn't updated yet.
    $standalone = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $claude = (Get-Command claude -ErrorAction SilentlyContinue).Source
    if (-not $claude -and (Test-Path $standalone)) { $claude = $standalone }
    if (-not $claude) {
        Write-Info "Not installed - installing with the official installer (claude.ai/install.ps1)."
        Write-Dim "This can take a minute..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression *> $null
        } catch {
            throw "Claude Code installation failed: $($_.Exception.Message)"
        }
        if (-not (Test-Path $standalone)) { throw "Claude Code installation failed: claude.exe not found after install." }
        $claude = $standalone
        $justInstalled = $true
    }
    $version = ((& $claude --version) -replace '\s*\(Claude Code\)', '').Trim()
    if ($justInstalled) { Write-Ok "Claude Code $version installed" } else { Write-Ok "Claude Code $version" }
    Write-Dim $claude

    # -------------------------------------------------------------- 2. Session
    Write-Step "Session"

    if (-not $Project) {
        $repos = Join-Path $env:USERPROFILE 'source\repos'
        $Project = if (Test-Path $repos) { $repos } else { $env:USERPROFILE }
    }
    $Project = (Resolve-Path $Project).Path
    $projectKey = $Project.Replace('\', '/').TrimEnd('/')

    if (-not $Name) {
        $nameFile = Join-Path $PSScriptRoot 'session-name.txt'
        if (Test-Path $nameFile) { $Name = (Get-Content $nameFile -Raw).Trim() }
        if (-not $Name) {
            $Name = (Read-Host "         Session name, e.g. the customer [Enter = $env:COMPUTERNAME]").Trim()
            if (-not $Name) { $Name = $env:COMPUTERNAME }
            Set-Content -Path $nameFile -Value $Name -Encoding UTF8
        }
    }

    if (-not $ExtraDirs.Count) {
        $ExtraDirs = @([IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
            ForEach-Object { $_.RootDirectory.FullName })
    }
    $ExtraDirs = @($ExtraDirs | ForEach-Object { (Resolve-Path $_).Path })

    Write-Field 'Name' $Name
    Write-Field 'Start in' $Project
    Write-Field 'Access' ($ExtraDirs -join '  ')

    $removed = Remove-StaleSessions
    if ($removed) { Write-Info "Removed $removed leftover folder(s) from earlier sessions." }

    $dir = Join-Path $env:TEMP ($prefix + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    Write-Ok "Throwaway config folder ready"
    Write-Dim $dir

    # -------------------------------------------------------------- 3. MCP servers
    Write-Step "MCP servers"

    $servers = Get-ExistingMcpServers $projectKey
    $d365Name = @($servers.Keys | Where-Object { $_ -match 'd365' }) | Select-Object -First 1
    if (-not $d365Name) {
        $d365Name = 'd365'
        $servers[$d365Name] = @{ type = 'http'; url = $McpUrl }
        Write-Warn "No d365 MCP config found on this VM - using $McpUrl"
    }
    foreach ($k in $servers.Keys) {
        $s = $servers[$k]
        $target = if ($s['url']) { $s['url'] } else { $s['command'] }
        Write-Field $k $target
    }
    $d365Url = $servers[$d365Name]['url']
    if ($d365Url) { Start-D365Mcp $d365Url }

    # remoteDialogSeen: skips "Enable Remote Control? (y/n)".
    # bypassPermissionsModeAccepted: the bypass-mode warning counts as accepted.
    Write-JsonFile (Join-Path $dir '.claude.json') @{
        hasCompletedOnboarding        = $true
        remoteDialogSeen              = $true
        bypassPermissionsModeAccepted = $true
        mcpServers                    = $servers
        projects                      = @{ $projectKey = @{ hasTrustDialogAccepted = $true } }
    }
    # No permission prompts; also accept the MCP servers in the project's .mcp.json.
    Write-JsonFile (Join-Path $dir 'settings.json') @{
        enableAllProjectMcpServers        = $true
        skipDangerousModePermissionPrompt = $true
        permissions                       = @{
            defaultMode           = 'bypassPermissions'
            additionalDirectories = $ExtraDirs
        }
    }

    # "stop session" in the chat creates stop.request: this script sees it and stops Claude
    # cleanly (Ctrl+C), so the session gets archived instead of piling up in the app.
    $stopFile = Join-Path $dir 'stop.request'
    $stopScript = Join-Path $dir 'stop.ps1'
    "New-Item -ItemType File -Path '$stopFile' -Force | Out-Null" | Set-Content -Path $stopScript -Encoding ascii
    @"
# Temporary remote session
- You can work in these folders: $($ExtraDirs -join ', ').
- When the user names a project or a path ("use project X in Y"), work there, using absolute paths
  to read, edit and run commands. Use get_workspace_info from the d365 MCP to check that the MCP
  points at the same project, and tell the user if it doesn't.
- When the user writes "stop session" (or "chiudi tutto"), say in one line that you are closing,
  then run in PowerShell: & '$stopScript'
  The remote session ends within a few seconds; the launcher then signs out and cleans up.
"@ | Set-Content -Path (Join-Path $dir 'CLAUDE.md') -Encoding UTF8

    # Claude Code opens the browser with the command in BROWSER: a no-op keeps the VM's browser
    # closed. The sign-in link goes to the clipboard instead (RDP shares it with your computer).
    $browserCmd = Join-Path $dir 'browser.cmd'
    '@exit /b 0' | Set-Content -Path $browserCmd -Encoding ascii

    $env:CLAUDE_CONFIG_DIR = $dir
    $env:BROWSER = $browserCmd

    # -------------------------------------------------------------- 4. Sign in
    Write-Step "Sign in"
    $signInStarted = $true

    $result = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result = Invoke-MaskedLogin
        if ($result -eq 'ok' -or $result -eq 'nolink') { break }
        if ($attempt -lt 3) {
            if ($result -eq 'invalid') { Write-Warn "That code wasn't accepted - here is a new link, try again." }
            else { Write-Warn "Sign-in didn't complete - here is a new link, try again." }
            Write-Host ""
        }
    }
    if ($result -eq 'nolink') {
        Write-Warn "Couldn't capture the sign-in link - falling back to Claude Code's own sign-in."
        Write-Dim "The code you paste there stays invisible: paste it once and press Enter."
        & $claude auth login --claudeai
    }

    $status = Get-ClaudeStatus
    if (-not $status.LoggedIn) { throw "Sign-in failed." }
    $who = $status.Email
    if ($status.Plan) { $who = "$who ($($status.Plan))" }
    Write-Ok "Signed in as $who"

    # -------------------------------------------------------------- 5. Remote session
    Write-Step "Remote session"

    $rcArgs = "remote-control --name `"$Name`" --spawn session --permission-mode bypassPermissions"
    Write-Field 'Session' $Name
    Write-Field 'Mode' 'bypass permissions (no prompts)'
    Write-Host ""
    Write-Info "Open '$Name' from the Claude app on your computer."
    Write-Info "You can close RDP now with the X - do NOT sign out of Windows."
    Write-Info "To end it: type 'stop session' in the chat, archive it in the app, or press Ctrl+C here."
    Write-Host ""

    $rc = Start-Process -FilePath $claude -ArgumentList $rcArgs -WorkingDirectory $Project -NoNewWindow -PassThru
    $rc.Id | Set-Content -Path (Join-Path $dir 'rc.pid') -Encoding ascii

    while (-not $rc.WaitForExit(1000)) {
        if (Test-Path $stopFile) {
            Write-Section "Stop requested from the session - shutting down..."
            # Ctrl+C also reaches this script, which goes straight to the finally block.
            [Win32.ConsoleCtrl]::GenerateConsoleCtrlEvent(0, 0) | Out-Null
            $rc.WaitForExit(30000) | Out-Null
            break
        }
    }
}
catch {
    Write-Host ""
    Write-Fail $_.Exception.Message
}
finally {
    # Cleanup must always run to the end, whatever the native commands print on stderr.
    $ErrorActionPreference = 'Continue'

    # Give Claude time to archive the session before signing out; kill it if that's not enough.
    if ($rc) {
        if (-not $rc.HasExited -and -not $rc.WaitForExit(30000)) {
            taskkill /PID $rc.Id /T /F *> $null
        }
        try {
            $until = if ($rc.HasExited) { $rc.ExitTime } else { [datetime]::Now }
            Stop-ChildProcesses $rc.Id $rc.StartTime $until
        } catch { }
    }

    if ($dir) {
        Write-Section "Cleaning up"
        if ($signInStarted -and $claude) {
            & $claude auth logout *> $null
            Write-Ok "Signed out"
        }
        Remove-Item Env:CLAUDE_CONFIG_DIR, Env:BROWSER -ErrorAction SilentlyContinue

        $credentials = Join-Path $dir '.credentials.json'
        $clean = Remove-Folder $dir
        if ($clean) {
            Write-Ok "Session files deleted"
        } elseif (Test-Path $credentials) {
            Write-Fail "Couldn't delete the login token: $credentials - remove it by hand."
        } else {
            # Login token already gone; leftovers are removed on the next run.
            Write-Ok "Login token deleted"
            Write-Warn "A few session files are still in use - they'll be removed on the next run."
            Write-Dim $dir
        }

        $local = Join-Path $Project '.claude\settings.local.json'
        if (Test-Path $local) {
            Write-Warn "$local exists (permissions saved from a session) - delete it if you don't need it."
        }
        Write-Host ""
        if ($clean) {
            Write-Host "  Done. Nothing from this session is left in your Claude config on this machine." -ForegroundColor Green
        } else {
            Write-Host "  Done. You are signed out; leftover files will be cleaned up next time." -ForegroundColor Green
        }
    }
    Write-Host ""
}
