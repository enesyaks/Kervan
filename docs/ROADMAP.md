# Kervan yol haritası

Her adım tek başına çalışan, test edilebilir bir özellik bırakır.

| # | Özellik | Durum |
|---|---|---|
| M0 | VM, systemd servisi, `/health` | ✅ |
| M1 | Protokol v1, token'lı WebSocket, Mac bağlantı ekranı | ✅ |
| M2 | Tek ajan oturumu (Claude Code, ACP), Mac sohbet ekranı, cevap akışı | ✅ |
| M3 | Kalıcılık: SQLite olay günlüğü, yeniden başlatmada kurtarma ve devam | ✅ |
| M4 | Araç çağrıları ve izin onayı (Onayla / Reddet) | ✅ |
| M5 | Çoklu oturum, geçmiş ekranı, tam metin arama | ✅ |
| M6 | Dosya yükleme / indirme, çalışma klasörü tarayıcısı | ✅ |
| M7 | Ajan kayıt defteri (`agents.yaml`): Codex, Gemini, OpenCode | ✅ |
| M7b | Skill ve MCP yönetimi: skill kütüphanesi, oturum/rol başına açma | ✅ |
| M7c | Ajanları uygulamadan ekleme / düzenleme (node seçimi M13 ile) | ✅ |
| M8 | Takımlar ve roller, takımı elle kurma | ✅ |
| M9 | Orkestrasyon MCP sunucusu: ana ajan yardımcı başlatır ve mesajlaşır | ✅ |
| M10 | Takım görünümü: çok panelli ekran, akış şeridi | ✅ |
| M11 | Git worktree ile yardımcı izolasyonu, bütçe ve sınırlar | ✅ |
| M12 | PTY yedeği, bildirimler, dayanıklılık; model seçici | ✅ |
| M13 | Çoklu sunucu (node): ajanları başka makinelerde çalıştırma | ✅ |
| sonra | Ekip: kullanıcılar, giriş, paylaşım | |

## M7b: Skill ve MCP yönetimi

Ajanlara yetenek eklemek, Mac uygulamasından.

- **Skill kütüphanesi:** sunucuda `/var/lib/kervan/skills/<ad>/SKILL.md` (+ yardımcı dosyalar). Mac'ten klasör olarak
  yüklenir, listelenir, silinir.
- **Oturum / rol başına seçim:** yeni oturum açarken (ve M8'de rol tanımında) hangi skill'lerin açık olacağı seçilir.
- **Ajana iletme:** Claude için seçilen skill'ler oturum başlarken çalışma klasörüne `.claude/skills/` olarak bağlanır
  (kopya ya da sembolik bağlantı). Skill kavramı olmayan ajanlar için içerik sistem talimatına eklenir.
- **MCP sunucuları:** aynı ekrandan tanımlanır (komut + argümanlar ya da HTTP adresi + başlıklar) ve ACP
  `session/new` / `session/resume` içindeki `mcpServers` ile her ajana verilir; böylece Claude, Codex ve Gemini aynı
  araçları kullanır. Gizli değerler (API anahtarları) Mac'te değil sunucuda, `/etc/kervan/` altında tutulur.

## M7c: Ajanları uygulamadan yönetme

`agents.yaml`'ı elle düzenlemeden, Mac uygulamasının Ayarlar ekranından ajan eklemek.

- **Form:** ad, komut (ya da yerleşik adaptör), argümanlar, `authMethod`, ortam değişkenleri (gizli değerler sunucuda kalır),
  skill klasörü. Kaydetmeden önce sunucu komutun çalıştırılabildiğini ve ACP `initialize` cevabını dener.
- **Kayıt:** sunucu tarafında `agents.json` (yönetilen ajanlar) + isteğe bağlı elle yazılmış `agents.yaml`.
- **Node alanı:** her ajan kaydında `node` (bugün yalnızca `local`). M13 geldiğinde formda node seçici açılır; ajan seçilen
  node'da çalışır, oturum ekranı hangi node'da çalıştığını gösterir.

## M13: Çoklu sunucu

Bir görevi birden çok sunucudaki ajanlara dağıtmak.

- **Merkez (hub):** bugünkü `kervan` sunucusu. Geçmiş, takımlar, görev dağıtımı ve Mac bağlantısı burada kalır.
- **Node:** diğer sunucularda çalışan hafif `kervan-node` servisi. Merkeze Tailscale üzerinden kendisi bağlanır,
  hangi ajanların kurulu olduğunu ve boş kapasitesini bildirir. Durum tutmaz; ajanları çalıştırır, olayları merkeze akıtır.
- **Yerleştirme:** ana ajan `spawn_helper` dediğinde merkez, ajan türüne ve node yüküne göre node seçer.
  Uygulamadan eklenen ajanlar (M7c) belirli bir node'a bağlanabilir.
  Kullanıcı rolü belirli bir node'a sabitleyebilir.
- **Ortak dosyalar:** git üzerinden. Her node görevin reposunu klonlar, her yardımcı kendi branch'inde çalışır ve push eder,
  ana ajan birleştirir. Ağ dosya sistemi (NFS) kullanılmaz.
- **Hazırlık (M2'den itibaren):** ajanları çalıştıran kod `AgentRunner` arayüzünün arkasında.
  Uzak node, bu arayüzün ikinci bir uygulaması olacak; oturum ve takım kodu değişmeyecek.
- **Riskler:** node başına ajan girişleri (her sunucuda ayrı login), merkez ile node arasında bağlantı kopması
  (node olayları tamponlar, yeniden bağlanınca gönderir), maliyetin node'lara dağılması.

## M13: Node'lar

Hub (ana Kervan sunucusu) ajanları başka makinelerde de çalıştırabilir. Her makinede `kervan-node` çalışır,
hub'a Tailscale üzerinden kendisi bağlanır (node'da açık port gerekmez) ve hub'ın verdiği ajanları kendi
`/srv/kervan/workspaces` klasöründe başlatır. Sohbet, onaylar, model seçimi ve dosyalar uygulamada aynı görünür.

Kurulum (node makinesinde, vm-setup.sh'tan sonra):

1. Hub'da `/etc/kervan/env` dosyasına `KERVAN_NODE_TOKEN=<en az 16 karakter>` ekleyip `kervan`'ı yeniden başlatın.
2. Node'da `/etc/kervan/node.env`: `KERVAN_HUB_URL=ws://kervan:7420`, aynı `KERVAN_NODE_TOKEN`, isterseniz `KERVAN_NODE_NAME=gpu`.
3. `infra/kervan-node.service` dosyasını `/etc/systemd/system/` altına kopyalayıp `systemctl enable --now kervan-node`.
4. Kod güncellemesi: `infra/deploy.sh ubuntu@<node> kervan-node`.
5. Uygulamada Ayarlar › Ajanlar'da node bağlı görünür; bir ajanı düzenleyip Node alanından seçin.

İlk sürümün sınırları: ana ajanlar (yardımcı başlatan) ve skill'li oturumlar hub'da çalışır; node'daki yardımcılar
ana ajanın klasörünü göremez, kendi klasörlerinde çalışır. Node'dan inen/yüklenen dosyalar 50 MB ile sınırlı.
Bağlantı koparsa node'daki ajanlar durur; node geri gelince bir sonraki mesajla kaldıkları yerden devam ederler.

Sonra: bir görevi node'lar arasında otomatik dağıtma (ana ajan hangi yardımcının nerede çalışacağını seçer),
node'lara skill dağıtımı.
