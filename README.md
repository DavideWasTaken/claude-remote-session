# claude-remote-session

Start a disposable Claude Code **Remote Control** session on a customer's VM with one double-click, and drive it from your own machine. Nothing of your account stays on the VM.

It was built for **Dynamics 365 Finance & Operations** development VMs (LCS cloud-hosted environments) and works together with [d365fo-mcp-server](https://github.com/dynamics365ninja/d365fo-mcp-server). It works on any Windows machine where you want Claude Code without leaving your login behind.

## Why

Customer VMs are shared machines. On a typical LCS dev VM:

- everyone uses the same local admin account, and the RDP credentials are visible to anyone with access to the LCS project;
- you can't create a separate Windows user for yourself;
- SSH is usually not available, only RDP.

If you install the Claude desktop app there and sign in, your whole claude.ai account sits on that machine: your chats, including other customers' work, plus projects and connectors. Anyone who opens the RDP session sees them, and the login stays on disk if you forget to sign out.

This script lets you:

- **set up a remote session in seconds:** double-click, sign in, close RDP, then work from the Claude app on your own PC;
- **keep your account off the VM:** credentials, history and transcripts live in a temporary folder that is deleted when the session ends;
- **run one session per customer:** each VM shows up under its own name in your session list, so you always know which machine you are talking to.

## What it does

1. **Installs Claude Code** with the official installer if it isn't installed yet.
2. **Creates a throwaway config folder** in `%TEMP%` and points `CLAUDE_CONFIG_DIR` at it, so nothing is written to `%USERPROFILE%\.claude`.
3. **Finds your MCP servers** in the Claude Code and Claude Desktop configs (plus an optional `mcp.json` next to the script). If no `d365` server is configured it adds `http://127.0.0.1:8080/mcp`. If the server doesn't answer, it starts it with `d365fo-mcp start`.
4. **Signs you in without touching the VM's browser.** The sign-in link is copied to the clipboard, which RDP shares with your PC: you open it on your own machine and paste the code back, masked with `*`.
5. **Starts `claude remote-control`** with no permission prompts and no "Enable Remote Control?" question. It can access every local drive, so you just tell it which project to work on.
6. **Cleans up when you're done:** clean shutdown so the session is archived, `claude auth logout`, and the temp folder is deleted. Leftovers from sessions that ended badly are removed on the next run.

## Requirements

- Windows with PowerShell 5.1 or later (Windows Server 2022 on LCS VMs works out of the box).
- A Claude **Pro or Max** subscription. Remote Control needs a claude.ai login; API keys are not supported.
- The Claude app (desktop, web or mobile) on **your own** machine, signed in with the same account.
- Outbound HTTPS from the VM to `claude.ai` and `anthropic.com`.
- For D365 F&O: [d365fo-mcp-server](https://github.com/dynamics365ninja/d365fo-mcp-server), installed and configured on the VM (`npm install -g d365fo-mcp`).

## Install

On the VM, open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/DavideWasTaken/claude-remote-session/main/install.ps1 | iex
```

It asks for a session name (for example the customer's name, or press Enter to use the computer name), then creates:

- `Documents\claude-remote-session\claude-session.ps1`: the script;
- `Documents\claude-remote-session\session-name.txt`: the session name, which you can edit at any time;
- `Desktop\Claude Remote Session.cmd`: the double-click launcher.

Run the same command again to update the script. Your session name is kept.

If you'd rather install by hand, copy `claude-session.ps1` and `claude-session.cmd` into the same folder and double-click the `.cmd`.

## Usage

1. Double-click **Claude Remote Session** on the Desktop.
2. Paste the sign-in link (it's already in your clipboard) into the browser on **your** PC, sign in, copy the code and paste it into the VM console.
3. Close the RDP window with the **X**. Don't use *Sign out*: that would end the session.
4. Open the session from the Claude app on your PC and tell it what to work on, for example *"use project 1311 in C:\Users\...\source\repos\1311"*.

To end the session, type **"chiudi tutto"** in the session, archive it from the app, or press Ctrl+C in the VM console. The script then signs out and deletes the temp folder.

### Optional parameters

You only need these when running the script from PowerShell instead of double-clicking.

| Parameter | Default | Meaning |
|---|---|---|
| `-Project` | `%USERPROFILE%\source\repos` | Starting folder |
| `-Name` | `session-name.txt`, or asked on first run | Session name shown in the app |
| `-ExtraDirs` | all local fixed drives | Folders Claude may access |
| `-McpUrl` | `http://127.0.0.1:8080/mcp` | Used only if no `d365` MCP config is found |

To force a specific MCP configuration on a VM, put an `mcp.json` next to the script:

```json
{ "mcpServers": { "d365": { "type": "http", "url": "http://127.0.0.1:8080/mcp" } } }
```

## Security notes

This reduces exposure a lot, but on a machine where others are administrators it can't make you invisible. Be aware that:

- **While the session runs**, the login token is in the temp folder and in process memory. A local admin, or an Azure admin taking a disk snapshot, could read it. When the session ends it is signed out and deleted.
- **Deleted files are removed normally, not wiped**, so forensic recovery is possible.
- **The session runs with `bypassPermissions`**: Claude executes commands, edits files and runs MCP tools such as SQL queries without asking. Keep that in mind on customer environments.
- **Files Claude creates in your projects**, for example `.claude\settings.local.json`, are not removed. The script warns you if it finds one.
- **Make sure your contract allows** sending the customer's code to an AI service.

Console messages and the in-session instructions are in Italian.

## License

[MIT](LICENSE)
