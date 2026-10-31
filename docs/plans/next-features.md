# Next features

What Kervan should build after 0.3, from a look at the tools people use to run several coding agents at once
(Conductor, Omnara, Happy, Vibe Kanban, Nimbalyst, agtx, Daintree, the Codex app) against what Kervan already has.

## Where Kervan stands

Already there: several agents (Claude Code, Codex, Gemini) on your own server, sessions that survive the Mac sleeping,
approvals, changes with checkpoints and rewind, projects, scheduled tasks, usage, terminal and port preview, teams with
helpers on their own worktrees, nodes, a paired web client, pull requests from a session, in-app updates.

What the field has that Kervan doesn't:

- **Parallel sessions on one repository.** Worktree-per-agent is the baseline everywhere. In Kervan only team helpers
  get a worktree; two sessions in the same project edit the same folder and step on each other.
- **A task board.** Kanban, where moving a card starts an agent and the card follows the session, is the main UI of
  agtx, AgentsRoom, KanBots and (until it wound down) Vibe Kanban.
- **Alerts on the phone.** Omnara and Happy are built around being told when an agent needs you. Kervan's web client
  can't notify over plain HTTP, and the Mac's notifications don't reach a phone.
- **A second opinion before merging.** Diff-first review is how Conductor and Nimbalyst sell themselves; Kervan has the
  diff but no review step by another agent.

## Steps

### Step 1. Isolated worktree per session (done)

Implement an option, on by default for projects that are git repositories, that starts each new session on its own
worktree and branch (`kervan/<title>-<id>`) instead of the shared project folder. The Changes panel, Commit and
Pull request work on that branch; archiving a session offers to remove its worktree. Sessions outside git projects
behave as today.

Acceptance:
- Two sessions in one git project edit the same file without seeing each other's changes.
- A pull request from such a session contains only that session's work.
- Removing an archived session's worktree leaves the project folder and other branches untouched.

### Step 2. Task board

Implement a board view per project with columns To do, Working, Needs you, Review and Done. A card holds a title and a
prompt; moving it to Working starts a session (on its own worktree, from step 1) with the prompt. The card then follows
its session: waiting for approval moves it to Needs you, a finished turn with changes to Review, a merged or closed
pull request to Done. Cards are stored on the server so the Mac and the web client show the same board.

Acceptance:
- Dragging a card to Working starts a session with the card's prompt and links the two.
- The card's column changes by itself as its session's status changes, on the Mac and in the web client.
- The board survives a server restart.

### Step 3. Phone alerts

Implement server-side alerts so a phone hears about an approval or a finished turn without the Mac. The first channel
is ntfy (a topic on ntfy.sh or a self-hosted server), with a generic webhook as the second; both are set in the app.
An alert names the session and what it needs, never the content of code or prompts, and opening it goes to the web
client's session.

Acceptance:
- An approval request sends one ntfy notification within five seconds; resolving it sends none more.
- Alerts carry the session title and kind only; no prompt, code or file content.
- Turning alerts off, or a wrong topic, never blocks or slows a session.

### Step 4. Review by another agent

Implement a "Review with…" action in the Changes panel that starts a reviewer session (any agent) with the session's
diff and the project's instructions, asking for problems ranked by severity. The reviewer works read-only on a copy;
its findings show next to the diff, and one click sends them back to the original session as a message.

Acceptance:
- Review starts a separate session that cannot modify the original session's files.
- Findings appear in the original session's Changes panel and can be sent to its agent as one message.
- A review of a session with no changes is refused with a clear message.

### Step 5. HTTPS for the web client

Plan how the web client gets HTTPS on a home network, so it can install as a proper app and receive Web Push alerts.
Evaluate Tailscale Serve certificates, a local certificate the app installs, and leaving HTTP for the LAN with HTTPS
over Tailscale only. Decide what pairing and the attempt limiter need to change, and how the app explains it.

Acceptance:
- A written decision with the chosen approach and why the others were set aside.
- The steps a user takes, all from the app, with no terminal.
- What changes for existing paired browsers.

### Step 6. Real-agent end-to-end suite

Implement a suite that runs the real agents (Claude Code, Codex, Gemini) against a small sample repository through the
server: a prompt that edits a file, an approval, a checkpoint and rewind, a pull request to a throwaway remote, and
recovery after a server restart. It runs on demand and in a nightly CI job with the keys as secrets, and skips an agent
whose key is missing.

Acceptance:
- One command runs the suite locally and reports per agent.
- The nightly job fails when an agent's edit, approval, rewind or recovery breaks.
- No key is printed in logs.

### Step 7. Documentation

Update the README (both languages), protocol/v1.md and the roadmap for the features above as they ship.
