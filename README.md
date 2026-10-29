# Kervan

Uzak bir sunucuda (Proxmox VM) birden çok AI ajan CLI'ını çalıştırıp native bir Mac uygulamasından yönetmek için.

```
mac/       SwiftUI istemci            (M1'de eklenecek)
protocol/  Mac ↔ sunucu mesaj şeması  (M1'de eklenecek)
server/    Gateway daemon (Node 24, TypeScript)
infra/     VM kurulumu, systemd, deploy
```

## Yerel geliştirme

```bash
cd server
npm install
npm test
npm run dev        # http://127.0.0.1:7420/health
```

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
| `/etc/kervan/env` | Ortam değişkenleri (`KERVAN_HOST`, `KERVAN_PORT`, `KERVAN_DATA_DIR`) |
| `/var/lib/kervan` | SQLite veritabanı (konuşma geçmişi, M3'ten itibaren) |
| `/srv/kervan/workspaces` | Oturum / takım çalışma klasörleri |

Loglar: `journalctl -u kervan -f`
