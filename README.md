# Kervan

Uzak bir sunucuda (Proxmox VM) birden çok AI ajan CLI'ını çalıştırıp native bir Mac uygulamasından yönetmek için.

```
docs/      Yol haritası (ROADMAP.md)
mac/       SwiftUI istemci (Swift package, Xcode gerekmez)
protocol/  Mac ↔ sunucu mesaj şeması (v1.md)
server/    Gateway daemon (Node 24, TypeScript)
infra/     VM kurulumu, systemd, deploy
```

## Yerel geliştirme

```bash
cd server
npm install
npm test
npm run dev        # http://127.0.0.1:7420/health, ws://127.0.0.1:7420/v1/ws
```

Mac uygulaması:

```bash
cd mac
swift test
scripts/bundle.sh                     # mac/build/Kervan.app
open build/Kervan.app
```

Yerel sunucuya Keychain'e dokunmadan bağlanmak için:
`KERVAN_SERVER=localhost KERVAN_TOKEN=local-dev-token-not-secret build/Kervan.app/Contents/MacOS/Kervan`

## VM kurulumu (bir kez)

1. Proxmox'ta Ubuntu 24.04 VM aç (öneri: 8 vCPU / 16 GB RAM / 60 GB disk).
2. `infra/` klasörünü VM'e kopyala ve kurulum betiğini çalıştır:
   ```bash
   scp -r infra <user>@<vm-ip>:~/
   ssh -t <user>@<vm-ip> 'sudo bash ~/infra/vm-setup.sh'
   ```
3. VM'yi tailnet'e bağla: `ssh -t <user>@<vm-ip> 'sudo tailscale up'`
4. Proxmox'ta bir snapshot al.

## Deploy

```bash
infra/deploy.sh ubuntu@kervan
```

Mac'ten kontrol: `curl http://kervan:7420/health`

## Sunucudaki yerler

| Yol | İçerik |
|---|---|
| `/opt/kervan/server` | Uygulama kodu |
| `/etc/kervan/env` | Ortam değişkenleri (`KERVAN_HOST`, `KERVAN_PORT`, `KERVAN_DATA_DIR`, `KERVAN_TOKEN`) |
| `/var/lib/kervan` | SQLite veritabanı (konuşma geçmişi, M3'ten itibaren) |
| `/var/lib/kervan/workspaces` | Oturum çalışma klasörleri (`KERVAN_WORKSPACES_DIR` ile değiştirilebilir) |

Loglar: `journalctl -u kervan -f`

## Claude girişi (VM, bir kez)

```bash
ssh -t ubuntu@kervan 'sudo -u kervan -H /opt/kervan/server/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude'
```

Açılan ekranda `/login`, sonra `/exit`. Arayüzü gerçek ajan olmadan denemek için: `node server/scripts/dev-fake-server.ts`.
