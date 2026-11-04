# This Mac as a node

Status: steps 1 to 6 done, step 7 (the real try) is next. Comes from a request to start a session from the phone and have it use the Ollama models and agents on the Mac.

## What the user gets

On the phone, the new-session list shows `Qwen Code (macbook)` next to the hub's agents. Starting it runs the agent on the Mac, against the Mac's Ollama. The answer comes back through the hub, like any other session. When the Mac is asleep, the phone says so instead of failing later.

```
phone ── Tailscale ──> hub ── connection the Mac opens ──> kervan-node on the Mac ──> agent ──> Ollama at 127.0.0.1:11434
```

The Mac only connects out. No port opens on it, and Ollama stays on loopback.

## What exists and what doesn't

| Piece | Today |
|---|---|
| Running agents on another machine, files over the hub's connection | Works: `node-agent.ts`, `nodes.ts`, `remoteFiles` in `files.ts` |
| A node's own key, invite codes | Works: `onboarding.ts`, `nodes.json` |
| `AgentDetail.node` in the agent list, which the web client already receives | Sent, but the web client ignores it (`app.js` shows only the name) |
| Goose and Qwen Code set up for Ollama | Works, against the hub's Ollama only (`agentregistry.ts`, `ollama()` and `install()`) |
| Installing a node | Debian and Ubuntu only: `installScript` uses `apt-get` and systemd |
| A second user for agents | Linux only: `bin/run-agent` uses `getent` and `setpriv` |
| Whether an agent's node is connected, as seen from the web client | Not sent: `WEB_EVENTS` leaves node updates out on purpose |

Step 1 ran a node on a Mac: see its findings below.

## Decisions

**The node runs as a separate macOS user, `_kervan-node`.** Running as the logged-in user would let any agent command started from a phone read SSH keys, documents and browser data. A hidden user with its own home has none of that, and file permissions should keep it out of the user's home folder. Step 2 checks this, because a new user can land in the `staff` group and `~` itself is often readable by that group.

It costs something, and the app must say so during setup:

- Agents installed in the user's home aren't usable. `~/.kimi-code/bin/kimi` is out of reach, so agents are installed for the node from the catalog.
- Claude, Codex and Gemini need signing in again, as the node.
- The node can't see the user's own project folders. Sessions work in the node's folder, or clone a repository there.

Ollama is unaffected: any user on the Mac can reach `127.0.0.1:11434`.

**It runs from a LaunchDaemon, so it starts without anyone logging in.** Ollama usually doesn't: the Ollama app runs in the user's session. So a logged-out Mac has a connected node and no models. The status has to show that (step 4).

**Setup uses macOS's own administrator prompt** (`osascript … with administrator privileges`). The app never sees the password.

**Only the hub is trusted to send work, and it does so as today.** Approvals work as on any node, and a paired phone can already approve commands. So this feature puts the Mac's node user within reach of the phone, which is the reason for the separate user.

### Known gap, accepted for the first version

Agents run as the same user as `kervan-node`, as on Linux nodes (step 6 of `agent-isolation.md` is still open). An agent could read the node's key and pose as that node to the hub. It can't reach the app's key, the Mac user's files or other machines. Separating the two is a later step for both platforms.

## Options set aside

- **Hub agents use the Mac's Ollama over Tailscale.** Simple, but Ollama has no sign-in, so it would be open to every device on the tailnet. It also gives no access to the Mac's other agents, and the files stay on the hub.
- **Running as the logged-in user.** The easiest setup, and everything on the Mac is one bad command away. Could return later as an explicit, clearly worded choice if the separate user proves too limiting.
- **The Mac app acting as the node itself.** It would stop when the app quits, and the app would hold agent processes and their keys.

## Steps

Each step ends with something that can be checked. Steps 2 to 6 depend on step 1.

### Step 1. Run kervan-node on macOS by hand

Start `node-main.ts` on this Mac as the logged-in user, against a throwaway local hub with a node token and the fake agent. Fix whatever assumes Linux in `node-agent.ts`, `runner.ts` and `pty.ts`.

Acceptance:
- A session on the node answers, and files list, upload and download.
- `node --test` covers anything fixed.
- The findings are written down here: Node version required, and what differs on macOS.

Done on 2026-11-03, on macOS 15.8 with Node 26.5, as the logged-in user: a separate hub process and `kervan-node` process on loopback, with agents saved through `agent.save`.

What worked on the node, with the written file confirmed in the node's folder:
- An ACP session, a terminal agent, approvals, and listing, uploading and downloading files. A path leaving the folder is refused.
- A real model: a terminal agent running `ollama run qwen2.5-coder:1.5b` answered "pong" through the hub.
- Dropping the node gives `node_offline`. After it reconnects, the session continues.

Found and fixed: a node whose workspaces folder didn't exist couldn't start any agent (`ENOENT` from `realpath`). This isn't specific to macOS; Linux setup just makes the folder first.

Findings for later steps:
- **`ollama run` isn't good enough as the agent.** Through a terminal it echoes the prompt back, wrapped, with its own `>>>` lines. Step 4 stays with Goose and Qwen Code over ACP. A real session with either hasn't been run yet.
- **A node has no Changes, terminal or port preview.** The hub refuses the first two ("only for agents on this server"), and ports are listed from the hub's machine. So a phone session on the Mac can't review changes. Step 5 must hide or explain these; bringing them to nodes is separate work.
- **`node:` in `agents.yaml` is ignored.** It's only honoured through `agent.save`, so a hand-written file silently runs the agent on the hub.
- **Step 2 must set `PATH`.** Node and Ollama are in `/opt/homebrew/bin`, which a LaunchDaemon doesn't have.
- **Step 2 must check for `python3`.** Terminal agents need it, and on a Mac without the Command Line Tools `/usr/bin/python3` only offers to install them.
- **Required Node is 24 or newer** (`engines`), which a fresh Mac doesn't have.

Not covered: the separate user, a real hub over Tailscale, a real phone, and sleep.

### Step 2. Install the node on a Mac from a script

Add `infra/mac-node-setup.sh`: create `_kervan-node` with `sysadminctl`, hidden and with its own home; install under `/Library/Application Support/Kervan`; write a root-owned LaunchDaemon; trade the invite code for the node's key; start it. Running it twice updates. Add removal: stop the daemon, remove the user and its folder.

Find Node from Homebrew or a download with a checked hash. Every path must be readable by `_kervan-node`.

Acceptance:
- After running it, the node survives a restart and connects with nobody logged in.
- As `_kervan-node`, reading `~/.ssh` of the Mac's user fails, and `curl 127.0.0.1:11434/api/tags` works.
- The key file is `600` and owned by `_kervan-node`. Removal leaves no user, daemon or folder.

Run on 2026-11-03 on this Mac, against a throwaway hub on loopback. The script differs from the description above in three ways: the user is made with `dscl` (an id below 500, no password, not in `staff`); everything is in `/opt/kervan-node`, because spaces in paths are a risk in agents' commands; and Node.js must already be there, with no download yet.

Checked through a real session on the node, as `_kervan-node`:
- Listing `~` and `~/.ssh` and reading `~/.ssh/config` are refused. Changing Kervan's code is refused, and `sudo` asks for a password nobody has.
- The node's key isn't in the agent's environment, but the agent can read `node.env`: the known gap above.
- A real model answered through `ollama run`, and killing the node brought it back through launchd.

`verify` found a real bug: every check passed except "the service is running". Once the hub went away, the node's process exited with code 0, because its retry timer was `unref`'d and nothing else kept it alive. On Linux, `Restart=always` hid this. Fixed, with a test that starts a real node against an unreachable hub. The fix hasn't been through a real install yet.

After `remove`, no user, folder or service was left, checked from the Mac.

A restart with nobody logged in is untested, because the throwaway hub wouldn't survive it: step 7 covers it with a real hub.

What the node user can still reach, which the plan had not listed:
- **Everything on loopback without a password.** On this Mac: Ollama's full API, which includes deleting models; Podman's port 44000; AirPlay; and the Kervan app's own port previews (8000, 40117), which lead into the hub's dev servers. A fix for Ollama would need a proxy, so for now step 3 must say this in plain words.
- **`screencapture` runs**, but without Screen Recording permission it gets only the wallpaper and menu bar, so the current app's menus show. Its windows stayed out in two tries.
- **Names in `/tmp` and `/Users`.** The sockets checked there (VS Code, Claude's) are `600`, so they can't be opened.
- **Mounted volumes' names** in `/Volumes`.

Found on the way: **agents outlive a node that's killed.** Their pty helpers stay on with parent 1 (seen as the logged-in user in step 1, after `SIGKILL`). A node should end its children when it stops, and a restarted node should clean up. This needs its own fix.

### Step 3. "Use this Mac as a node" in the app

Add it to Settings › Nodes: name, the costs above in plain words, the administrator prompt, progress, then connected. Add Remove with a confirmation. The app only offers this on its own machine, and only with a hub connected. Keep the node's version in step with the app on updates. Load the design skills first.

Acceptance:
- From a fresh Mac user, one button gets to a connected node.
- Cancelling the macOS prompt leaves nothing behind and says so.
- `swift test` covers the command building.

Done on 2026-11-03, against a throwaway hub on loopback with the same version. From the app, setup reached "connected", a real model answered through a session on the node, and Remove took the node off the hub and left no folder, service or process. It did leave the `_kervan-node` user, without saying so: the script ignored `dscl`'s failure. It now retries and fails with a message, and install copes with a user left without its group. Why the delete failed is unknown, and the retry hasn't been shown to fix it yet. `remove` deleted the user both times it ran from Terminal, and not the one time it ran from the app through `osascript`, so macOS's privacy controls are the likely cause (the same route got "Operation not permitted" reading the script from the Desktop). This isn't confirmed, and the real `dscl` error hasn't been seen. For now the app shows a command to finish the job in Terminal; that path hasn't run yet.

The first tries found two real problems. macOS's prompt didn't show or closed by itself when the app wasn't in front, so the app now comes to the front first; this was seen once, without a clear cause, so watch for it. The "nothing changed" notice sat below the fold, so a closed prompt looked as if nothing had happened; it's at the top now, with what macOS said.

Not covered: the failure path, closing the prompt on purpose, Update and Connect here with a real older node, and a real hub. The risk notice still takes a little scrolling at the sheet's height. Setup uses the address the app is connected to, not the choice in "How nodes reach the hub".

### Step 4. Models and agents come from the node they run on

Add node calls for Ollama's status and for the agent catalog, and let `agent.registry` and its install request name a node. Add a node picker to the catalog sheet. Show "Ollama isn't running on this Mac" rather than an empty list.

Acceptance:
- With a fake node reporting models, the catalog lists that node's models, not the hub's.
- Adding Qwen Code for a node writes an agent with that `node` and points at that machine's `127.0.0.1:11434`.
- An agent the hub already has isn't confused with the same agent on the node.

Done on 2026-11-03. `agent.registry` and `agent.install` take a `node`, the node answers with its own registry and Ollama, the agent is saved as `<id>-<node>`, and the catalog has a "Run on" picker. Tested with a stand-in registry on a real node connection; no real Goose or Qwen install has run on a Mac node. The picker was seen listing a connected node, but choosing the node in it hasn't been tried in the app.

Found on the way: `parseClientMessage` only keeps required fields, so **`ollamaModel` never reached the server.** Choosing a model in the catalog did nothing, on hubs too: the agent was installed without Ollama. Fixed, and the test checks the model arrives.

On a node, Claude, Codex and Gemini show as unavailable in the catalog, because the check is about what this server ships. Whether to offer them on nodes is still open.

### Step 5. The phone shows where an agent runs and whether it's there

Add `online` to `AgentDetail`, and send `agents.updated` when a node connects or drops. The web client shows `Qwen Code · macbook` and disables an offline agent with a reason. A session on an offline node says "The Mac is asleep or offline" and keeps the draft. Check the 375 px width.

Acceptance:
- A paired browser receives no node names beyond what `AgentDetail` carries, and still can't call any node message.
- Dropping the node updates the open page without a reload.
- Sending to an offline node keeps the text and shows the reason.

Done on 2026-11-03, in a browser at 375 px against a throwaway hub with a real node process on this Mac. The list shows `Qwen Code · macbook`. Stopping the node updated the open page without a reload: a banner, the session's status, a disabled send button and a disabled choice in New session, with the draft kept. Starting it again brought all of it back, and the kept draft was sent and answered. Changes is hidden for agents on a node, because the server keeps no record for them.

Not covered: a real phone, real sleep rather than a stopped process, and the case where the send fails after the page last heard the node was there. In that case the text is put back, but this hasn't been run. The Mac app's new-session list doesn't show offline nodes this way yet. When a node drops, its session also shows "The agent process exited unexpectedly", which reads worse than it is.

### Step 6. Keep the Mac available, on request

Add an off-by-default "Keep this Mac awake while plugged in" setting for the node, using `caffeinate -s`. State the limit in the app: a closed lid without an external display still sleeps, and nothing wakes it from the phone.

Acceptance:
- On AC power with the setting on, the Mac stays awake; on battery the setting has no effect.
- Turning it off ends the `caffeinate` process.

Done on 2026-11-03: `mac-node-setup.sh keep-awake on|off` runs `caffeinate -s` from a LaunchDaemon as the node's user, and the Nodes settings have a checkbox for it. Tried for real on AC power, from Terminal: on gave macOS's PreventSystemSleep assertion, off and `remove` both ended it and left no service. Not tried: on battery, whether the Mac really stays awake over time, and the checkbox itself.

### Step 7. Try it for real

The checklist and failure log for this step are in [phone-trial.md](phone-trial.md).

With the user, on this Mac with real Ollama models and a hub on the same version: start a Qwen Code or Goose session from a real phone, approve a command, attach a file, then put the Mac to sleep and wake it. Run `/ecc:security-scan` and repeat the attacks from the last pen test against the node's messages, which that test didn't cover.

Acceptance:
- A prompt from the phone is answered by a model on the Mac.
- With the Mac asleep, the phone says so; after waking, the node reconnects and the session continues.
- Findings are fixed or written down here before release.

## Not in this plan

- Access to the user's own project folders from the node.
- Running as the logged-in user.
- Waking the Mac from the phone.
- Windows nodes.
- Separating agents from the node's key.

## Open questions for the user

1. The node name shown on the phone: the Mac's host name, or asked during setup? Planned: asked, with the host name filled in.
2. Which agents matter most after Goose and Qwen Code? Each one needs installing and signing in as the node.
