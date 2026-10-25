# d365fo-remote-session: a disposable Claude Code or Codex remote session for a customer VM.
#
# 1. Asks once which agent to use (Claude Code, or Codex - experimental) and the session name,
#    and keeps both in session.ini next to this script. Installs the agent's CLI if it is missing.
# 2. Points CLAUDE_CONFIG_DIR / CODEX_HOME at a throwaway folder in %TEMP%: credentials, history
#    and transcripts go there instead of %USERPROFILE%\.claude or \.codex.
# 3. Copies the MCP servers already configured on the VM (Claude Code and Claude Desktop).
#    If there is no d365 server it adds -McpUrl; if it doesn't answer, runs `d365fo-mcp start`.
# 4. Signs in without opening the VM's browser: the link goes to the clipboard. Claude gives a
#    code to paste back here, masked; Codex shows a code to type on your computer.
# 5. Starts `claude remote-control` under the chosen name in bypass-permissions mode, or
#    `codex remote-control` with no approvals and a pairing code for the ChatGPT app.
# 6. When the session ends (archived in the app, "stop session", or Ctrl+C) it signs out and
#    deletes the throwaway folder.
#
# Usage:    double-click the launcher. Tell the agent which project to use from the chat
#           ("use project X in Y"): it can access every local drive.
# Optional: -Agent claude|codex -Project <start folder> -Name <session name> -ExtraDirs <folders>
#           -McpUrl <url>

param(
    # claude or codex; empty = session.ini, asked on first run.
    [ValidateSet('claude', 'codex')]
    [string]$Agent = '',
    # Start folder; empty = %USERPROFILE%\source\repos (or the user profile).
    [string]$Project = '',
    # Name shown in the Claude app; empty = session.ini, asked on first run.
    [string]$Name = '',
    # Folders the agent may access besides the start folder; empty = every local fixed drive.
    [string[]]$ExtraDirs = @(),
    # Used only when no MCP server with "d365" in its name is configured on the VM.
    [string]$McpUrl = 'http://127.0.0.1:8080/mcp'
)

$ErrorActionPreference = 'Stop'
$prefixes = @('cc-session-', 'codex-rs-')
# Session name and agent, editable by hand. session-name.txt is where older versions kept the name.
$settingsFile = Join-Path $PSScriptRoot 'session.ini'
$legacyNameFile = Join-Path $PSScriptRoot 'session-name.txt'
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
    Write-Host "  D365FO Remote Session" -ForegroundColor Cyan
    Write-Host "  ---------------------" -ForegroundColor DarkCyan
    Write-Host "  Disposable Claude Code / Codex remote session - nothing of your account stays here." -ForegroundColor DarkGray
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

# session.ini: one key=value per line (name, agent).
function Read-SessionSettings {
    $settings = @{ name = ''; agent = '' }
    if (Test-Path $settingsFile) {
        foreach ($line in Get-Content $settingsFile -Encoding UTF8) {
            if ($line -match '^\s*(\w+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1].ToLower()] = $Matches[2] }
        }
    } elseif (Test-Path $legacyNameFile) {
        $settings.name = (Get-Content $legacyNameFile -Raw).Trim()
    }
    return $settings
}

function Save-SessionSettings($settings) {
    "name=$($settings.name)", "agent=$($settings.agent)" | Set-Content -Path $settingsFile -Encoding UTF8
    if (Test-Path $legacyNameFile) { Remove-Item $legacyNameFile -ErrorAction SilentlyContinue }
}

# Removes leftovers of sessions that ended badly, leaving running ones alone.
# Over RDP %TEMP% is per session (Temp\2, Temp\3...), so look in the subfolders too.
function Remove-StaleSessions {
    $base = Join-Path $env:LOCALAPPDATA 'Temp'
    $removed = 0
    $patterns = foreach ($p in $prefixes) { "$base\$p*", "$base\*\$p*" }
    Get-ChildItem -Path $patterns -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $pidFile = Join-Path $_.FullName 'rc.pid'
        if (Test-Path $pidFile) {
            $oldPid = [int](Get-Content $pidFile)
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { return }
        }
        # A Codex daemon left running from that folder would still be signed in: stop it first.
        Stop-ProcessesUnder $_.FullName
        if (Remove-Folder $_.FullName 1) { $removed++ }
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

# Stops the processes whose executable lives in a folder (the Codex daemon installs its own copy of
# codex.exe in CODEX_HOME) together with everything they started.
function Stop-ProcessesUnder([string]$path) {
    $root = $path.TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Replace('\\?\', '').StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object {
            Stop-ChildProcesses $_.ProcessId $_.CreationDate ([datetime]::Now)
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

# Asks Windows (Restart Manager) which processes have files in a folder open.
function Get-LockingProcesses([string]$path) {
    if (-not ('RmLocks' -as [type])) {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class RmLocks {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint handle, int flags, string key);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint handle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint handle, uint nFiles, string[] files, uint nApps, RM_UNIQUE_PROCESS[] apps, uint nServices, string[] services);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint handle, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);
    public static int[] Get(string[] files) {
        var pids = new List<int>();
        uint handle;
        if (files.Length == 0 || RmStartSession(out handle, 0, Guid.NewGuid().ToString()) != 0) return pids.ToArray();
        try {
            if (RmRegisterResources(handle, (uint)files.Length, files, 0, null, 0, null) != 0) return pids.ToArray();
            uint needed = 0, count = 0, reasons = 0;
            if (RmGetList(handle, out needed, ref count, null, ref reasons) == 234 && needed > 0) {
                var info = new RM_PROCESS_INFO[needed];
                count = needed;
                if (RmGetList(handle, out needed, ref count, info, ref reasons) == 0)
                    for (int i = 0; i < count; i++) pids.Add(info[i].Process.dwProcessId);
            }
        } finally { RmEndSession(handle); }
        return pids.ToArray();
    }
}
'@
    }
    $files = @(Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    return @([RmLocks]::Get($files) | Select-Object -Unique | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
}

# Deletes a folder even when paths inside are longer than 260 characters: Claude Code syncs your
# account's skills and plugins into deep folders that Remove-Item in PowerShell 5.1 can't reach.
# The \\?\ prefix lifts that limit. Retries because files can stay locked for a moment after their
# process exits (or while antivirus scans them).
function Remove-Folder([string]$path, [int]$attempts = 10) {
    # Only ever our own session folders, never an empty or relative path.
    $leaf = Split-Path $path -Leaf
    if (-not [IO.Path]::IsPathRooted($path) -or -not @($prefixes | Where-Object { $leaf -like "$_*" }).Count) { return $false }
    for ($i = 0; $i -lt $attempts; $i++) {
        if (Test-Path -LiteralPath $path) {
            cmd.exe /d /c "rd /s /q `"\\?\$path`"" *> $null
        }
        if (-not (Test-Path -LiteralPath $path)) { return $true }
        if ($i -lt $attempts - 1) { Start-Sleep -Milliseconds 700 }
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

# ---------------------------------------------------------------- codex

function ConvertTo-TomlValue($value) {
    if ($null -eq $value) { return '""' }
    if ($value -is [bool]) { return $value.ToString().ToLower() }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) { return [string]$value }
    if ($value -is [Collections.IDictionary]) {
        $pairs = foreach ($k in $value.Keys) { "$(ConvertTo-TomlValue ([string]$k)) = $(ConvertTo-TomlValue $value[$k])" }
        return '{ ' + ($pairs -join ', ') + ' }'
    }
    if ($value -is [Collections.IEnumerable] -and $value -isnot [string]) {
        return '[' + ((@($value) | ForEach-Object { ConvertTo-TomlValue $_ }) -join ', ') + ']'
    }
    $s = ([string]$value).Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $s + '"'
}

# config.toml for the throwaway CODEX_HOME: no approvals, no sandbox, credentials in auth.json
# (deleted with the folder) instead of the Windows Credential Manager, and the MCP servers found on
# the VM translated from the Claude format.
function Write-CodexConfig([string]$path, $servers, [string]$project) {
    $lines = @(
        'approval_policy = "never"'
        'sandbox_mode = "danger-full-access"'
        'cli_auth_credentials_store = "file"'
        ''
        "[projects.$(ConvertTo-TomlValue $project)]"
        'trust_level = "trusted"'
    )
    foreach ($k in $servers.Keys) {
        $s = $servers[$k]
        $lines += ''
        $lines += "[mcp_servers.$(ConvertTo-TomlValue ([string]$k))]"
        if ($s['url']) {
            if ($s['type'] -eq 'sse') { Write-Warn "$k uses SSE, which Codex doesn't support - it may not connect." }
            $lines += "url = $(ConvertTo-TomlValue $s['url'])"
            if ($s['headers']) { $lines += "http_headers = $(ConvertTo-TomlValue $s['headers'])" }
        } else {
            $lines += "command = $(ConvertTo-TomlValue $s['command'])"
            if ($s['args']) { $lines += "args = $(ConvertTo-TomlValue $s['args'])" }
            if ($s['env']) { $lines += "env = $(ConvertTo-TomlValue $s['env'])" }
        }
    }
    [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n")
}

# Email and plan from the id_token Codex saved in auth.json, for the "Signed in as" line.
function Get-CodexAccount([string]$authFile) {
    try {
        $auth = Read-JsonFile $authFile
        $payload = $auth['tokens']['id_token'].Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - $payload.Length % 4) % 4)
        $claims = $json.DeserializeObject([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)))
        $who = $claims['email']
        $plan = $claims['https://api.openai.com/auth']['chatgpt_plan_type']
        if ($plan) { $who = "$who ($plan)" }
        return $who
    } catch {
        return 'ChatGPT'
    }
}

# Runs `codex login --device-auth` with its output hidden and shows only the link and the one-time
# code: you open the link on YOUR computer and type the code there, nothing is typed on the VM.
# Returns ok or failed.
function Invoke-CodexDeviceLogin {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $codex
    $psi.Arguments = 'login --device-auth'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:loginProc = [System.Diagnostics.Process]::Start($psi)
    $proc = $script:loginProc
    $stderr = $proc.StandardError.ReadToEndAsync()

    $url = $null
    $code = $null
    $seen = ''
    $deadline = (Get-Date).AddSeconds(30)
    while (-not ($url -and $code) -and (Get-Date) -lt $deadline) {
        $line = $proc.StandardOutput.ReadLineAsync()
        if (-not $line.Wait([Math]::Max(1, [int]($deadline - (Get-Date)).TotalMilliseconds))) { break }
        if ($null -eq $line.Result) { break }
        $text = $line.Result -replace '\x1b\[[0-9;]*m', ''
        $seen += $text + "`n"
        if (-not $url -and $text -match '(https://\S+)') { $url = $Matches[1] }
        if (-not $code -and $text -match '\b([A-Z0-9]{4}-[A-Z0-9]{4,6})\b') { $code = $Matches[1] }
    }
    if (-not ($url -and $code)) {
        taskkill /PID $proc.Id /T /F *> $null
        Write-Dim ($seen + $stderr.Result).Trim()
        return 'failed'
    }
    $stdout = $proc.StandardOutput.ReadToEndAsync()

    Set-Clipboard -Value $url
    Write-Ok "Sign-in link copied to the clipboard"
    Write-Info "Open it in the browser on YOUR computer, sign in to ChatGPT and enter this code:"
    Write-Host ""
    Write-Host "           $code" -ForegroundColor White
    Write-Host ""
    Write-Dim "$url  (the code expires in 15 minutes)"
    Write-Host "         waiting " -NoNewline -ForegroundColor DarkGray
    # Short waits, so Ctrl+C still gets through.
    $ticks = 0
    while (-not $proc.WaitForExit(500)) {
        if (++$ticks % 10 -eq 0) { Write-Host "." -NoNewline -ForegroundColor DarkGray }
    }
    Write-Host ""
    $script:loginProc = $null
    if ($proc.ExitCode -eq 0) { return 'ok' }
    Write-Dim ($stdout.Result + $stderr.Result).Trim()
    return 'failed'
}

# Creates a short-lived pairing code for the ChatGPT app and copies it to the clipboard.
function Show-PairingCode {
    $ErrorActionPreference = 'Continue'
    $out = ((& $codex remote-control pair 2>&1) -join "`n") -replace '\x1b\[[0-9;]*m', ''
    if ($out -match 'Pairing code:\s*(\S+)') {
        Set-Clipboard -Value $Matches[1]
        Write-Ok "Pairing code: $($Matches[1])  (copied to the clipboard)"
    } else {
        Write-Warn "Couldn't create a pairing code:"
        Write-Dim $out.Trim()
    }
}

# Runs a codex command in a hidden window and gives up after $seconds (stop must never hang cleanup).
function Invoke-CodexQuiet([string]$arguments, [int]$seconds = 30) {
    $p = Start-Process -FilePath $codex -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit($seconds * 1000)) { taskkill /PID $p.Id /T /F *> $null }
}

# ---------------------------------------------------------------- main

$dir = $null
$rc = $null
$rcStart = $null
$claude = $null
$codex = $null
$loginProc = $null
$remoteStarted = $false
$justInstalled = $false
$signInStarted = $false

Write-Banner

# Agent and session name: asked once, then read from session.ini (edit it to change them).
$settings = Read-SessionSettings
$changed = -not (Test-Path $settingsFile)
if (-not $Agent) {
    # $Agent keeps its ValidateSet: only ever assign it claude or codex.
    $saved = $settings.agent.ToLower()
    if ($saved -in 'claude', 'codex') {
        $Agent = $saved
    } else {
        Write-Host ""
        Write-Host "         Agent    [1] Claude Code   [2] Codex (experimental)"
        $choice = (Read-Host "         Choose [Enter = 1]").Trim()
        $Agent = if ($choice -in '2', 'codex') { 'codex' } else { 'claude' }
        $settings.agent = $Agent
        $changed = $true
    }
} elseif (-not $settings.agent) {
    $settings.agent = $Agent
}
if (-not $Name) {
    $Name = $settings.name
    if (-not $Name) {
        $Name = (Read-Host "         Session name, e.g. the customer [Enter = $env:COMPUTERNAME]").Trim()
        if (-not $Name) { $Name = $env:COMPUTERNAME }
        $settings.name = $Name
        $changed = $true
    }
}
if ($changed) { Save-SessionSettings $settings }

$isCodex = $Agent -eq 'codex'
$prefix = if ($isCodex) { 'codex-rs-' } else { 'cc-session-' }
$agentName = if ($isCodex) { 'Codex' } else { 'Claude Code' }

try {
    # -------------------------------------------------------------- 1. Claude Code / Codex
    Write-Step $agentName

    if ($isCodex) {
        # codex.cmd rather than the codex.ps1 shim npm also creates: .ps1 can't be started as a process.
        $codex = (Get-Command codex.cmd, codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $codex) {
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
                throw "Codex is not installed and npm isn't available - install Node.js, or Codex itself, first."
            }
            Write-Info "Not installed - installing with 'npm install -g @openai/codex'."
            Write-Dim "This can take a minute..."
            $ErrorActionPreference = 'Continue'
            npm install -g @openai/codex *> $null
            $npmPrefix = (npm prefix -g 2>$null | Select-Object -First 1)
            $ErrorActionPreference = 'Stop'
            $shim = if ($npmPrefix) { Join-Path $npmPrefix.Trim() 'codex.cmd' } else { '' }
            if (-not $shim -or -not (Test-Path $shim)) { throw "Codex installation failed: codex.cmd not found after install." }
            $codex = $shim
            $justInstalled = $true
        }
        $version = ((& $codex --version 2>$null) -replace '^codex-cli\s*', '').Trim()
        if ($justInstalled) { Write-Ok "Codex $version installed" } else { Write-Ok "Codex $version" }
        Write-Dim $codex
    } else {
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
    }

    # -------------------------------------------------------------- 2. Session
    Write-Step "Session"

    if (-not $Project) {
        $repos = Join-Path $env:USERPROFILE 'source\repos'
        $Project = if (Test-Path $repos) { $repos } else { $env:USERPROFILE }
    }
    $Project = (Resolve-Path $Project).Path
    $projectKey = $Project.Replace('\', '/').TrimEnd('/')

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

    if ($isCodex) {
        # Codex puts a socket in CODEX_HOME\app-server-control and Windows limits its path to 108
        # characters, so keep the folder name short; drop the RDP Temp\2 level if that's not enough.
        $dir = Join-Path $env:TEMP ($prefix + [guid]::NewGuid().ToString('N').Substring(0, 8))
        if ($dir.Length -gt 64) { $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp') (Split-Path $dir -Leaf) }
        if ($dir.Length -gt 64) { Write-Warn "The temp folder path is long - Codex remote control may fail to start." }
    } else {
        $dir = Join-Path $env:TEMP ($prefix + [guid]::NewGuid().ToString('N'))
    }
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

    $stopFile = Join-Path $dir 'stop.request'
    $stopScript = Join-Path $dir 'stop.ps1'

    if ($isCodex) {
        Write-CodexConfig (Join-Path $dir 'config.toml') $servers $Project
        # Global instructions: Codex reads AGENTS.md from CODEX_HOME. "stop session" works as for Claude.
        "New-Item -ItemType File -Path '$stopFile' -Force | Out-Null" | Set-Content -Path $stopScript -Encoding ascii
        @"
# Temporary remote session
- You can work in these folders: $($ExtraDirs -join ', ').
- When the user names a project or a path ("use project X in Y"), work there, using absolute paths
  to read, edit and run commands. Use get_workspace_info from the d365 MCP to check that the MCP
  points at the same project, and tell the user if it doesn't.
- When the user writes "stop session" (or "chiudi tutto"), say in one line that you are closing,
  then run in PowerShell:
  & '$stopScript'
  Remote control stops within a few seconds; the launcher then signs out and cleans up.
"@ | Set-Content -Path (Join-Path $dir 'AGENTS.md') -Encoding UTF8
        $env:CODEX_HOME = $dir
    } else {
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
        # cleanly (Ctrl+C). Claude Code keeps a session stopped that way for resuming, so it stays in
        # the app as offline; archiving it from the app is what removes it from the list.
        "New-Item -ItemType File -Path '$stopFile' -Force | Out-Null" | Set-Content -Path $stopScript -Encoding ascii
        @"
# Temporary remote session
- You can work in these folders: $($ExtraDirs -join ', ').
- When the user names a project or a path ("use project X in Y"), work there, using absolute paths
  to read, edit and run commands. Use get_workspace_info from the d365 MCP to check that the MCP
  points at the same project, and tell the user if it doesn't.
- When the user writes "stop session" (or "chiudi tutto"), say in one line that you are closing and
  that archiving this session in the app also removes it from their list, then run in PowerShell:
  & '$stopScript'
  The remote session ends within a few seconds; the launcher then signs out and cleans up.
"@ | Set-Content -Path (Join-Path $dir 'CLAUDE.md') -Encoding UTF8

        # Claude Code opens the browser with the command in BROWSER: a no-op keeps the VM's browser
        # closed. The sign-in link goes to the clipboard instead (RDP shares it with your computer).
        $browserCmd = Join-Path $dir 'browser.cmd'
        '@exit /b 0' | Set-Content -Path $browserCmd -Encoding ascii

        $env:CLAUDE_CONFIG_DIR = $dir
        $env:BROWSER = $browserCmd
    }

    # -------------------------------------------------------------- 4. Sign in
    Write-Step "Sign in"
    $signInStarted = $true

    if ($isCodex) {
        $authFile = Join-Path $dir 'auth.json'
        $result = ''
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $result = Invoke-CodexDeviceLogin
            if ($result -eq 'ok') { break }
            if ($attempt -lt 2) { Write-Warn "Sign-in didn't complete - here is a new code, try again."; Write-Host "" }
        }
        if ($result -ne 'ok' -or -not (Test-Path $authFile)) {
            Write-Dim "If ChatGPT refused the code, turn on device code sign-in for Codex in ChatGPT's security settings."
            throw "Sign-in failed."
        }
        Write-Ok "Signed in as $(Get-CodexAccount $authFile)"
    } else {
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
    }

    # -------------------------------------------------------------- 5. Remote session
    Write-Step "Remote session"

    if ($isCodex) {
        # The launcher's PID: while it runs, the next launcher leaves this folder alone.
        $PID | Set-Content -Path (Join-Path $dir 'rc.pid') -Encoding ascii
        $remoteStarted = $true
        $ErrorActionPreference = 'Continue'
        $startOut = ((& $codex remote-control start --json 2>&1) -join "`n") -replace '\x1b\[[0-9;]*m', ''
        $ErrorActionPreference = 'Stop'
        $state = $null
        $last = @($startOut -split "`n" | Where-Object { $_ -match '^\s*\{.*"status"' }) | Select-Object -Last 1
        if ($last) { $state = $json.DeserializeObject($last) }
        if (-not $state -or $state['status'] -ne 'connected') {
            Write-Dim $startOut.Trim()
            throw "Codex remote control didn't start."
        }
        # Codex has no session name: the app lists this machine under its computer name.
        $serverName = $state['serverName']
        Write-Field 'Machine' "$serverName  (Codex shows the computer name, not '$Name')"
        Write-Field 'Mode' 'never ask for approval, no sandbox'
        Write-Host ""
        Show-PairingCode
        Write-Info "In the ChatGPT app on your computer or phone: Codex > add a remote computer > enter the code."
        Write-Info "Then pick '$serverName' and start a thread. You can close RDP now with the X - do NOT sign out."
        Write-Info "To end it: 'stop session' in the chat, Q or Ctrl+C here, or sign out of Codex from the app."
        Write-Dim "P here makes a new pairing code if this one expired."
        Write-Host ""

        while ($true) {
            if (Test-Path $stopFile) { Write-Section "Stop requested from the session - shutting down..."; break }
            if (-not (Test-Path $authFile)) { Write-Section "Signed out from the app - shutting down..."; break }
            $key = $null
            try { if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true).Key } } catch { }
            if ($key -eq 'P') { Show-PairingCode }
            if ($key -eq 'Q') { Write-Section "Shutting down..."; break }
            Start-Sleep -Milliseconds 500
        }
    } else {
        $rcArgs = "remote-control --name `"$Name`" --spawn session --permission-mode bypassPermissions"
        Write-Field 'Session' $Name
        Write-Field 'Mode' 'bypass permissions (no prompts)'
        Write-Host ""
        Write-Info "Open '$Name' from the Claude app on your computer."
        Write-Info "You can close RDP now with the X - do NOT sign out of Windows."
        Write-Info "To end it: archive the session in the app - that also removes it from your list."
        Write-Dim "('stop session' in the chat or Ctrl+C here also work, but leave it listed as offline.)"
        Write-Host ""

        $rc = Start-Process -FilePath $claude -ArgumentList $rcArgs -WorkingDirectory $Project -NoNewWindow -PassThru
        # Read now: once the process has exited, StartTime comes back empty.
        $rcStart = $rc.StartTime
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
        if ($rcStart) { Stop-ChildProcesses $rc.Id $rcStart ([datetime]::Now) }
    }

    # Sign-in interrupted (Ctrl+C while waiting for the code): don't leave it running.
    if ($loginProc -and -not $loginProc.HasExited) { taskkill /PID $loginProc.Id /T /F *> $null }

    if ($dir) {
        Write-Section "Cleaning up"
        if ($isCodex) {
            # Stop the daemon before signing out, then anything still running from the folder.
            if ($remoteStarted) {
                Invoke-CodexQuiet 'remote-control stop'
                Write-Ok "Remote control stopped"
            }
            Stop-ProcessesUnder $dir
            if ($signInStarted -and $codex) {
                Invoke-CodexQuiet 'logout'
                Write-Ok "Signed out"
            }
            Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
        } elseif ($signInStarted -and $claude) {
            & $claude auth logout *> $null
            Write-Ok "Signed out"
        }
        Remove-Item Env:CLAUDE_CONFIG_DIR, Env:BROWSER -ErrorAction SilentlyContinue

        $credentials = Join-Path $dir $(if ($isCodex) { 'auth.json' } else { '.credentials.json' })
        $clean = Remove-Folder $dir
        $lockers = @()
        if (-not $clean) {
            # Still locked: stop our own claude.exe processes holding files (for Codex, the ones
            # running from the session folder), then try again.
            $lockers = @(Get-LockingProcesses $dir)
            $root = $dir.TrimEnd('\') + '\'
            $ours = @($lockers | Where-Object { $_.Path -and ($_.Path -eq $claude -or $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) })
            if ($ours.Count) {
                $ours | Stop-Process -Force -ErrorAction SilentlyContinue
                $clean = Remove-Folder $dir
                if (-not $clean) { $lockers = @(Get-LockingProcesses $dir) }
            }
        }
        if ($clean) {
            Write-Ok "Session files deleted"
        } elseif (Test-Path $credentials) {
            Write-Fail "Couldn't delete the login token: $credentials - remove it by hand."
        } else {
            # Login token already gone; leftovers are removed on the next run.
            Write-Ok "Login token deleted"
            Write-Warn "A few session files are still in use - they'll be removed on the next run."
            if ($lockers.Count) {
                Write-Dim ("Held by: " + (($lockers | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '))
            }
            Write-Dim $dir
        }

        $local = Join-Path $Project '.claude\settings.local.json'
        if (-not $isCodex -and (Test-Path $local)) {
            Write-Warn "$local exists (permissions saved from a session) - delete it if you don't need it."
        }
        Write-Host ""
        if ($clean) {
            Write-Host "  Done. Nothing from this session is left in your $agentName config on this machine." -ForegroundColor Green
        } else {
            Write-Host "  Done. You are signed out; leftover files will be cleaned up next time." -ForegroundColor Green
        }
    }
    Write-Host ""
}
