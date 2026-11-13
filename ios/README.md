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
kare → Vision OCR (aynı satırdaki kutular soldan sağa tek satır, L01…) → Nemotron çıkarma (few-shot, json_schema)
     → kod kontrolü: ad/telefon/saat kendi satırında olmalı, items aynı satırda, en fazla 15 nesne
     → useful=false ise kare silinir; yoksa metin + görsel hafıza (nesne, konum ilişkisi, RESİM) + Nemotron 3.5 Embed
soru → Nemotron 3.5 Embed (~0,3 sn)
     → telefonda hibrit arama (1–20 ms): FTS5 bm25 + bellek içi vektör indeksi (Accelerate) + kısmi okuma + yenilik,
       RRF ile birleştirme → aynı tabelanın okumaları tek grup → Nemotron 3.5 Rerank 8B (ilk 20)
     → tek Nemotron çağrısı: dil, "az önce / burada / şu an neredeyim", "unut" isteği ve cevap (yalnız kayıtlardan)
     → kod kontrolü: her alıntı kayıtta, her sayı OCR'da; model "inferred" derse EMİN DEĞİLİM + gözlemler
```

- **Kodda dil ayrıştırma yok** (anahtar kelime listesi, "burada/az önce/unut" regex'i yok). Soruyu anlamak İngilizce sistem istemiyle modelin işi: `AI/MemoryAI.swift` (`answerSystem`), çıkarma: `AI/Extraction.swift`.
- Çıkarma istemi ve kontrolleri ekibin v7 istemlerinden (31/31). Alınmayanlar: ayrı soru ayrıştırma çağrısı (+5 sn), liste / "neredeyim" sorularının koda yönlendirilmesi ve insan sözcüğü listesi (vakaya özel kod), LOOK yeniden bakma (cevap başına 3'e kadar ek görsel çağrı).
- Her vektörün yanında model adı (`embed_model`) saklanır; model değişince eski satırlar arka planda yeniden gömülür.
- Anahtarlar yalnız Keychain'de: `nvidia-api-key` (sohbet), `embed-api-key`, `rerank-api-key` (boşsa gömme anahtarı). Geliştirici paneli > Nemotron.
- Test: `--embed=https://integrate.api.nvidia.com/v1|nvidia/nemotron-3.5-embed-1b|<anahtar> --rerank=nvidia/nemotron-3.5-rerank-8b|<anahtar> --mock-script=stop@0.3,asks@2 --asks=soru1||soru2` (sırayla sorar, iz `ask “…”` log satırında).

## Dosyalar

```
Muisti/
  MuistiApp.swift   RootView: Kayıt / Sor / Hafıza sekmeleri, Siri isteği → dinle
  Core/        CapturedFrame, CaptureSource, AppConfig, ImageData, ISO8601, Log
  Glasses/     WearablesController, GlassesCaptureSource (A, B, C, uyarlamalı), MockDeviceController, MockRuntime
  Phone/       PhoneCameraSource, LocationProvider (+ sokak adı)
  Adaptive/    MotionProvider, AdaptiveScheduler
  Perception/  PerceptionEngine (keskinlik, dHash + metin tekrarı, Vision OCR, yüz/plaka bulanıklaştırma, kayıt dışı bölge)
  Memory/      MemoryStore (SQLite + FTS5 + RRF), VectorIndex (Accelerate), MemoryPipeline, EnrichmentWorker, QueryEngine (gruplama + rerank)
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
