# Security

## Reporting a vulnerability

If you find a security issue, please **don't open a public issue.** Report it privately through GitHub's
[security advisories](https://github.com/enesyaks/Kervan/security/advisories/new). I'll try to answer within a
few days and keep the details private until a fix is out.

Helpful to include:

- The affected part (server, Mac app, setup scripts) and the version or commit,
- Steps to reproduce,
- The possible impact.

## Scope and design assumptions

Kervan is designed to run **on your own network**:

- The server runs on your local network or inside Tailscale; exposing it directly to the internet isn't supported.
- Access is a single shared token (`/etc/kervan/env`). Whoever has the token can use the agents and the terminal,
  which means running commands on the server as the `kervan` user.
- Agents run as that user; the systemd service limits where it can write with `ProtectSystem=strict`.
- API keys and MCP secrets are kept on the server in `0600` files and are never sent to clients.

Anything that breaks these assumptions counts as a vulnerability: access without the token, keys leaking to a
client, writing outside the allowed paths, or using a node token against the app's API.
