# Telefondan gerçek deneme

Amaç: Mac'teki yerel modelle çalışan bir ajanın telefondan gerçek bir işi bitirebildiğini görmek. `docs/plans/mac-node.md` içindeki 7. adımı kapatır.

Her satırı işaretleyin. Tutmayan her şeyi sondaki günlüğe yazın; sıradaki işleri bu günlük belirleyecek.

**Bu denemede kullanılan:** `.32` hub'ı (`kervan-1.tail62192c.ts.net`, 0.3.17), node `enes-s-macbook-pro`, Ollama ve LM Studio modelleri.

## Başlamadan önce

Şu an uygulama ve node 0.3.16'da, hub 0.3.17'de. Parola gerektiren adımları siz yapacaksınız.

- [ ] Mac uygulamasını 0.3.17'ye güncelleyin.
- [ ] **Ayarlar › Nodes › Güncelle…** ile node'u güncelleyin (macOS yönetici parolası ister).
- [ ] Node'un listede 0.3.17 ve bağlı göründüğünü kontrol edin.
- [ ] Telefonda Tailscale'i açın ve `http://kervan-1.tail62192c.ts.net:7420` adresini açın.
- [ ] Web erişimi kapalıysa Mac uygulamasından açın, tarayıcıyı eşleştirme koduyla eşleştirin.
- [ ] LM Studio sunucusunu açın: `~/.lmstudio/bin/lms server start`

## 1. Ajan kurulumu

Kurulumlar Mac uygulamasındaki katalogdan yapılır, **Nerede çalışsın** olarak Mac seçilir. Yeni model denetimi ilk kez burada gerçek bir kurulumda çalışacak.

- [ ] Node'daki eski ajanları silin: `goose (qwen2.5-coder:7b)` ve `Qwen Code (qwen2.5-coder:7b)`. Bu model araç çağrısı yapamıyor; denetimden geçmezler.
- [ ] Qwen Code'u `qwen2.5-coder:7b` ile ekleyin. **Beklenen:** model reddedilir, nedeni anlaşılır, ajan eklenmez.
- [ ] Qwen Code'u `granite4.1:30b` ile ekleyin. **Beklenen:** eklenir.
- [ ] Goose'u `nemotron-3.5-bolt:e4b` ile ekleyin. **Beklenen:** eklenir. Goose, devam etme kontrolü için gerekli.
- [ ] LM Studio modellerinin menüde göründüğünü kontrol edin.
- [ ] Katalog açıkken LM Studio sunucusunu kapatın. **Beklenen:** birkaç saniye içinde ipucu ve **Başlat** düğmesi görünür. **Başlat**'a basın; modeller kendiliğinden geri gelir.
- [ ] Katalog açıkken Ollama ile küçük bir model indirin. **Beklenen:** birkaç saniye içinde listede görünür.

## 2. Telefondan temel kullanım

Bundan sonraki her şeyi telefondan yapın. Mac açık ve uyanık kalsın.

- [ ] Yeni oturum listesinde ajan `Qwen Code · enes-s-macbook-pro` gibi görünüyor.
- [ ] Basit bir soruya modelden yanıt geliyor. İlk yanıtın süresini yazın: ____
- [ ] Bir komut çalıştırmasını isteyin. Telefonda izin kartı çıkıyor; onaylayınca çalışıyor.
- [ ] Bir komutu reddedin. Ajan çalıştırmıyor.
- [ ] Bir dosya ekleyin. Ajan dosyayı okuyabiliyor.
- [ ] **Gerçek bir iş verin ve bitmesini bekleyin.** Yerel modele gerçekten vereceğiniz bir iş seçin. İş: ____
- [ ] Sonuç işe yarıyor mu? Süre: ____ Bu iş için yeniden yerel modeli seçer miydiniz? ____
- [ ] Mac uygulamasında aynı oturum aynı içerikle görünüyor.
- [ ] Telefonu birkaç dakika kilitleyip açın. Sayfa kendini yeniliyor, kaçan mesajlar geliyor.

Bu oturumda Changes ve Terminal yok; bu bilinen bir eksik, günlüğe yazmayın. Çok rahatsız ettiyse yazın.

## 3. Uyku ve devam etme

Bu bölüm iki soruyu birden yanıtlar. Node'un bağlantısı kopunca ajanlar durur ve bir sonraki mesajda `session/resume` ile açılır. Yani Goose veya Qwen bunu desteklemiyorsa sorun yalnızca sunucu yeniden başlarken değil, **Mac her uyuduğunda** çıkar.

Şu an başka uygulamalar Mac'in kendiliğinden uyumasını engelliyor. Bu yüzden elma menüsünden **Uyut** ile uyutun.

Önce oturumda ajana kolay bir bilgi söyleyin: "Parola kelimem kervansaray, sadece aklında tut."

- [ ] Mac'i uyutun. Telefon bir dakika içinde "Uykuda ya da çevrimdışı" gösteriyor. Süre: ____
- [ ] Uykudayken mesaj yazın. Yazdığınız metin kaybolmuyor, nedeni görünüyor.
- [ ] Mac'i uyandırın. Node kendiliğinden bağlanıyor. Süre: ____
- [ ] "Parola kelimem neydi?" diye sorun. **Beklenen:** "kervansaray".
- [ ] "agent cannot resume sessions" hatası çıktıysa ajan adıyla birlikte yazın.
- [ ] Aynı denemeyi diğer ajanla (Qwen ve Goose ikisi de) yapın.
- [ ] Ajan çalışırken Mac'i uyutun. Uyanınca oturum takılı kalmıyor, yazarak devam edebiliyorsunuz.

## 4. Sunucu yeniden başlayınca

- [ ] Ajan çalışırken hub'ı yeniden başlatın. Bunu bana söyleyin ya da kendiniz çalıştırın:

```bash
ssh ubuntu@kervan-1.tail62192c.ts.net sudo systemctl restart kervan
```

- [ ] Telefon kendiliğinden yeniden bağlanıyor, geçmiş duruyor.
- [ ] Yazarak devam edince ajan önceki konuşmayı hatırlıyor.

Telefonda "Devam et" düğmesi yok, o yalnızca Mac uygulamasında. Telefonda gerekli olup olmadığını günlüğe yazın.

## 5. Mac yeniden başlayınca

**Muhtemelen tam geçmeyecek.** Sonucu görmek yine de değerli:

- FileVault açık, yani normal yeniden başlatmada Mac parola girilene kadar diskini açmaz ve node başlamaz. Tek seferlik atlamak için `fdesetup authrestart` gerekiyor. FileVault ayarına dokunmayın.
- Ollama, LM Studio ve Tailscale uygulaması şu an kullanıcı oturumunuzda çalışıyor. Kimse giriş yapmamışken Ollama büyük olasılıkla kapalı olur. Tailscale'in bağlanıp bağlanmayacağını bilmiyorum.

Deneme:

```bash
sudo fdesetup authrestart
```

- [ ] Giriş yapmadan bir iki dakika bekleyin. Telefonda node bağlı görünüyor mu? ____
- [ ] Bağlıysa telefondan mesaj gönderin. Model yanıt veriyor mu, hata ne diyor? ____
- [ ] Mac'e giriş yapın. Node bağlı, model yanıt veriyor.

## Geçme ölçütü

Deneme şu dördü tutarsa geçer:

1. Telefondan gerçek bir iş yerel modelle bitti ve sonuç işe yaradı.
2. Komut onayı ve dosya ekleme telefondan çalıştı.
3. Uyku sonrası oturum, önceki konuşmayı hatırlayarak devam etti.
4. Hub yeniden başlayınca hiçbir şey kaybolmadı.

5. bölüm ölçüte dahil değil. Kimse giriş yapmamışken çalışması sizin için gerekliyse aşağıda belirtin, ayrı bir iş olur.

## Benim yapacaklarım

Siz denemeyi bitirince, node 0.3.17'deyken:

- `/ecc:security-scan` ve son sızma testindeki saldırıları node mesajlarına karşı yeniden denemek (7. adımın gereği).
- Günlükteki her hata için önce onu yakalayan bir test, sonra düzeltme.

## Hata günlüğü

| Bölüm | Ne oldu | Ne bekliyordunuz | Ne kadar rahatsız etti (engel / can sıkıcı / önemsiz) |
|---|---|---|---|
| Başlamadan önce, 1 | Mac uyanınca node hub'a dönmüyor. Hub bağlantıyı kapatıyor, node ise soketini hâlâ açık sanıyor ve kalıcı olarak bağlantısız kalıyor (20:40 uyanışında doğrulandı). Node'un kendi canlılık denetimi yok. | Uyanınca kendiliğinden bağlanması | Engel |
| 1 | Node çevrimdışıyken katalogda **Nerede çalışsın** seçimi hiç görünmüyor, ajan sanki yalnızca sunucuya kurulabiliyor. | Node'un çevrimdışı olduğunu söyleyen bir seçim | Can sıkıcı |
| | | | |

Ekran görüntüsünü doğrudan sohbete atabilirsiniz, günlüğe ben işlerim.

## Son iki soru

- Yerel modele gerçekten hangi işleri vereceksiniz, hangileri yine Claude veya Codex'te kalacak? ____
- Mac kapalı kapakla veya kimse giriş yapmamışken de çalışmalı mı? ____
