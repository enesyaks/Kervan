# Kervan roadmap

Every step produces a self-contained, testable feature.

| # | Feature | Status |
|---|---|---|
| M0 | VM, systemd service, `/health` | ✅ |
| M1 | Protocol v1, token-authenticated WebSocket, Mac connect screen | ✅ |
| M2 | Single-agent session (Claude Code, ACP), Mac chat screen, streamed responses | ✅ |
| M3 | Persistence: SQLite event log, restart recovery and resumption | ✅ |
| M4 | Tool calls and permission approval (Allow / Reject) | ✅ |
| M5 | Multi-session, history screen, full-text search | ✅ |
| M6 | File upload / download, workspace browser | ✅ |
| M7 | Agent registry (`agents.yaml`): Codex, Gemini, OpenCode | ✅ |
| M7b | Skill and MCP management: skill library, per-session/role toggles | ✅ |
| M7c | Add / edit agents from the app (node picker via M13) | ✅ |
| M8 | Teams and roles, manual team creation | ✅ |
| M9 | Orchestration MCP server: lead agent starts helpers and messages them | ✅ |
| M10 | Team view: multi-panel display, activity stream | ✅ |
| M11 | Helper isolation via git worktrees, budgets and limits | ✅ |
| M12 | PTY fallback, notifications, resilience; model picker | ✅ |
| M13 | Multi-server (nodes): run agents on other machines | ✅ |
| — | Changes panel with checkpoints and rewind | ✅ |
| — | Agent plan and slash commands | ✅ |
| — | @-mentions and image paste | ✅ |
| — | Projects: shared workspaces, instructions, repository cloning | ✅ |
| — | Scheduled tasks: recurring and interval runs, timezone support | ✅ |
| — | Usage view: cost tracking by agent and session, daily reports | ✅ |
| — | In-workspace terminal and localhost port preview tunnel | ✅ |
| — | Localization: English and Turkish UI | ✅ |
| later | Team: users, authentication, sharing | |

## M7b: Skill and MCP management

Adding capabilities to agents directly from the Mac app.

- **Skill library:** On the server under `/var/lib/kervan/skills/<name>/SKILL.md` (+ supporting files). Uploaded as a folder from the Mac, listed, and deleted.
- **Per-session / per-role selection:** Choose which skills are active when starting a new session (and in M8 role definitions).
- **Passing to agents:** For Claude, selected skills are symlinked or copied into `.claude/skills/` in the session's workspace at launch. For agents without native skill support, content is injected into the system prompt.
- **MCP servers:** Configured from the same screen (command + args or HTTP URL + headers) and passed to each agent via ACP `session/new` / `session/resume` in `mcpServers`. This lets Claude, Codex, and Gemini share the same tools. Secret values (API keys) stay on the server under `/etc/kervan/` and never reach the Mac.

## M7c: Managing agents from the app

Adding and configuring agents from the Mac app's Settings screen without manually editing `agents.yaml`.

- **Form:** Name, command (or built-in adapter), args, `authMethod`, environment variables (secrets stay on the server), skills folder. Before saving, the server tests that the command executes and responds to ACP `initialize`.
- **Storage:** Server-side `agents.json` (managed agents) + optional manual `agents.yaml`.
- **Node field:** Each agent record includes `node` (defaults to `local`). When M13 is enabled, the form offers a node picker; the agent runs on the selected node, and the session view indicates where it is running.

## M13: Multi-server (nodes)

Distributing tasks across agents on multiple machines.

- **Hub:** The primary `kervan` server. History, teams, task dispatch, and the Mac connection live here.
- **Node:** A lightweight `kervan-node` service running on secondary machines. It connects outbound to the hub over Tailscale, reports installed agents and idle capacity, keeps no persistent state, runs agents, and streams events back to the hub.
- **Placement:** When a lead agent calls `start_helper`, the hub assigns the helper based on agent capability and node load. Agents added from the app (M7c) can target a specific node, and user roles can be pinned to a specific node.
- **Shared files:** Handled via git. Each node clones the task's repository, each helper works on its own branch and pushes changes, and the lead agent merges. Network filesystems (NFS) are not required.
- **AgentRunner abstraction:** Agent execution is decoupled behind the `AgentRunner` interface. Remote nodes implement this interface, leaving session and team logic unchanged.

### Adding nodes

Nodes are managed from the app under **Settings › Agents › Add node…**. Provide a name; the app requests a single-use, 30-minute invite code from the hub and provides two setup paths:

- **Command:** Run `curl -fsSL 'http://kervan:7420/v1/node/install?code=…' | sudo bash` on the new machine. The onboarding script installs Node.js 24, downloads the Kervan code bundle from the hub, sets up the `kervan` user and `kervan-node` systemd service, and exchanges the invite for a node-specific token in `/etc/kervan/node.env`. Works on Ubuntu/Debian over Tailscale.
- **SSH:** Enter the address and username; the app runs the installation script over SSH using the Mac's SSH key with `sudo -n`.

Once connected, the node appears live in the app. Each node has its own authentication key; removing a node revokes its key. Manual configuration via shared `KERVAN_NODE_TOKEN` remains supported. Deploying updates: `infra/deploy.sh ubuntu@<node> kervan-node`.

## Shipped features

### Changes panel, checkpoints, and rewind
Before each prompt, Kervan takes an internal git snapshot of the workspace in a separate store, leaving the project's own git history untouched. The **Changes** panel shows all modified, added, and deleted files with line-by-line diffs since the first or last message. Users can rewind the entire folder or selected files to any previous message checkpoint, or commit working changes directly to the project's git repository.

### Agent plan and slash commands
When an agent reports its to-do list, an interactive **plan card** appears above the composer showing pending, in-progress, and completed steps with priorities. Typing `/` surfaces slash commands provided dynamically by the agent (such as `/review` or `/compact`), with inline parameter hints.

### @-mentions and image paste
Typing `@` in the composer brings up a fuzzy file picker of workspace paths; selecting a file inserts it as an attachment. Pasting images via **⌘V** attaches screenshots as visual inputs for multimodal models, and the microphone button triggers macOS dictation.

### Projects
Projects link sessions to a shared workspace on the server—from an existing path, an empty folder, or a cloned git repository. Project-level instructions (coding standards, test commands, conventions) are automatically prepended to every session started within that project. In a git repository each session gets its own worktree and branch, so parallel sessions never edit the same files; archiving can remove the worktree while keeping the branch.

### Scheduled tasks
Automated tasks run on recurring daily schedules (at specific times on selected weekdays) or periodic intervals (every N minutes). When due, Kervan starts a dedicated session, executes the user prompt, records the outcome, and sends a system notification upon completion. Schedules respect the user's local Mac time zone.

### Usage and cost view
Tracks spending across models and sessions based on reported ACP usage. The usage dashboard provides daily spending totals and breakdowns by agent over configurable timeframes (7 days, 30 days, or custom ranges), along with highest-spending session rankings.

### In-workspace terminal and port preview tunnel
The side panel includes an interactive bash terminal running inside the session workspace on the server via PTY. When agents run local dev servers (e.g. `:3000`), Kervan detects listening ports and exposes them to the Mac through a raw TCP-over-WebSocket tunnel, enabling instant browser preview on `localhost`.

### Localization
Complete bilingual support across the native macOS application in English and Turkish, automatically matching system language preferences or selectable in Settings.

### In-app updates
The Mac app checks GitHub releases, verifies the download against its `.sha256` file, swaps itself and relaunches. When the connected server is older than the app, the sidebar offers a server update over SSH that replaces only the code and service, keeping settings, workspaces and the token.

### Report a problem
Help › Report a Problem… collects versions, connection state and the server's recent log, with API keys, tokens and secrets removed, and opens a prefilled GitHub issue you can edit before sending.

### Web version
The server serves a phone-first web client at its own address: sessions, the conversation, approvals, sending,
stopping and new sessions, in English or Turkish. It's off until turned on in the app; each browser is paired with a
one-time code, gets its own revocable key, may only work with sessions, and failed tries are rate-limited.

### Pull requests from a session
The Changes panel pushes a session's work on its own branch and opens a pull request with `gh` on the server, or
opens GitHub's compare page ready to send.

### First-use tour
After the onboarding, six short cards walk through sessions, projects, approvals, the side panel, scheduled tasks and usage, and where to get help. Shown once; Help › Welcome Tour plays it again.

---

## Up next

The detailed plan, with acceptance criteria per step: [plans/next-features.md](plans/next-features.md).

- **Real-agent end-to-end testing:** Automated test suites that execute real coding agents (Claude Code, Codex, Gemini) against sample repositories over ACP, validating tool calls, plan updates, diff generation, and recovery.
