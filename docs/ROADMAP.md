# Kervan yol haritası

Her adım tek başına çalışan, test edilebilir bir özellik bırakır.

| # | Özellik | Durum |
|---|---|---|
| M0 | VM, systemd servisi, `/health` | ✅ |
| M1 | Protokol v1, token'lı WebSocket, Mac bağlantı ekranı | ✅ |
| M2 | Tek ajan oturumu (Claude Code, ACP), Mac sohbet ekranı, cevap akışı | ✅ |
| M3 | Kalıcılık: SQLite olay günlüğü, yeniden bağlanınca geçmişin gelmesi | |
| M4 | Araç çağrıları ve izin onayı (Onayla / Reddet) | ✅ |
| M5 | Çoklu oturum, geçmiş ekranı, tam metin arama | |
| M6 | Dosya yükleme / indirme, çalışma klasörü tarayıcısı | |
| M7 | Ajan kayıt defteri (`agents.yaml`): Codex, Gemini, OpenCode | |
| M8 | Takımlar ve roller (`roles.yaml`), takımı elle kurma | |
| M9 | Orkestrasyon MCP sunucusu: ana ajan yardımcı başlatır ve mesajlaşır | |
| M10 | Takım görünümü: çok panelli ekran, akış şeridi | |
| M11 | Git worktree ile yardımcı izolasyonu, bütçe ve sınırlar | |
| M12 | PTY yedeği, bildirimler, dayanıklılık | |
| M13 | Çoklu sunucu (node) | |
| sonra | Ekip: kullanıcılar, giriş, paylaşım | |

## M13: Çoklu sunucu

Bir görevi birden çok sunucudaki ajanlara dağıtmak.

- **Merkez (hub):** bugünkü `kervan` sunucusu. Geçmiş, takımlar, görev dağıtımı ve Mac bağlantısı burada kalır.
- **Node:** diğer sunucularda çalışan hafif `kervan-node` servisi. Merkeze Tailscale üzerinden kendisi bağlanır,
  hangi ajanların kurulu olduğunu ve boş kapasitesini bildirir. Durum tutmaz; ajanları çalıştırır, olayları merkeze akıtır.
- **Yerleştirme:** ana ajan `spawn_helper` dediğinde merkez, ajan türüne ve node yüküne göre node seçer.
  Kullanıcı rolü belirli bir node'a sabitleyebilir.
- **Ortak dosyalar:** git üzerinden. Her node görevin reposunu klonlar, her yardımcı kendi branch'inde çalışır ve push eder,
  ana ajan birleştirir. Ağ dosya sistemi (NFS) kullanılmaz.
- **Hazırlık (M2'den itibaren):** ajanları çalıştıran kod `AgentRunner` arayüzünün arkasında.
  Uzak node, bu arayüzün ikinci bir uygulaması olacak; oturum ve takım kodu değişmeyecek.
- **Riskler:** node başına ajan girişleri (her sunucuda ayrı login), merkez ile node arasında bağlantı kopması
  (node olayları tamponlar, yeniden bağlanınca gönderir), maliyetin node'lara dağılması.
