# d365fo-remote-session

Start a disposable **Claude Code Remote Control** or **Codex remote control** session on a customer's VM with one double-click, and drive it from your own machine. Nothing of your account stays on the VM.

> Formerly `d365fo-claude-remote-session`. Codex support is **experimental**: `codex remote-control` is itself marked experimental by OpenAI.

It was built for **Dynamics 365 Finance & Operations** development VMs (LCS cloud-hosted environments) and works together with [d365fo-mcp-server](https://github.com/dynamics365ninja/d365fo-mcp-server). It works on any Windows machine where you want Claude Code or Codex without leaving your login behind.

## Why

Customer VMs are shared machines. On a typical LCS dev VM:

- everyone uses the same local admin account, and the RDP credentials are visible to anyone with access to the LCS project;
- you can't create a separate Windows user for yourself;
- SSH is usually not available, only RDP.

If you install the Claude or ChatGPT desktop app there and sign in, your whole account sits on that machine: your chats, including other customers' work, plus projects and connectors. Anyone who opens the RDP session sees them, and the login stays on disk if you forget to sign out.

This script lets you:

- **set up a remote session in seconds:** double-click, sign in, close RDP, then work from the Claude or ChatGPT app on your own PC;
- **keep your account off the VM:** credentials, history and transcripts live in a temporary folder that is deleted when the session ends;
- **run one session per customer:** with Claude each VM shows up under its own name in your session list, so you always know which machine you are talking to (Codex lists it under the computer name).

## What it does

1. **Asks once which agent to use**, Claude Code or Codex, and **installs its CLI** if it isn't there yet (Claude with the official installer, Codex with `npm install -g @openai/codex`). The choice is saved with the session name in `session.ini`.
2. **Creates a throwaway config folder** in `%TEMP%` and points `CLAUDE_CONFIG_DIR` or `CODEX_HOME` at it, so nothing is written to `%USERPROFILE%\.claude` or `\.codex`.
3. **Finds your MCP servers** in the Claude Code and Claude Desktop configs (plus an optional `mcp.json` next to the script). If no `d365` server is configured it adds `http://127.0.0.1:8080/mcp`. If the server doesn't answer, it starts it with `d365fo-mcp start`.
4. **Signs you in without touching the VM's browser.** The sign-in link is copied to the clipboard, which RDP shares with your PC. Claude: open it on your own machine and paste the code back, masked with `*`. Codex: open it on your own machine and type the code the console shows (device code sign-in), nothing is typed on the VM.
5. **Starts the remote session** with no permission prompts. Claude: `claude remote-control`, with no "Enable Remote Control?" question. Codex: `codex remote-control --no-daemon` with `approval_policy = "never"` and no sandbox, plus a pairing code for the ChatGPT app. It can access every local drive, so you just tell it which project to work on.
6. **Cleans up when you're done:** clean shutdown of the agent and its child processes (for Codex, its remote-control server too), sign-out, and the temp folder is deleted, including paths longer than 260 characters. Leftovers from sessions that ended badly are removed on the next run.

## Requirements

- Windows with PowerShell 5.1 or later (Windows Server 2022 on LCS VMs works out of the box).
- **Claude:** a Claude **Pro or Max** subscription (Remote Control needs a claude.ai login; API keys are not supported), the Claude app (desktop, web or mobile) on **your own** machine signed in with the same account, and outbound HTTPS from the VM to `claude.ai` and `anthropic.com`.
- **Codex:** a ChatGPT plan that includes Codex, the ChatGPT app with Codex remote access on **your own** computer or phone signed in with the same account, Node.js/npm on the VM (already there if you use d365fo-mcp), and outbound HTTPS to `chatgpt.com` and `openai.com`. If ChatGPT refuses the sign-in code, turn on device code sign-in for Codex in ChatGPT's security settings.
- For D365 F&O: [d365fo-mcp-server](https://github.com/dynamics365ninja/d365fo-mcp-server), installed and configured on the VM (`npm install -g d365fo-mcp`).

## Install

On the VM, open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/DavideWasTaken/d365fo-remote-session/main/install.ps1 | iex
```

It asks for a session name (for example the customer's name, or press Enter to use the computer name) and the agent, Claude Code or Codex, then creates:

- `Documents\remote-session\remote-session.ps1`: the script;
- `Documents\remote-session\session.ini`: the session name and the agent, which you can edit at any time;
- `Desktop\Remote Session.cmd`: the double-click launcher.

`session.ini` looks like this; set `agent` to `claude` or `codex` to switch:

```ini
name=Contoso
agent=claude
```

Run the same command again to update the script. Your settings are kept. An install of the old `d365fo-claude-remote-session` is replaced: its session name and `mcp.json` are carried over, and the old folder and launcher are removed.

If you'd rather install by hand, copy `remote-session.ps1` and `remote-session.cmd` into the same folder and double-click the `.cmd`. It asks for the agent and the session name on the first run.

## Usage

### Claude Code

1. Double-click **Remote Session** on the Desktop.
2. Paste the sign-in link (it's already in your clipboard) into the browser on **your** PC, sign in, copy the code and paste it into the VM console.
3. Close the RDP window with the **X**. Don't use *Sign out*: that would end the session.
4. Open the session from the Claude app on your PC and tell it what to work on, for example *"use project 1311 in C:\Users\...\source\repos\1311"*.

To end the session, **archive it from the Claude app**. In single-session mode Remote Control exits when its session ends, and the script then signs out and deletes the temp folder. Archiving is also what removes the session from your list.

You can also type **"stop session"** in the chat or press Ctrl+C in the VM console. The cleanup is the same, but Claude Code deliberately keeps a session stopped this way so it can be resumed, so it stays in your list as offline until you archive it.

### Codex (experimental)

1. Double-click **Remote Session** on the Desktop.
2. Paste the sign-in link (it's already in your clipboard) into the browser on **your** PC, sign in to ChatGPT and type the code shown in the VM console.
3. The console then shows a **pairing code** (also copied to the clipboard). In the ChatGPT app on your computer or phone, add a remote computer for Codex and enter it. The code is short-lived: press **P** in the console for a new one.
4. Close the RDP window with the **X**. Don't use *Sign out*: that would end the session.
5. Pick the VM in the app (it's listed under its **computer name**: Codex has no session name) and start a thread, for example *"use project 1311 in C:\Users\...\source\repos\1311"*.

To end the session, type **"stop session"** in the chat, press **Q** or Ctrl+C in the VM console, or sign out of Codex from the app. The script stops Codex, signs out and deletes the temp folder.

### Console

The console walks you through five steps. With Claude Code:

```
  D365FO Remote Session
  ---------------------

[1/5] Claude Code
  [ OK ] Claude Code 2.1.310
[2/5] Session
         Name     Contoso
         Start in C:\Users\Admin\source\repos
         Access   C:\  K:\
  [ OK ] Throwaway config folder ready
[3/5] MCP servers
         d365     http://127.0.0.1:8080/mcp
  [ OK ] d365 is up at http://127.0.0.1:8080/mcp
[4/5] Sign in
  [ OK ] Sign-in link copied to the clipboard
         Open it in the browser on YOUR computer, sign in and copy the code you get.
         Paste the code: ****************
  [ OK ] Signed in as you@example.com (max)
[5/5] Remote session
         Session  Contoso
         Mode     bypass permissions (no prompts)
```

### Optional parameters

You only need these when running the script from PowerShell instead of double-clicking.

| Parameter | Default | Meaning |
|---|---|---|
| `-Agent` | `session.ini`, or asked on first run | `claude` or `codex` |
| `-Project` | `%USERPROFILE%\source\repos` | Starting folder |
| `-Name` | `session.ini`, or asked on first run | Session name shown in the Claude app |
| `-ExtraDirs` | all local fixed drives | Folders the agent may access |
| `-McpUrl` | `http://127.0.0.1:8080/mcp` | Used only if no `d365` MCP config is found |

To force a specific MCP configuration on a VM, put an `mcp.json` next to the script:

```json
{ "mcpServers": { "d365": { "type": "http", "url": "http://127.0.0.1:8080/mcp" } } }
```

## Security notes

This reduces exposure a lot, but on a machine where others are administrators it can't make you invisible. Be aware that:

- **While the session runs**, the login token is in the temp folder and in process memory. A local admin, or an Azure admin taking a disk snapshot, could read it. When the session ends it is signed out and deleted.
- **Deleted files are removed normally, not wiped**, so forensic recovery is possible.
- **The session runs without approvals** (`bypassPermissions` for Claude, `approval_policy = "never"` with no sandbox for Codex): the agent executes commands, edits files and runs MCP tools such as SQL queries without asking. Keep that in mind on customer environments.
- **Codex remote control is experimental.** On Windows the Codex background daemon refuses to run as administrator, and LCS VMs run the admin account elevated, often with UAC off. So the script runs `codex remote-control --no-daemon` in the foreground and requests the pairing code from its local socket itself, with the same request `codex remote-control pair` sends to the daemon. A future Codex release could change that request.
- **Files Claude creates in your projects**, for example `.claude\settings.local.json`, are not removed. The script warns you if it finds one.
- **Make sure your contract allows** sending the customer's code to an AI service.

## License

[MIT](LICENSE)
