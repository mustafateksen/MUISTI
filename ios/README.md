# Muisti iOS: gözlük ve yakalama hattı (Kişi 1)

Meta Wearables DAT SDK **1.0.1** (SPM, exact). Xcode 26.4+, iOS 17.2+, Swift 6.
Hattın çıktısı tek şey: **kare akışı** (`CapturedFrame`). Eleme, OCR ve bulanıklaştırma Kişi 2'de; `/ingest` ve `/ask` sunucusu Kişi 3'te.

## Çalıştırma

1. `ios/Muisti.xcodeproj`'yi aç. Paket ilk açılışta iner.
2. Signing & Capabilities: kendi takımını seç, gerekirse bundle id'yi değiştir (`fi.junction.powerpuffboys.muisti`).
   Ücretsiz (kişisel) takım `HotspotConfiguration` / `wifi-info` yetkilerini vermeyebilir. İmzalama hata verirse bu ikisini `Config/Muisti.entitlements` dosyasından sil.
3. **Simülatör (gözlüksüz):** çalıştır → sol üstteki 🐞 → *Sahte gözlüğü aç* → *Kaydı başlat*.
   Tek adımda açmak için Scheme > Run > Arguments altına `--mock-autostart` ekle. İsteğe bağlı argümanlar:
   - `--mode=adaptive|stream|streamPlusPhoto|intervalPhoto`
   - `--server=http://127.0.0.1:8000`
   - `--mock-script=fold@8,unfold@14,don@16,doff@26,tap@30,battery5@34,hot@36,background@40`: bölüm 7'deki hata satırlarını zamanlı olarak tetikler.
4. **Sahte sunucu:** `python3 ios/tools/mock_server.py --port 8000 --out /tmp/muisti-ingest`. Uygulamada Ayarlar > Sunucu alanına `http://<Mac IP>:8000` yaz.
5. **Gerçek gözlük:** Meta AI'da geliştirici modu açık olmalı (yazılım güncellemesinden sonra kendiliğinden kapanır). Ana ekranda *Bağlan* → Meta AI → geri dönüş → *Kaydı başlat* → kamera izni.

Kayıtlar `Dosyalar > Bu iPhone'da > Muisti > sessions/<tarih>/` altında: `frames/*.jpg`, `meta.jsonl`, `gps.jsonl`. Buradan AirDrop ile Mac'e alınabilir.

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

## Diğer hatlarla sözleşme

```swift
// Kişi 2: algı hattını tak
await controller.setSink(MyPerceptionSink())   // FrameSink.process(_:) -> IngestPayload?
controller.requestFollowUp()                   // "yazı gördüm, bir daha bak" (uyarlamalı) / mod B'de yüksek çözünürlük
// Kişi 4: ses ve soru
try AudioSessionSetup.configureForVoice()
let answer = try await APIClient(baseURL: url).ask("…", lat: lat, lon: lon)
```

`IngestPayload` alan adları, plandaki `/ingest` sözleşmesiyle birebir aynıdır. Kişi 2 hazır olana kadar `PassthroughSink` kullanılır: tekil kareler her zaman, akış kareleri her N.'si geçer.

## Dosyalar

```
Muisti/
  MuistiApp.swift                 Wearables.configure(), onOpenURL (yalnızca metaWearablesAction)
  Core/        CapturedFrame, CaptureSource (protokol + durum), AppConfig, ImageData, Log, AudioSessionSetup
  Glasses/     WearablesController (kayıt/izin/güncelleme), GlassesCaptureSource (oturum/kamera/akış/fotoğraf; A, B, C ve uyarlamalı),
               MockDeviceController (#if DEBUG), MockRuntime
  Phone/       PhoneCameraSource (yedek kaynak), LocationProvider
  Adaptive/    MotionProvider (CoreMotion etkinlik, adım sayar, ivme), AdaptiveScheduler
  Pipeline/    CaptureController (orkestra), FrameSink + PassthroughSink, SessionRecorder, UploadQueue
  Net/         APIClient (/ingest, /ask)
  UI/          HomeView, PreviewView, StatusBanner, SettingsView, DebugMenu (#if DEBUG)
  Resources/   demo_signs.mp4 (h.265, tabelalar), demo_sign.jpg: sahte gözlük beslemesi; yerelde üretildi
tools/mock_server.py              /ingest + /ask sahte sunucusu (yalnızca standart kütüphane)
```

Brifingdeki `GlassesPhotoSource` ayrı bir dosya olarak yazılmadı; bu mod `GlassesCaptureSource` içinde. Akış ile fotoğraf aynı sensörü ve aynı oturumu paylaştığı için tek sahip daha güvenli.

## Simülatörde (sahte gözlük) doğrulananlar

| Senaryo | Sonuç |
|---|---|
| Uyarlamalı: uyandırma akışı → fotoğraf `started` → akış kapanır → kareler | ✅ 720×1280, aktarım 5–600 ms (sahte) |
| Simüle yürüyüş (1,4 m/sn): ~11 m'de bir kare, konumlu | ✅ |
| Akış A, 7 kare/sn, her 5. kare `/ingest`'e | ✅ (~1,3 kare/sn) |
| Sunucu yokken kuyruk diske birikir, uygulama yeniden açılınca boşalır | ✅ |
| Menteşe kapanır → oturum `stopped` → açılıp takılınca yeni oturum kendiliğinden | ✅ |
| Gözlük çıkarılınca kare alınmaz, takılınca devam eder | ✅ |
| Sapa dokunma → "devam için sapına dokun", son kare ekranda; ikinci dokunuş sürdürür | ✅ |
| Pil %5 / ısınma → uyarı + mod önerisi | ✅ |
| Arka plana geçiş → oturum bilinçli kapanır, "Devam et" | ✅ (bildirimle tetiklendi) |

Sahte cihazla ilgili not: menteşe açılsa bile gözlük **takılana kadar** oturum "Device unavailable" ile reddediliyor. Gerçek gözlükte bunu doğrulamak gerekiyor.

## Doğrulanmayanlar (gerçek gözlük penceresinde)

- `camera.photo` `.full` boyutu ve Bluetooth aktarım süresi (BirdSpotter: ~1 sn, bazen 9 sn). Varsayılan `.full` + `.medium` kalite. Yavaşsa Ayarlar'dan `.large`'a düşür.
- `stream.capturePhoto` (mod B) görüntüsünün çözünürlüğü.
- 10 dakikada pil tüketimi: uyarlamalı, A (2 ve 24 kare/sn) ve C ayrı ayrı ölçülmeli. Uyarlamalı modun asıl iddiası bu.
- `external-accessory` / `UISupportedExternalAccessoryProtocols` Gen 2 için gerekli mi? (Kılavuz istiyor, CameraAccess örneğinde yok; ikisi de eklendi.)
- Kayıt sırasında ekran kilitlenmesin diye `isIdleTimerDisabled` açık; arka plana geçince gözlük oturumu kapanıyor.
- Telefon cepteyken gövde yönü (yaw) dönüş algılamasında ne kadar işe yarıyor?
