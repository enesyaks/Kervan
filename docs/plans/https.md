# HTTPS for the web client

Since then, hubs set up by Kervan answer only over Tailscale (see `tailnet.ts`), so the plain traffic on the home network this
plan worried about is gone. HTTPS itself is still only needed for Web Push and installing the web client as an app.

Step 5 of [next-features.md](next-features.md). The web client works over plain HTTP today. That's fine on a home
network or over Tailscale (WireGuard encrypts the traffic), but browsers hold back two things from HTTP pages:
**Web Push** (alerts straight to the browser, without the ntfy app) and **installing as an app** with a service worker.
On iPhone, Web Push only reaches web apps added to the home screen, and only over HTTPS.

## Decision

**HTTPS through Tailscale Serve, with plain HTTP kept for the home network.** The server's own Tailscale gives it a
name like `kervan.tail1234.ts.net` with a certificate every browser already trusts; `tailscale serve` takes HTTPS on
port 443 there and hands it to Kervan on `127.0.0.1:7420`. Nothing to install on the phone, and it works anywhere the
phone is signed in to Tailscale. On the home network, the HTTP address keeps working as now, without Web Push.

## Options weighed

| | Trusted on every device | Works away from home | What the user does | Verdict |
|---|---|---|---|---|
| **Tailscale Serve** | Yes (Let's Encrypt, issued by Tailscale) | Yes, with Tailscale on the phone | Turn on HTTPS certificates once in Tailscale's admin page; one switch in the app | **Chosen** |
| A certificate the app makes and installs | Only after installing it on each device | Only on the home network | Install a profile on the phone, then turn on full trust for it in Settings (iPhone) | Set aside: many steps per device, and a root the phone trusts for everything is a risk out of proportion |
| A public domain with Let's Encrypt | Yes | Only if the server is reachable from the internet | Own a domain, set up DNS records or open a port | Set aside: Kervan is meant to stay off the internet, and most users have no domain |
| HTTP only (today) | n/a | With Tailscale | Nothing | Kept for the home network, but no Web Push or app install |

## What the user does, all in the app

1. **Settings › Web access** gets a **Secure address (HTTPS)** card. The server reads `tailscale status` and shows one of:
   - *Tailscale isn't set up on the server*: with a button to the Server update flow, which can add it.
   - *HTTPS certificates are off in your Tailscale account*: **Turn on in Tailscale** opens the DNS page of Tailscale's
     admin console, where it's one switch ("HTTPS Certificates"). The card checks again when the app comes back.
   - *Ready*: **Use HTTPS** runs `tailscale serve --bg --https=443 http://127.0.0.1:7420` on the server and shows
     `https://<name>.ts.net` with Copy. **Stop** runs `tailscale serve --https=443 off`.
2. **Add a device** shows the HTTPS address first once it's on; the alerts' tap-to-open link uses it too.

No terminal and no password: the one step that needs root, letting the `kervan` user drive `tailscale serve`, happens
during setup (below).

## What changes

**Server setup.** `hub-setup.sh` runs `tailscale set --operator=kervan` after Tailscale is up, in every mode including
`update`, so hubs already installed get it from the app's Server update. The service stays as hardened as it is: the
`tailscale` CLI talks to `tailscaled` over its socket, which `ProtectSystem=strict` doesn't block.

**Who is asking (the attempt limiter).** Requests that come through Serve arrive from `127.0.0.1`, so counting failures
per address would lump every outside browser together. For loopback requests only, the limiter keys on the
`Tailscale-User-Login` header Serve adds (falling back to one shared bucket); headers from any other address are
ignored, so nobody on the LAN can pick their own bucket. The app's own connection is still never limited.

**Paired browsers.** A browser's key lives with the page's address, so a phone paired on `http://192.168.x.x:7420` is
not paired on `https://….ts.net`. It pairs once more there; its HTTP pairing keeps working, and the device list shows
both. Nothing changes for paired browsers until the user opens the HTTPS address.

**The page.** The content security policy already allows only its own origin, which covers `wss://` on the same name.
A small service worker (for install and, next, Web Push) is served from the same fixed file list.

## Next, on top of this

**Web Push** as a third alert channel next to ntfy and the webhook: the server makes a VAPID key pair once, a paired
browser on the HTTPS address subscribes from the web client ("Alerts on this device"), and approvals, finished turns and
errors go to it with the same content rules (session name optional, never code). Subscriptions belong to a paired
device and go when the device is removed.

## Acceptance (from the plan)

- A written decision with the chosen approach and why the others were set aside: above.
- The steps a user takes, all from the app, with no terminal: *What the user does*.
- What changes for existing paired browsers: *Paired browsers*.
