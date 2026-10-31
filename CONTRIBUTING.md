# Contributing

Thanks for your interest in Kervan. Bug reports, ideas and pull requests are all welcome.

## Before you start

- Planning something big? Open an **issue** first; agreeing on the direction saves both of us time.
- Small fixes (typos, docs, an obvious bug) can go straight to a pull request.

## Development setup

You need macOS 14+ with the Xcode Command Line Tools (Swift 6) and Node 24.

```bash
# Server
cd server
npm install
npm test
npm run dev          # ws://127.0.0.1:7420/v1/ws, token: local-dev-token-not-secret

# Mac app
cd mac
swift test
KERVAN_SERVER=localhost KERVAN_TOKEN=local-dev-token-not-secret swift run Kervan
```

To work on the UI without spending a real agent's quota: `node server/scripts/dev-fake-server.ts`.

## Guidelines

- **The protocol changes on both sides together.** `server/src/protocol.ts`, `mac/Sources/KervanKit/Protocol.swift`
  and, where needed, [`protocol/v1.md`](protocol/v1.md) change in the same PR. Breaking changes bump `PROTOCOL_VERSION`.
- **Tests.** New behaviour comes with tests: `server/test/` on the server, `mac/Tests/` for the Mac side.
  Server tests use a fake ACP agent ([`server/test/fixtures/fake-agent.ts`](server/test/fixtures/fake-agent.ts)).
- **Style.** Match the code around you: same naming, same comment density. Comments explain *why*.
- **UI text** is written in English with its Turkish translation next to it: `L("Save", "Kaydet")`.
  Sentence case, plain words.
- **Secrets** (API keys, tokens) stay on the server; clients only ever see their names.

## Pull requests

1. Fork the repository and branch off `main`.
2. Make sure `npm test` and `swift test` pass locally; CI runs the same.
3. In the PR, say what changed, why, and how you tried it; add a screenshot if the UI changed.

## Releases

The app, its `Info.plist` and the server (`server/src/version.ts`) share one version number; a test keeps them in
step.

Releases are signed with one self-signed certificate, "Kervan Release", so an update keeps the app's identity and
the Keychain keeps its saved access key. Create it once on the machine that makes releases with
`mac/scripts/signing-identity.sh`, and back it up (Keychain Access › Export). `bundle.sh` signs ad-hoc when it's
missing, which is fine for development. The app installs an update only if it is signed with the same certificate as
the running copy.

To release, bump the version, then:

```bash
mac/scripts/release.sh     # mac/build/Kervan-<version>-macOS.zip and .sha256
gh release create v<version> mac/build/Kervan-<version>-macOS.zip mac/build/Kervan-<version>-macOS.zip.sha256
```

The app's updater installs a release only when its `.sha256` file is attached and matches.

Contributions are released under the [MIT license](LICENSE).
