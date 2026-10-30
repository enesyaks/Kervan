# Katkıda bulunmak

Kervan'a ilginiz için teşekkürler. Hata bildirimi, öneri ve pull request'lerin hepsi açığız.

## Başlamadan önce

- Büyük bir değişiklik düşünüyorsanız önce bir **issue** açın; yön üzerinde anlaşmak ikimizin de zamanını korur.
- Küçük düzeltmeler (yazım, belgeler, açık bir hata) için doğrudan PR açabilirsiniz.

## Geliştirme ortamı

Gerekenler: macOS 14+ ve Xcode Command Line Tools (Swift 6), Node 24.

```bash
# Sunucu
cd server
npm install
npm test
npm run dev          # ws://127.0.0.1:7420/v1/ws, token: local-dev-token-not-secret

# Mac uygulaması
cd mac
swift test
KERVAN_SERVER=localhost KERVAN_TOKEN=local-dev-token-not-secret swift run Kervan
```

Gerçek bir ajan harcamadan arayüz üzerinde çalışmak için: `node server/scripts/dev-fake-server.ts`.

## Kurallar

- **Protokol iki tarafta birlikte değişir.** `server/src/protocol.ts`, `mac/Sources/KervanKit/Protocol.swift`
  ve gerekiyorsa [`protocol/v1.md`](protocol/v1.md) aynı PR'da güncellenir. Uyumsuz bir değişiklikte `PROTOCOL_VERSION` artar.
- **Test.** Yeni davranış testle gelir: sunucuda `server/test/`, Mac tarafında `mac/Tests/`.
  Sunucu testleri sahte bir ACP ajanı kullanır ([`server/test/fixtures/fake-agent.ts`](server/test/fixtures/fake-agent.ts)).
- **Stil.** Çevredeki koda uyun: aynı adlandırma, aynı yorum yoğunluğu. Yorumlar *neden*i anlatır.
- **Arayüz metinleri** Türkçe, siz diliyle, cümle düzeninde yazılır.
- **Gizli bilgiler** (API anahtarları, token'lar) sunucuda kalır; istemciye yalnızca adları gider.

## Pull request

1. Depoyu fork'layın, `main`'den bir dal açın.
2. `npm test` ve `swift test` yerelde geçsin; CI aynılarını çalıştırır.
3. PR açıklamasında neyi, neden değiştirdiğinizi ve nasıl denediğinizi yazın; arayüz değiştiyse ekran görüntüsü ekleyin.

Katkılarınız [MIT lisansı](LICENSE) altında yayımlanır.
