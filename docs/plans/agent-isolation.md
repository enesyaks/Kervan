# Running agents apart from the server

Status: built on hubs, step 6 (nodes) open. Comes from a security review; the problem below was reproduced on a local server.

## The problem

Agents run as the same system user as Kervan and inherit its environment (`runner.ts`, `pty.ts`, `terminals.ts`). An
agent's command can therefore read `KERVAN_TOKEN`, which is the app's full key. In the reproduction, a command run by an
agent used the key and `/v1/check` answered 200.

Approvals are the only thing between an agent and the server, and this gets around them. One approved command in a
hostile repository (`npm test`, a postinstall script) is enough to answer the agent's own approval requests, pair a new
browser, open terminals and read every session. Packages installed from the agent catalog get the same environment.

Clearing the variable isn't enough. The same user can read `/etc/kervan/env` (`640 root:kervan`) and everything under
`/var/lib/kervan`: every agent's API keys, MCP secrets, alert settings. Only a different user fixes that.

## Decision

**Agents, their terminals and their sign-ins run as a second system user, `kervan-agent`, started through a narrow sudo
rule.** The server stays `kervan` and keeps the secrets.

```
kervan        /etc/kervan/env, /var/lib/kervan (keys, database), gh's sign-in
  └ sudo -n -u kervan-agent /opt/kervan/server/bin/run-agent <program> <args>
kervan-agent  /home/kervan-agent (agent logins), /srv/kervan/workspaces
```

## Options weighed

| | Keeps changes, commit, PR, review | New moving parts | Weakens the service | Verdict |
|---|---|---|---|---|
| **sudo to a fixed wrapper** | Yes | One small script, one sudoers line | Drops `NoNewPrivileges` on the server | **Chosen**, if the spike below holds |
| A launcher service as `kervan-agent`, stdio over a socket | Yes | A daemon, its protocol, its restarts | No | Fallback if the spike fails: more code, stronger service sandbox |
| Agents on a local `kervan-node` | **No**: `requireLocal` refuses changes, undo, commit, review and PR for sessions on a node | Node service and token | No | Set aside |
| `spawn` with `uid`/`gid` and `CAP_SETUID` | Yes | None | Severely: a compromised server can become any user, root included, and ambient capabilities can reach the agent | Set aside |
| Containers per agent | Yes, with mounts | A container runtime on every server | No | Later, as an option; too heavy as the default |

## What changes

**Environment.** Agents get a short allowed list (`PATH`, `HOME`, `LANG`, `TERM`…) plus their own `command.env`, instead
of `...process.env`. sudo's `env_reset` enforces this from outside the server too; the wrapper reads the agent's variables
from stdin so secrets don't appear in `ps`. One agent's API key no longer reaches another agent.

**Service.** `NoNewPrivileges` has to go from `kervan.service`, or sudo can't work. The wrapper sets it again for the
agent with `setpriv --no-new-privs`, so the agent can't use sudo or setuid programs. The sudoers rule allows only the
wrapper, only as `kervan-agent`.

**Files.**
- `/srv/kervan/workspaces`: owned by `kervan-agent`, group `kervan`, setgid, so the server can read diffs and uploads.
- Agent logins move to `/home/kervan-agent`. `agentlogin.ts` runs through the wrapper.
- Catalog agents move from `/var/lib/kervan/tools` to `/srv/kervan/tools`, and checkpoints to `/srv/kervan/checkpoints`.
- The orchestra socket becomes `660` with group `kervan-agent`; its per-session token still says who is calling.
- `gh`'s sign-in stays with `kervan`. **Agents can no longer push or open pull requests with it themselves**; the app's
  pull request button still can. This is a behaviour change to call out in the release notes.

**Git (review finding 7).** Today this is low risk, because the agent is already the same user. After the split it would
be the way back in: the server runs git in folders the agent controls, so a `post-commit` hook or `core.fsmonitor` in
`.git/config` would run as `kervan`, with the secrets. So every server-side git and gh call in a workspace
(`checkpoints.ts`, `pullrequest.ts`, `worktree.ts`) goes through one helper that neutralises this: `core.hooksPath`,
`core.fsmonitor`, `core.sshCommand`, `core.pager`, `diff.external`, `credential.helper`, `commit.gpgsign` and protocol
allow-lists set on the command line, plus `safe.directory` for that folder. **This has to ship no later than the split.**

**Macs and development.** There's no second user there. With `KERVAN_AGENT_USER` unset the server starts agents directly
as today, with the cleaned environment. The app says agents aren't separated on such a server.

## Steps

1. **Clean environment. Done** (`agentenv.ts`). An agent that needs a variable names it with `inheritEnv` in `agents.yaml`.
2. **Git helper. Done** (`safegit.ts`). Hooks, fsmonitor and signing are overridden through `GIT_CONFIG_*`, so gh's git is
   covered too. What can't be overridden (`filter.*`, `diff.*.command`, `url.*`, `credential.*`, …) makes Kervan refuse to
   run git in that repository, Git LFS's own filter excepted. Kervan also refuses to push to a folder on the server, since
   that runs that repository's hooks as `kervan`.
3. **Spike. Done**, in an Ubuntu 24.04 container with systemd. sudo works under `ProtectSystem=strict`; its real user stays
   `kervan`, so a plain SIGTERM reaches it and it passes it on; PTY agents work.
4. **Server side. Done** (`agentuser.ts`), active when `KERVAN_AGENT_USER` is set.
5. **Setup and migration. Done** in `hub-setup.sh`, in every mode. Tried by installing the previous version and updating.
6. **Nodes. Not done.** `kervan-node` still runs agents as one user, with the clean environment. The node has only its own
   token to protect, which can't drive the app's API.

Two things came out differently from the first draft of this plan:

- **Workspace git runs as the agent user**, not as the server with safeguards: nothing the agent planted can then run as
  the server. Only `git push` and `gh` run as `kervan`, because they need its sign-in, and they stay behind `safegit.ts`.
- **Catalog agents live in `/srv/kervan/tools`, writable by the agent user**, not in a folder it can only read, because npm's
  install scripts must not run as the server. An agent can therefore change a program other sessions use. All sessions
  share one user anyway; see below.

## Acceptance

Through the real entry points, on a VM under systemd, as an agent's own command:

- `$KERVAN_TOKEN` is empty, and another agent's API key isn't in the environment.
- Reading `/etc/kervan/env` and `/var/lib/kervan/agents.json` fails with permission denied.
- `sudo` and writing to the server's code fail.
- A hook and an fsmonitor planted by the agent don't run when the app commits or opens a pull request.
- Still working: Claude and Codex sign-in, approvals, changes, undo, commit, PR, review, worktrees, helpers, terminals,
  uploads, catalog installs. An existing hub upgraded with Server update keeps its sessions and logins.

## What this doesn't solve

- **Sessions can still see each other.** All agents share one user, so one session's agent can read another's folder.
  Separate users per project, or containers, are a later step.
- **Network.** An agent can still reach the internet and Kervan's own port; it just has no key for it. Exfiltrating the
  code it can read remains possible.
- **Approved commands** still do what they do inside what `kervan-agent` can reach.
- **A file an agent makes readable only by itself** (`chmod 600`) can't be downloaded or copied for a review by the server.

## Related

[Rehearsal](rehearsal.md) needs a stricter boundary than this one: it runs commands nobody has approved yet.
