# Güvenlik

## Açık bildirmek

Bir güvenlik açığı bulduysanız lütfen **herkese açık bir issue açmayın.** GitHub'ın
[özel güvenlik bildirimi](https://github.com/enesyaks/Kervan/security/advisories/new) üzerinden yazın.
Bildirimi birkaç gün içinde yanıtlamaya, düzeltmeyi yayımlayana kadar ayrıntıları gizli tutmaya çalışırım.

Faydalı olur:

- Etkilenen bileşen (sunucu, Mac uygulaması, kurulum betikleri) ve sürüm ya da commit,
- Açığı yeniden üretmek için adımlar,
- Olası etki.

## Kapsam ve tasarım varsayımları

Kervan **kendi ağınızda** çalışmak üzere tasarlandı:

- Sunucu yerel ağda ya da Tailscale içinde çalışır; doğrudan internete açılması desteklenmez.
- Erişim tek bir paylaşılan token iledir (`/etc/kervan/env`). Token'a sahip olan, ajanları ve terminali kullanabilir;
  yani sunucuda `kervan` kullanıcısı yetkisiyle komut çalıştırabilir.
- Ajanlar bu kullanıcıyla çalışır; systemd servisi `ProtectSystem=strict` ile yazma alanını sınırlar.
- API anahtarları ve MCP sırları sunucuda `0600` izinli dosyalarda durur ve istemciye gönderilmez.

Bu varsayımların dışına çıkan her şey (token olmadan erişim, anahtarların istemciye sızması, yazma alanının dışına
çıkabilmek, node token'ıyla uygulama API'sine erişmek) güvenlik açığı sayılır.
