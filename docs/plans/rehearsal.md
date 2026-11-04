# Rehearsal: see what a command does before approving it

Status: not started. Step 1 decides whether this gets built at all. Comes from a request for a highly useful agent feature that others don't have.

## What the user gets

When an agent asks to run a shell command, Kervan also runs it in a throwaway copy of the session's folder, with no network and no secrets. The approval card shows what happened there, on the phone and on the Mac:

```
rm -rf build && npm run clean
Rehearsal: 2.1 s, exit code 0
  412 files deleted, including src/config.local.json
  Network blocked: registry.npmjs.org
[Approve]  [Reject]  [Show output]
```

The card appears at once and the result joins it when ready. The user can answer before that. Nothing about the real folder changes until they approve, and then the agent runs the command as it does today.

## Why

An approval today shows only the command's text. On a phone, `npm test` or a long pipeline says little about what it will do, so people either approve blindly or stop using the phone.

As of 2026-11-04 I found parts of this elsewhere, but not the whole:

- DryRun is an MCP server the agent has to use. foreguard is a proxy that makes a plan from tool calls.
- AgentFS runs a whole session in an overlay and diffs it afterwards. It isn't tied to single approvals.
- The orchestrators in one 11-tool comparison review work after it's done, through diffs and test gates.

This doesn't prove nobody has it, and it would be easy to copy. The reason to build it is that phone approvals become meaningful, not that it's unique.

## What exists and what doesn't

- Every approval passes through the hub: `session/request_permission` in `runner.ts`, then `askPermission` in `sessions.ts`, for any ACP agent.
- `describe()` reads `rawInput.command` only when it's a string. Which agents send that, and in what form, hasn't been measured.
- `clientCapabilities` is empty, so the agent runs its own commands. Kervan can't apply a rehearsal's result, only run the command a second time.
- Agents already run as `kervan-agent` through `bin/run-agent`, away from the server's secrets. That user can still read other sessions' folders through the workspaces group and reach the network, so it isn't enough here.
- `Checkpoints` already compares a folder's states with git, but it leaves out `node_modules` and `build`, which rehearsals must see.

What the `.32` hub has today (Ubuntu 24.04, kernel 6.8, 4 cores, 3 GB of memory, ext4):

- `bwrap` isn't installed.
- `kernel.apparmor_restrict_unprivileged_userns` is 1, and `unshare -Urn` failed for the SSH user. So a sandbox built on user namespaces needs an AppArmor profile, or a root helper.
- ext4 has no cheap file clones, so a copy costs real time and disk.
- 3 GB is little, and a rehearsal competes with the running agents for it.

## Decisions

**A rehearsal never says "safe".** A hostile script can notice the sandbox and behave. A command may also act differently with the network on, against a database, or after the folder changes. The card says what was seen and nothing else. A clean rehearsal never approves anything by itself, and there's no setting to make it.

**The card never waits.** The request is recorded and shown as today. The result arrives as a new event, `permission_rehearsal`, tied to `requestId`. An answer from the user stops a rehearsal still running.

**If it can't be rehearsed, the card says so.** No command text, too large a folder, another rehearsal running, timed out, sandbox unavailable: each has its own plain sentence. Failure never blocks the approval or hides the buttons.

**Off by default, and it fails closed.** If the sandbox can't confirm its own limits at start, rehearsals are off and Diagnostics says why. An unsandboxed fallback must not exist in the code.

**Everything from a rehearsal is untrusted.** Output and file names are plain text, bounded in size and stripped of control characters. They go to the user's card only, never to the agent or into a prompt.

**One at a time, within limits.** At most one per hub, and limits on time, memory, processes, disk and folder size. Exact numbers come from step 1. A rehearsal that hits the time limit reports what had happened so far.

## Options set aside

- **Asking a model to predict the effects.** Cheap and safe, but it's a guess shown as if it were a fact.
- **Only classifying commands as risky.** DryRun's lower tier does this, and it wouldn't have caught the config file in the example above.
- **Running whole sessions in an overlay.** It would avoid running commands twice, but it changes how every agent runs, and review would come after the work.
- **Docker per rehearsal.** A heavy dependency on a small server, and its daemon is a large thing to expose to the server's user.

## Steps

### Step 1. Try to break the sandbox

On a throwaway machine, not a hub in use. No product code. Start with `bwrap` running as `kervan-agent`, on a copy of the folder, with a fresh network, PID and mount namespace and an empty environment. If it can't pass, try a small root helper, which also widens what sudo allows.

From inside the sandbox, each of these must fail:

- Read `/etc/kervan/env`, `/var/lib/kervan`, another session's folder, or the agent's sign-ins in its home.
- Write anywhere outside the copy, including through a symlink planted in the folder.
- Reach anything over the network: the internet, `127.0.0.1:7420`, the LAN, the Tailscale address, a Unix socket.
- See or signal a process outside, or leave one running after the rehearsal ends.
- Gain privileges through setuid or sudo.

These must be stopped without hurting the server: a fork bomb, filling the disk, using all the memory, and a command that never ends.

Measure the time for a real project folder, with and without `node_modules`. Note what remains open, above all the kernel surface a sandbox still shares.

Acceptance: every attempt above fails, and a typical rehearsal finishes in the time someone would wait at a card. **If not, stop here and write down why.** A weak sandbox is worse than no feature, because it runs unapproved commands.

### Step 2. Measure whether it helps

With the sandbox from step 1, replay about 30 real commands from past `permission_request` events, with the user's agreement to read them. Rate each result: told me something useful, told me nothing, or misleading.

Also record which agents send a usable command, and in what form.

Acceptance, a judgement to confirm with the user: at least half are useful and none is misleading in a way that invites a bad approval. If not, stop.

### Step 3. The rehearsal itself

`server/src/rehearsal.ts`: given a command and a folder, returns exit code, duration, whether it timed out, files added, changed and deleted (counts and the first few paths), and a bounded tail of the output. It takes the sandbox as a dependency, so the flow can be tested with a stand-in.

Tests: each "can't be rehearsed" case, limits, cut-off output, control characters. A test against the real sandbox repeats the attacks from step 1, and it fails rather than skips on a machine set up for it.

### Step 4. Wire it into approvals

Start a rehearsal from `askPermission` for `execute` requests with a usable command, on agents running on the hub. Add the event to `protocol.ts` and `protocol/v1.md`, stop on answer, and clean up after a restart. Check that older apps ignore the new event, on the Mac and in the web client.

Acceptance: an approval works exactly as today with rehearsals off, when one fails, and when one is still running.

### Step 5. The card

Show the result in `ChatView.swift` and `server/web/app.js`, with the design skills loaded for the Mac part. Waiting, finished and "couldn't rehearse" all fit on a phone screen, with full output behind a tap. Wording in both languages, and never "safe".

### Step 6. Setup and the setting

`hub-setup.sh` installs what step 1 chose, and `update` handles existing hubs. A setting turns it on, Diagnostics reports whether the sandbox passed its self-check, and the docs state the limits.

### Step 7. Try it for real

With the user, from a phone, on real work for a while, on one hub. Repeat the attacks through a real agent and run `/ecc:security-scan`.

Acceptance: the user keeps it on because it helps, and findings are fixed or written down before release. Only then consider making it on by default.

## Not in this plan

- Nodes and the Mac. A rehearsal must run where the agent runs, and macOS needs its own sandbox. On a node the card says rehearsals aren't available there.
- Applying a rehearsal's result instead of running the command twice. It would need Kervan to offer agents ACP's `terminal` capability. Whether the agents would use it hasn't been checked.
- File edits. Their diffs are already known without running anything.
- Effects outside the folder: databases, cloud services, pushes.

## Open questions for the user

1. Which throwaway machine for step 1? It needs Ubuntu 24.04 like the hubs and root access that you set up. A new VM is better than `.21`.
2. May step 2 read past commands from the `.32` hub's database?
3. Is it acceptable that rehearsal output, which can show a project's contents, is stored with the session like the rest of its history?
