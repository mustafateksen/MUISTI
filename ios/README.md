# Muisti iOS

Gözlük + telefon, **sunucusuz**. Depolama, OCR, bulanıklaştırma, hafıza ve sorgu telefonda çalışıyor; Nemotron 3.5 Super VL doğrudan telefondan API ile çağrılıyor.

```
Kare → eleme (keskinlik, tekrar, kayıt dışı bölge) → Apple Vision OCR → yüz + plaka bulanıklaştırma
     → SQLite (FTS5) + bulanık küçük kare   [Application Support/memory, dosya koruması açık]
     → arka planda Nemotron: yapılandırılmış kayıt {kind, name, phone, hours, …} + kanıt kuralı
Ses  → "Sor" düğmesi / "Hey Siri, Muisti'ye sor" → gözlük mikrofonu (HFP) → cihaz üstü konuşma tanıma
     → Nemotron soru planı → yerel arama → kanıttan cevap → kanıt kuralı → gözlük hoparlörü (A2DP)
```

**Kanıt kuralı:** cevaptaki her telefon, saat ve fiyat, karede okunan metinde birebir geçmek zorunda; geçmiyorsa cevap "net görmedim"e çevrilir. Kayıt yoksa "Bunu görmedim." İnternet yoksa yerel aramayla cevap verilir.

## Çalıştırma

1. `ios/Muisti.xcodeproj`'yi aç, Signing'de takımını seç.
2. **Ayarlar > Nemotron:** "Hazır sağlayıcı seç > Verda (Junction)" ve API anahtarı. Anahtar Keychain'de durur, koda yazılmaz.
3. **Simülatör:** 🐞 → Sahte gözlüğü aç → Kaydı başlat. Ya da argümanlar: `--mock-autostart --mode=stream`.
4. **Gerçek gözlük:** Meta AI'da geliştirici modu → Bağlan → Kaydı başlat.
5. **Sor sekmesi:** mikrofona dokun ve sor. Eller serbest kullanım için "Hey Siri, Muisti'ye sor" ya da Eylem Düğmesi → Kestirme → "Muisti'ye sor".

DEBUG argümanları:
- `--autostart` / `--mock-autostart`
- `--mode=…`, `--source=phone`
- `--nemotron-key=…`: test cihazının Keychain'ine yazar
- `--script=capture@6,highres@10,ask@20,listen@25,stop@30` ve `--ask="soru"`
- `--mock-script=fold@8,unfold@12,don@14,tap@20,battery5@24,hot@26,background@30`

## Uçtan uca testler (simülatör, donanım gerekmez)

```
xcrun simctl privacy booted reset all fi.junction.powerpuffboys.muisti   # izin akışlarını da sına
xcodebuild test -project ios/Muisti.xcodeproj -scheme Muisti -destination 'platform=iOS Simulator,name=iPhone 17'
```

`MuistiUITests/MuistiCrashTests.swift`, sahte gözlükle 4 senaryo:
- Sesli soru düğmesi + izin uyarıları (sahadaki çökme)
- Kayıt sırasında dokunma, menteşe, takma, pil ve ısı olayları + sekme geçişleri (önizleme kutusu sabit 320 pt mi, kare gelince düzen kayıyor mu, ekranda ham SDK metni var mı)
- Arka plana atıp geri dönme
- Yazılı soru + hafıza listesi

## Yakalama modları

| Mod | Gözlükte ne çalışır | Ne zaman |
|---|---|---|
| **Uyarlamalı** (varsayılan) | Sürekli video yok. Kamera yalnızca fotoğraf yeteneğiyle bekler; kareyi zamanlayıcı ister | Günlük kullanım, pil |
| A · Düşük hızlı akış | `.raw` akış, 2/7 kare/sn, istemci tarafında hız sınırı | Okunabilirlik karşılaştırması |
| B · Akış + fotoğraf | A + `stream.capturePhoto` (Kişi 2 `requestFollowUp()` çağırınca) | Yazı görülünce yüksek çözünürlük |
| C · Aralıklı fotoğraf | N saniyede bir fotoğraf | Pil ölçümünde karşılaştırma için taban |

**Uyarlamalı zamanlayıcı** (`Adaptive/AdaptiveScheduler.swift`, saf mantık) telefonun sensörlerine bakar:

- **Mesafe:** yürürken yaklaşık 10 m'de bir kare. Açık havada GPS, içeride adım sayar kullanılır. Bisiklette veya araçta yaklaşık 30 m'de bir.
- **Durup bakma:** yürüyen kişi ~1,5 sn durunca tek kare alınır (tabelaya ya da stanta bakıyordur).
- **Dönüş:** GPS rotası ya da gövde yönü ~35° değişince kare alınır.
- **Tavanlar:** en kısa aralık 3 sn, dakikada en fazla 15 kare. Dururken birkaç seyrek yenilemeden sonra kare alınmaz.
- **Pil ve ısı:** telefon pili %20'nin altında ya da düşük güç modu açıksa ×1,5; gözlük pili %20'nin altındaysa ×2, %10'un altındaysa ×3; ısınma varsa ×2. Bu çarpanlar aralıkları ve mesafeleri uzatır. Kritik ısıda çekim durur. Gözlük takılı değilken kare alınmaz.
- **Bulanıklık kapısı:** kare zamanı gelince en fazla ~1,2 sn, ivme ve dönüş sakinleşene kadar beklenir (adımların arasındaki an).
- Hareket verisi yoksa (ör. simülatör) basit zamanlayıcıya düşer (8 sn).

Bütün eşikler Ayarlar > Uyarlamalı mod altında değiştirilebilir.

Gözlük tarafında fotoğraf yeteneğini açmak için önce kısa bir akış başlatılır (`Photo.start()` soğuk kamerada `starting`'de takılı kalır). Fotoğraf yeteneği `started` olunca akış durdurulur.

## Nemotron

| | |
|---|---|
| Verda (varsayılan) | `https://containers.datacrunch.io/nemotron-3-5-super-vl-b300/v1`, model `nemotron-3.5-super-vl`. Gömme yok → anahtar kelime (FTS5) + kısmi kelime araması |
| NVIDIA build | `https://integrate.api.nvidia.com/v1`, `nvidia/nemotron-3.5-super-vl-120b-a12b` + `nvidia/nemotron-3.5-embed-1b` (gömme ile anlam araması) |
| Ölçüm (Verda) | Görselli çıkarma ~0,85 sn; soru → cevap ~1,8 sn (plan + cevap, 2 çağrı) |
| Kare başına | 1 çağrı (yalnız tutulan kareler: yazılı ya da dakikada 1 sahne) |

İstemler `AI/MemoryAI.swift` içinde (Nemotron teslim metni için oradan alınabilir).

### Telefonda RAG (Emir'in sunucusu yok, her şey uygulamada)

```
kare → Vision OCR (aynı satırdaki kutular soldan sağa tek satır, L01…) ‖ baş tespiti (paralel)
     → baş/plaka maskesi (yüz + vücut duruşu + üst gövde, 2×2 parça; pikselleştir+bulanıklaştır; tespit hata verirse kare atılır)
     → anı bölümü (zaman ≤10 dk ve konum ≤300 m ile bir önceki bölüme eklenir; yoksa yeni bölüm)
     → Nemotron çıkarma (json_schema, few-shot yok): metin alanları kendi OCR satırından kontrol edilir,
       8-15 nesne, ilişkiler, RESİM (gerçek değil) ayrımı; useful=false → kare silinir; bozuk JSON → bir kez temperature 0
     → Nemotron 3.5 Embed; bölüm oturunca Nemotron başlık + özet yazar
soru → Nemotron 3.5 Embed (~0,3 sn) → telefonda hibrit arama (FTS5 + bellek içi vektör + kısmi okuma + yenilik, RRF)
     → aynı tabelanın okumaları tek grup → Nemotron 3.5 Rerank 8B
     → tek Nemotron çağrısı: soru dili (Apple NaturalLanguage), en yeni kareler, ilgili kayıtlar ve bölümleri (kare sırası,
       minutes_ago) → cevap / "unut" isteği; Verda 12 sn'de cevap vermezse aynı model NVIDIA build'den
     → kod kontrolü: her alıntı kayıtta, her sayı OCR'da; tutmazsa bir düzeltme turu; "inferred" → EMİN DEĞİLİM
```

- **Kodda dil ayrıştırma yok** (anahtar kelime listesi, regex yok). Soruyu anlamak İngilizce sistem istemiyle modelin işi: `AI/MemoryAI.swift` (`answerSystem`), çıkarma: `AI/Extraction.swift`.
- Ekibin v12 istemlerinden alınanlar: OCR satır kimlikleri ve satır kontrolü, nesne grupları ve tanımları, resim/gerçek ayrımı, stated/inferred, alıntılar, max_tokens 2500, 1536 px. Alınmayanlar: few-shot örnekleri (örnek içeriği kopyalandı), ayrı soru ayrıştırma çağrısı (+5 sn), anahtar kelimeli nesne temizliği ve listelerin koda yönlendirilmesi (vakaya özel kod), LOOK yeniden bakma.
- Soru dili İngilizceye kilitli (`en-US`, telefon dilinden bağımsız). Cevap sorunun dilinde.
- Soru gelince arka plandaki çıkarma isteği iptal edilir (sayılmaz, sonra tekrar), soru önce cevaplanır.
- Anahtarlar yalnız Keychain'de: `nvidia-api-key` (sohbet), `embed-api-key`, `rerank-api-key` (boşsa gömme anahtarı; NVIDIA yedek sohbet de bunu kullanır).
- Örnek veri: Geliştirici > "Hafızayı silip örnek fotoğrafları yükle" (`Documents/ingest/manifest.json`), ya da `--script-only=wipe@0,ingest@1 --ingest=ingest`. Telefona: `devicectl device copy to … --destination Documents/ingest`.
- Test: `--ask-only --asks=soru1||soru2` (son istem `Documents/last_prompt.txt`, DEBUG).

### Ölçüm (simülatör, 73 fotoğraf / 79 soru)

`Pipeline/EvalRunner.swift` (DEBUG): `--script-only=wipe@0,ingest@1,waitidle@2,eval@3 --ingest=ingest2 --eval=ingest2`.
`Documents/ingest2/eval.json`: `{"q", "expect": [foto], "must": [biri] | null}`; sonuç `eval_result.json` + `eval_summary.txt`.
Veri: 7 bölümde 73 açık lisanslı fotoğraf (benzer çeldiriciler: 3 fırın, 3 eczane, 3 tramvay, 3 müze, 3 tuvalet…), sorular: metin, nesne, ilişki/sıra, yenilik, Türkçe, görülmeyenler.

| Koşu | Değişiklik | Doğru cevap (çekirdek 53) | Görülmedi (7) | r@1 | p50 |
|---|---|---|---|---|---|
| 1 | başlangıç | 46 | 7 | 46 | 1,8 sn |
| 2 | tarih sayıları + alıntı kapsamı + 8B gömme | 47 | 6 | 45 | 3,7 sn (8B sorgu vektörü zaman aşımı) |
| 3 | 1B gömmeye dönüş | 49 | 6 | 47 | 2,1 sn |
| 4 | alıntı %80 kelime, 800 token, `found` alanı | 50 | 7 | 47 | 1,7 sn |
| 6 | reranker skoruyla ikinci bakış (≥ −2,8) | **52** | **7** | 47 | 2,0 sn |

- `nemotron-3.5-embed-8b` (4096-d) hesapta var ama sorgu anında 5+ sn / zaman aşımı → 1B kaldı.
- İkinci bakış eşiği ölçümden: görülmeyen şey sorularında en iyi skor ≤ −2,94, yanlış reddedilen cevaplarda −2,04…−2,71.

### Gözlükten aktarım hızı
- 12 MP fotoğraf Bluetooth'tan 10–14 sn, Wi-Fi'dan ~1 sn. SDK Wi-Fi yolu için Info.plist (`NSLocalNetworkUsageDescription`, `NSBonjourServices`) ve yerel ağ izni ister: açılışta Bonjour taramasıyla izin kontrol edilir, reddedildiyse uyarı gösterilir; aktarım hızı ölçülür, iki kez < 400 KB/s ise "Bluetooth'tan yavaş geliyor" uyarısı.
- Kayıt sürerken soru telefon mikrofonundan dinlenir (gözlük mikrofonu HFP, kamera bağlantısıyla aynı radyoyu paylaşır); cevap yine gözlükten (A2DP).
- Fotoğrafın zamanı istendiği an (geldiği an değil), GPS o ana göre eşlenir.

### Arka planda kayıt

Meta SDK `.hvc1` (HEVC) akışını arka planda sürdürür (`.raw` durur; CHANGELOG 0.5.0). Arka planda iOS GPU/donanım çözücü vermediği için:
- Uygulama arka plana geçince gözlük kamerası 720p, 2 fps HEVC akışa geçer; sıkıştırılmış kareler çözülmeden dosyaya yazılır (`Glasses/BackgroundSegmentRecorder.swift`). GPS ("location" arka plan modu, mavi gösterge) uygulamayı canlı tutar ve konum geçmişi tutulur.
- Öne gelince dosyadan ~2,5 sn'de bir kare alınır, gerçek zamanı ve en yakın GPS'iyle normal hattan geçer (OCR, maskeleme, tekrar, bölümler, Nemotron); dosya silinir. Fotoğraf modu kendiliğinden geri gelir.
- Simülatörde (sahte gözlük) doğrulandı: 25 sn arka plan → 10 kare → 2 yeni anı. **Gerçek gözlükte denenmedi.** Kapatmak: Geliştirici > "Arka planda da kaydet".

## Gözlük bağlantısı: Wi-Fi

- SDK aktarım yolunu Info.plist'ten seçiyor: `UISupportedExternalAccessoryProtocols` (`com.meta.ar.wearable`) ve `external-accessory` arka plan modu varsa **yalnızca Bluetooth Classic** kullanıyor, Wi-Fi'a hiç geçmiyor (Meta, GitHub #356). Bu iki girdi kaldırıldı; Wi-Fi girdileri (`NSLocalNetworkUsageDescription`, `NSBonjourServices` `_bonjour._tcp`), Bluetooth LE girdileri ve Hotspot Configuration / Wi-Fi Info yetkileri duruyor.
- Akış başlayınca iOS "Wi-Fi ağına katıl" diye sorar (gözlüğün kendi ağı); "Katıl". Bu ağda internet yok: Nemotron çağrıları hücreselden gider, uygulamaya hücresel veri izni verin.
- Wi-Fi'da akış 720p, 7 kare/sn; ölçülen kare sıklığı yürürken ~1–1,5 sn'de bir (14 Kasım). Classic'te ses de akarken görüntü 360×640'a düşüyordu.
- Bilinen sorun: Ray-Ban Gen 2, yazılım 129.x'te bazı cihazlarda katılım başarısız ("Unable to join the network", #354). Olursa iki Classic girdisini geri koyun.

## Konuşma: dokun, sor, devam et

- **Yandan dokunma = soru sor** (gözlük dokunmatik yüzeyi, `MWDATInputs` `select(captouch)`). Gözlük dokunmaları 0,9–2 sn arayla bildirdiği için ilk dokunma tetikler, sonraki 2,5 sn'dekiler aynı hareket sayılır. Çekim butonu Meta'da kalır (kısa basış = foto; Muisti o anı da hafızaya ekler).
- **Sesler:** dinleme başlarken `listen_start` (ekibin `ilk.wav`'ı), dinleme bitince `listen_end` (`son.wav`), sessizlikleri kesilmiş.
- **Devam eden sohbet:** sesli sorulan her cevaptan sonra mikrofon kendiliğinden açılır; ~6 sn sessizlik kapatır. Muisti uygun olduğunda topu geri atar ("Telefon numarasını da ister misin?"). Her cevap için yeni ses motoru (ikinci cevabın sessiz kalması buydu).
- Sürekli dinleme ("Hey Muisti", `GlassesSpeech` / `GlassesAudioRecognizer`) kodda duruyor ama varsayılan kapalı (Ayarlar › Voice): Classic'te ses akışı görüntüyü düşürüyordu ve çift tetikleniyordu.

## Anlık görüntü aracı (look_now) ve yönlendirici

- **Yönlendirici:** her soruda hafıza aramasıyla paralel küçük bir Nemotron çağrısı (`RoutePrompts`) yalnızca şunu seçer: `look` / `memory` / `chat` / `other`. Uzun cevap isteminde hafıza kayıtları modeli "hafızadan cevapla"ya çekiyordu; kısa istem bu kararda çok daha kararlı.
- `look` → uygulama gözlükten en yeni kareyi alır (son 3 sn; yoksa 2 dk içindeki en yeni hafıza karesi, yaşıyla), yüzleri maskeler, telefonda OCR yapar ve cevap çağrısına yalnızca o kareyi verir. Cevap çağrısının kendi `look_now` aksiyonu ve `question_is_about_what_user_sees_now` alanı yedek tetik.
- **Takip soruları:** bakıştan sonraki 90 sn içinde aynı kare görünür kalır ("tabelada tam ne yazıyor?", "süt var mı?", "açık mı?"); "tekrar bak" taze kare alır.
- Ekranda/TV'de/afişte görünen şey gerçek değildir (TV'deki alev = ocak açık değil). Canlı görüntüye dayanan cevapta kanıt olarak o kare gösterilir ("Live view").
- **Sohbet:** selam, teşekkür, tepkiler ("ok, güzel") ve genel sorular `chat`: kısa doğal cevap, rozet ve kanıt yok. Kısa Türkçe ifadelerde dil tespiti güvenilmez olduğundan konuşmanın dili kullanılır.
- **Ölçüm** (`ConversationEval`, `--script-only=conveval@0 --conv=<klasör>`; 15 konuşma, 29 tur, anlık görüntü test fotoğraflarıyla): ilk tur 16/22 → yönlendirici ve taşınan kareyle 29/29.

## Muisti Turva (kişisel güvenlik kuralları)

Kullanıcı kuralını sesle koyar, Muisti gördüğüne göre uyarır. Uyarı her zaman gördüğünü ve saatini söyler ("Ocağı en son 18:42'de açık gördüm, kapattığını görmedim"), kanıt karesi telefonda.

- **Kural oluşturma:** "Evden çıkarken ocak açıksa uyar", "Enalapril'i her sabah 8'de hatırlat", "Ürünlerde süt varsa uyar". Cevap çağrısı (`AnswerDraft.action = create_rule`) kuralı JSON'a çevirir, Muisti okuyup "doğru mu?" diye sorar, "evet" ile kaydedilir. Silme, "ilacımı aldım" / "ocağı kapattım" (kaynak: kullanıcının sözü), "çıkıyorum", "burası evim", "şimdi değil" (30 dk erteleme) de aynı çağrıda.
- **Kare okuma** (`SafetyPrompts.observe…`): yalnızca kurallarda izlenen nesneler sorulur (ocak, anahtar, `medication:<ad>`, alerjenler). Ocakta görünür ısı işareti yoksa "unknown", TV/posterdeki nesne görünmez sayılır, saat göstergesi ısı işareti değildir. Yüzler ve plakalar telefonda maskelenir, gönderilen ve saklanan kare budur.
- **Yerel kapılar:** evde eller görünürken 5 sn'de bir, değilse 30 sn'de bir; etiket kuralı varsa çok yazılı karelerde 8 sn'de bir; en çok dakikada 20 çağrı. El tespiti (Vision) ucuz, OCR + maskeleme yalnızca sırası gelen karede.
- **Durum makinesi** (`SafetyMonitor`): "açık" demek için iki ardışık okuma, "kapalı" için bir okuma yeter; 12 saat görülmeyen "açık" bilinmiyora döner.
- **Tetikler:** evden çıkış (sesli "çıkıyorum", konumun ev dairesinden çıkması, kamerada iç mekândan dışarıya geçiş), saat (uygulama içinde 30 sn'de bir + kapalıyken yerel bildirim), olay (ilaç kutusu elde, ürün etiketi), hareketsizlik (ocak açık, 20 dk mutfağa bakılmadı).
- **İlaç:** kutu saatinde elde görülürse Muisti "aldın mı?" diye sorar ve mikrofonu açar. Alım yalnızca kullanıcı onaylarsa sayılır. Aynı gün ikinci kez elde görülürse yalnızca kaydı söyler; doz tavsiyesi vermez.
- **Soru-cevap:** "Ocağı kapattım mı?", "Bugün ilacımı aldım mı?", "Hangi kurallarım var?" sorularında kurallar, son durumlar ve 24 saatlik log cevap çağrısına kanıt olarak gider. Cevapta saatler bu logdan, kare gösterilir.
- **Saklama:** `memory/safety.sqlite` (kurallar, olaylar, durumlar, uyarılar) + `memory/safety_frames/`, aynı dosya koruması. Olaylar 30 gün, kareler 7 gün; "son N dakikayı unut" bu tabloları da siler. Sunucuya bir şey gitmez.
- **Arayüz:** "Safety" sekmesi: bekleyen evet/hayır, uyarılar (kare + OK/Later), son görülen durumlar ("senin sözün" ayrımıyla), kurallar (aç/kapat, sil), "burası evim".

**Ölçüm (simülatör, 14 Kasım):** `SafetyEval`, `--script-only=safetyeval@0 --safety=<klasör>`:
- A. Plandaki senaryolar gerçek `SafetyMonitor` ile (ağ yok): 12/12 (ocak açık + çıkış, tek okuma yetmez, açık-kapalı, hiç görülmedi, "kapattım", ilaç hatırlatma + tekrar yok, onay sorusu + ikinci doz, anahtar masada, TV tuzağı, 20 dk hareketsizlik).
- B. Kare modeli, 27 açık lisanslı foto (Openverse) + sentetik TV tuzağı: ocak 19/20 (yanlış "açık" 1: fırın saat göstergesi; istem düzeltildi, yeniden ölçülecek), kaçırılan açık 0, TV tuzağı doğru, dış mekân 2/2, etiket alerjenleri 2/2, kare başına p50 ~1,6 sn.
- C. Sesli konuşma (kural oluştur → evet → durum sor → çıkıyorum → kapattım → ilaç → kuralları listele → sil): son turda kalan hatalar istemle düzeltildi; telefona kurulumdan sonra yeniden ölçülecek.

Sınırlar: ocak bekçisi ya da duman dedektörünün yerine geçmez; kamera bakmıyorsa olay yoktur; tıbbi cihaz değildir. Coğrafi sınır `CLMonitor` yerine kayıt sırasında gelen konumla hesaplanıyor (kayıt kapalıyken çıkış yalnızca sesle ya da kamerayla anlaşılır).

## Dosyalar

```
Muisti/
  MuistiApp.swift   RootView: Kayıt / Sor / Hafıza sekmeleri, Siri isteği → dinle
  Core/        CapturedFrame, CaptureSource, AppConfig, ImageData, ISO8601, Log
  Glasses/     WearablesController, GlassesCaptureSource (A, B, C, uyarlamalı), MockDeviceController, MockRuntime
  Phone/       PhoneCameraSource, LocationProvider (+ sokak adı)
  Adaptive/    MotionProvider, AdaptiveScheduler
  Perception/  PerceptionEngine (keskinlik, dHash + metin tekrarı, Vision OCR satırları, kayıt dışı bölge), HeadBlur (baş/plaka maskesi)
  Memory/      MemoryStore (SQLite + FTS5 + RRF + anı bölümleri), VectorIndex (Accelerate), MemoryPipeline, EnrichmentWorker, QueryEngine (gruplama + rerank + bölüm bağlamı)
  AI/          NemotronClient (OpenAI uyumlu), MemoryAI (istemler + kanıt kuralı), KeychainStore
  Voice/       VoiceAssistant (dinle → sor → oku), AskIntent (Siri / Eylem Düğmesi)
  Pipeline/    CaptureController, SessionRecorder (isteğe bağlı ham veri seti)
  UI/          HomeView, AskView, MemoryListView, PreviewView, StatusBanner, SettingsView, DebugMenu
```

## Simülatörde (sahte gözlük) doğrulananlar

| Senaryo | Sonuç |
|---|---|
| Uyarlamalı: uyandırma akışı → fotoğraf `started` → akış kapanır → kareler | ✅ 720×1280, aktarım 5–600 ms (sahte) |
| Simüle yürüyüş (1,4 m/sn): ~11 m'de bir kare, konumlu | ✅ |
| Akış A, 7 kare/sn, her 5. kare algı hattına | ✅ |
| İnternet/anahtar yokken kareler telefonda bekler, gelince Nemotron'a işlenir | ✅ |
| Menteşe kapanır → oturum `stopped` → açılıp takılınca yeni oturum kendiliğinden | ✅ |
| Gözlük çıkarılınca kare alınmaz, takılınca devam eder | ✅ |
| Sapa dokunma → "devam için sapına dokun", son kare ekranda; ikinci dokunuş sürdürür | ✅ |
| Pil %5 / ısınma → uyarı + mod önerisi | ✅ |
| Arka plana geçiş → oturum bilinçli kapanır, "Devam et" | ✅ (bildirimle tetiklendi) |
| Tabela videosu → 4 tabela = 4 kayıt (tekrar/yarım okuma elendi), Nemotron ile zenginleşti | ✅ |
| "Dişçinin numarası?" → "+358 9 4321 7788"; "Pizzacının telefonu?" → BİLMİYORUM | ✅ |
| Kanıt kuralı: OCR'da olmayan saat/numara cevaptan atılır (10 birim test) | ✅ |
| Yüz bulanıklaştırma (gerçek gözlük karesi), 12 MP kare işleme ~220 ms | ✅ |

Sahte cihazla ilgili not: menteşe açılsa bile gözlük **takılana kadar** oturum "Device unavailable" ile reddediliyor. Gerçek gözlükte bunu doğrulamak gerekiyor.

## Gerçek gözlükte ölçülenler (Ray-Ban Meta Gen 2, 13 Kasım)

| Konu | Sonuç |
|---|---|
| `camera.photo` `.full` | **4032×3024 (12 MP)**, 1,7–1,9 MB, aktarım **2–15 sn** (ilk kare en yavaş) |
| Fotoğraf yönü | Sensör sırasıyla geliyor, EXIF'te yön yok → 90° saat yönü pikselde çevriliyor (Ayarlar'dan değişir; sahte gözlükte 0°) |
| Akış sonrası çekim | Akış durdurulduktan hemen sonra istenen fotoğraf "Capture failed" → fotoğraf `started` olduktan sonra 1 sn bekleniyor |
| Akış (mod A) `.high` 7 kare/sn | 720×1280, dik, ~4,4 kare/sn kaydedildi |
| Akış içi fotoğraf (mod B) | **1080×1440**, ~4 sn |
| Telefon kamerası | Akış 720×1280; yüksek çözünürlük 2376×4224 |
| Nemotron'a giden kare | Bulanık anahtar kare, uzun kenar 1280 px (~150–300 KB) |

Telefonla hata ayıklama (DEBUG): `xcrun devicectl device process launch --device <UDID> --console --environment-variables '{"OS_ACTIVITY_DT_MODE":"enable"}' fi.junction.powerpuffboys.muisti --autostart [--mode=…] [--source=phone] [--script=capture@6,highres@10,stop@30,start@33]`

## Doğrulanmayanlar (gerçek gözlük penceresinde)

- `.large` boyutu ve aktarım süresi (`.full` 2–15 sn; daha sık kare gerekirse karşılaştır).
- Yürürken uyarlamalı modun gerçek kare sıklığı (masa başında "duruyor" olduğu için 45 sn'de bir yeniler).
- Menteşe kapat/aç ve gözlüğü çıkar/tak gerçek gözlükte (sahte cihazda doğrulandı).
- 10 dakikada pil tüketimi: uyarlamalı, A (2 ve 24 kare/sn) ve C ayrı ayrı ölçülmeli. Uyarlamalı modun asıl iddiası bu.
- `external-accessory` / `UISupportedExternalAccessoryProtocols` Gen 2 için gerekli mi? (Kılavuz istiyor, CameraAccess örneğinde yok; ikisi de eklendi.)
- Kayıt sırasında ekran kilitlenmesin diye `isIdleTimerDisabled` açık; arka plana geçince gözlük oturumu kapanıyor.
- Telefon cepteyken gövde yönü (yaw) dönüş algılamasında ne kadar işe yarıyor?
