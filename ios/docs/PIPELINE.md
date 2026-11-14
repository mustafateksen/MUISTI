# MUISTI pipeline (koddan çıkarılmış harita)

Son güncelleme: 14 Kasım 2026. Yollar `ios/Muisti/` altına göredir. Sabitler koddan okunmuştur; "ölçüm" yazan yerler gerçekten ölçülmüştür, geri kalanı koddan hesaplanan sürelerdir.

İki hat var:

1. **Kare hattı**: gözlük → kare seçimi → telefonda algı → kayıt → Nemotron ile zenginleştirme → güvenlik kuralları → sesli uyarı.
2. **Soru hattı**: dokunuş → dinleme → arama → cevap → doğrulama → konuşma.

```
KARE HATTI
gözlük akışı (hvc1 7 fps Wi-Fi / raw 2 fps BT)
   └─ HEVCFrameDecoder (en yeni kare)
        └─ AdaptiveScheduler (0,5 s'de bir karar; yürürken ≤1,5 s'de bir kare)
             └─ blur kapısı (≤1,2 s sabit an bekler)
                  └─ ingest ──────────────────────────────┬─ SafetyMonitor.consider (durum kuralları, tehlikeler)
                       └─ PerceptionEngine (telefonda)     │      └─ Nemotron "observe" → 2 okuma → uyarı
                            netlik → dHash → OCR+zoom ∥ kafa tespiti → tekrar eleme → maskeli kare
                            └─ MemoryStore.insert (FTS'te hemen aranır)
                                 ├─ checkText (OCR metni → kural eşleşmesi → uyarı)   ← en hızlı uyarı yolu
                                 └─ EnrichmentWorker (en yeni kare önce)
                                      Nemotron çıkarım → doğrulama → embed → vektör araması açık
                                      └─ checkEnriched (rerank + kosinüs → doğrudan uyarı ya da kısa metin kontrolü)

SORU HATTI
dokunuş → ton → mikrofon (gözlük akışındaki ses ya da HFP)
   └─ SFSpeechRecognizer (cihazda, kısmi sonuçlar)
        ├─ 0,45 s duraklama → QueryEngine.prepare: tur kararı (tool calling) ∥ (embed → arama → rerank)   [yan etkisiz]
        └─ 1,2 s sessizlik → soru bitti
             └─ QueryEngine.ask
                  karar: say → doğrudan cevap | look_now → canlı kare | search_memory → aşağısı | komut araçları → çalıştır
                  → bağlam (kayıtlar, bölümler, 2×2 kare montajı)
                  → cevap çağrısı (iki uç yarışır) → [onarım] → [ikinci bakış] → [görsel yeniden kontrol]
                  → kanıt kontrolü (yerel) → konuşma (AVSpeechSynthesizer)
                       └─ bekleyen uyarılar söylenir → gerekiyorsa mikrofon yeniden açılır
```

## 1. Kare hattı

| # | Aşama | Kod | Ne yapar | Sabitler |
|---|---|---|---|---|
| 0 | Akış | `Glasses/GlassesCaptureSource.swift` (`attachCameraIfNeeded`) | Wi-Fi'de `.hvc1` 720×1280 7 fps, Bluetooth'ta `.raw` 2 fps; ses isteğe bağlı 16 kHz mono | hvc1 8 s çözülmezse raw'a döner; akış 25 s başlamazsa yeniden; yeniden bağlanma 1-2-4-8-16-30 s |
| 0b | Çözme | `Glasses/HEVCFrameDecoder.swift` | VideoToolbox, yalnız en yeni kare tutulur; arka planda CPU JPEG | — |
| 1 | Zamanlayıcı | `Pipeline/CaptureController.swift` (`tick`), `Adaptive/AdaptiveScheduler.swift` | 0,5 s'de bir karar | en hızlı 1 s; yürürken 8 m ya da 1,5 s; dururken 3 s; baş dönüşü 25° + 0,6 s durulma; dakikada en fazla 60 |
| 2 | Blur kapısı | `CaptureController.waitForSteadyMoment` | Sabit an bekler (80 ms'de bir bakar) | en fazla 1,2 s |
| 3 | Kare alma | `GlassesCaptureSource.captureStill` | Planlı kare: 1 s'den genç çözülmüş kare, en fazla 2 s bekler; JPEG 0,9 | foto modunda zaman aşımı 25 s |
| 4 | `ingest` | `CaptureController.ingest` | GPS ekler, önizleme, hatta koyar (tampon: en yeni 6), `safety.consider` | — |
| 5 | Algı | `Perception/PerceptionEngine.swift:74` | netlik (Laplacian <60 at) → dHash → **OCR ∥ kafa tespiti** → tekrar eleme → 1536 px maskeli kare (JPEG 0,78) | OCR `.accurate`, dil düzeltme kapalı; zoom: en fazla 8 blok, **paralel** okunur; yazısız kare 60 s'de bir |
| 6 | Kayıt | `Memory/MemoryStore.insert` | Kare dosyası + satır (`status = 0`) + FTS5 + bölüm atama | bölüm: 10 dk / 300 m. **Kare bu andan itibaren anahtar kelimeyle bulunur.** |
| 7 | Zenginleştirme | `Memory/EnrichmentWorker.swift:142` | En yeni bekleyen kare: 1 görsel çağrı (`max_tokens` 2500, şemalı JSON) → `ExtractionCheck.verify` → embed → `status = 1` | tek işçi; soru sürerken bekler; hata 2→60 s geri çekilme; 5 denemeden sonra bırakır |
| 8 | Kural kontrolü (metin) | `Safety/SafetyMonitor.swift:642` `checkText` | OCR'da harf varsa: son 60 s'deki metinle %50 benzerse atla, yoksa kısa metin çağrısı (`max_tokens` 200) | en hızlı uyarı yolu: algı + 1 küçük çağrı |
| 9 | Kural kontrolü (anlam) | `SafetyMonitor.swift:543` `checkEnriched` | rerank + kosinüs: yeterince yakınsa doğrudan uyarı, arada ise kısa metin çağrısı | doğrudan: logit ≥ −2,85 ve kosinüs ≥ 0,20 (tek başına kosinüs ≥ 0,27); yok say: logit < −3,1 ve kosinüs < 0,22 |
| 10 | Durum / tehlike | `SafetyMonitor.swift:156` `consider` → `observe` | Evde eller görünürken 5 s'de, değilken 30 s'de bir kare; dışarıda 20 s (yalnız durum kuralı varsa) | "açık" için 2 okuma; **ilk okumadan sonra doğrulama karesi hemen (≥1 s) alınır** |
| 11 | Uyarı | `SafetyMonitor.fire` → `VoiceAssistant.announce` | Ürün başına 3 dk + kural başına 45 s bekleme; düşük önem konuşulmaz | **asistan meşgulse kuyruğa girer, tur bitince söylenir** |

## 2. Soru hattı

| # | Aşama | Kod | Ne yapar | Sabitler |
|---|---|---|---|---|
| 1 | Tetik | `Voice/VoiceAssistant.swift:490` `pushToTalk` | Boşta: dinle. Dinlerken: soruyu bitir. **Düşünürken / konuşurken: kes ve hemen dinle.** | çift dokunuş koruması 2,5 s (boşta, dinlerken), 0,7 s (araya girerken) |
| 2 | Ton + mikrofon | `VoiceAssistant.swift:522` `listenWithEarcon` | Gözlük sesi akıştaysa ton çalarken dinleme açılır; değilse HFP'ye geçiş | akış: 0,12 s; HFP: en fazla 2 s geçiş + 0,56 s |
| 3 | Tanıma | `startListening`, `TapSpeechSession` / `SpeechSession` | Cihazda `SFSpeechRecognizer`, kısmi sonuçlar; tanıyıcı ve isim listesi önceden hazır | isim listesi dakikada bir yenilenir |
| 4 | Erken arama | `handlePartial` → `Memory/QueryEngine.swift` `prepare` | Duraklamada o ana kadarki sözlerle tur kararı + embed + arama + rerank başlar (yan etkisi yok) | 0,45 s duraklama |
| 5 | Soru bitti | `handlePartial`, `armSilenceTimer` | Yeni kelime gelmezse biter | 1,2 s sessizlik; hiç konuşulmazsa 6 s; üst sınır 15 s |
| 6 | Tur kararı + arama | `QueryEngine.retrieve`, `AI/TurnTools.swift` | **Tur kararı** (native tool calling, `tool_choice: required`, ~0,2 s) ∥ [**embed** → yerel hibrit arama (FTS + vektör + bulanık + yakın zaman, RRF k=60, 60 kayıt) → **rerank** (ilk 30 grup)]. Sohbetin ortasındaysa modelin kendi yazdığı sorgu da aranır, ikisi birleştirilip tek rerank yapılır | karar 8 s, embed 2 s, rerank 3 s zaman aşımı (aşılırsa birleşik sıra kalır) |
| 6b | Araçlar | `TurnTools.tools` | `say` (doğrudan konuş), `look_now`, `search_memory(query)`, `forget_recent`, `create_rule`, `confirm_pending`, `cancel_pending`, `delete_rule`, `log_event`, `leaving_home`, `arrived_home`, `set_home`, `snooze_warning` | argümanlar kodda doğrulanır; eksikse bellek aramasına düşer |
| 7 | Canlı kare | `QueryEngine.ask` → `CaptureController.liveView` | `look_now` çağrılırsa hemen: en yeni çözülmüş kare (yoksa akıştan foto) + OCR + maske, 1536 px; rerank beklenmez | kare ≤3 s; foto 25 s |
| 8 | Bağlam | `QueryEngine.ask` | İlk 8 grup + önceki cevabın kayıtları + en fazla 3+1 bölüm (14'er kare) + son 5 kare + 2×2 montaj (640 px hücre) | sohbet: son 4 tur, 15 dk |
| 9 | Cevap | `QueryEngine.answer` | 1 çağrı, şemalı JSON (11 alan: yalnız cevap ve kanıtı), `max_tokens` 1000, sıcaklık 0. **İki uç yarışır** (bkz. §3) | toplam 20 s |
| 10 | Düzeltmeler | `QueryEngine.ask` | (a) kanıt kontrolü geçmezse onarım turu; (b) model "görmedim" dedi ama rerank ≥ −2,8 ise ikinci bakış; (c) yalnız görsele dayanan cevapta kareye yeniden bakma (`lookAgain`, 3,5 s; yer ve zaman kısmını yargılamaz) | her biri en fazla 1 ek çağrı |
| 11 | Kanıt kontrolü | `QueryEngine.checked` | Yerel: alıntı ve sayılar kayıtların OCR'ında var mı. Canlı bakışta yalnız sayılar denetlenir | ağ yok |
| 12 | Konuşma | `VoiceAssistant.swift:409` `speak` | Tek `AVSpeechUtterance`; çıkış HFP'deyse A2DP'ye dönmesini bekler | en fazla 1,5 s (yalnız HFP'den dönerken) |
| 13 | Sonrası | `VoiceAssistant.ask` | Bekleyen uyarılar söylenir; `expects_reply` ise mikrofon yeniden açılır | — |

Ağ çağrısı sayısı: sohbet ("teşekkürler", "naber") = yalnız tur kararı (~0,2–0,5 s). Bellek sorusu = karar + embed + rerank + cevap (karar diğerleriyle paralel). "Bu ne?" = karar + embed + cevap. Düzeltmeler girerse +1 ile +3.

Eski düzende her mesaj (teşekkür dahil) ~25 000 karakterlik cevap istemiyle tek büyük çağrıya gidiyor, hangi eylemin seçileceği o istemin içinde sayfalarca anlatılıyordu; ayrıca ayrı bir router çağrısı vardı. Şimdi eylem seçimi araç tanımlarında, cevap istemi yalnız "kanıttan cevapla" kısmı (~7 000 karakter kısaldı), router yok.

Düşünürken 1,6 s içinde cevap çıkmazsa 2,4 s'de bir çok hafif bir "çalışıyorum" notası çalınır (`waitingTones`).

## 3. Ağ katmanı (`AI/NemotronClient.swift`)

- **İki uç, aynı model**: Verda (takımın konteyneri) ve NVIDIA build. Verda `/embeddings` vermez; embed ve rerank NVIDIA'dadır.
- **Gecikme takibi**: her sohbet çağrısının süresi uç başına yumuşatılarak tutulur (90 s geçerli). Ayarlı uç 2,5 s'den yavaşsa ve diğeri daha hızlıysa arka plan çağrıları (zenginleştirme, güvenlik) diğer uca gider.
- **Yarıştırma (`hedged`)**: soru çağrıları (tur kararı, cevap, yeniden bakma) önce hızlı uca gider; o uç `hedgeAfter` (0,8–2,0 s) içinde cevap vermezse ikinci uç da başlar; ilk başarılı cevap alınır, diğeri iptal edilir.
- **Hız sınırı**: 1,6 s boşluk yalnız NVIDIA uçlarındaki arka plan çağrılarına uygulanır. Sorular hiç bekletilmez; 429 alan soru çağrısı beklemez, diğer uç cevaplar.
- **Öncelik**: soru başlayınca arka plan istekleri iptal edilir (`beginQuestion`); zenginleştirme kareyi yeniden dener, güvenlik çağrıları soru bitince yeniden yapılır.
- Akış (SSE) kullanılmıyor: şemalı JSON iki uçta da tek parça geliyor (ölçüm, aşağıda).

## 4. Ölçümler (14 Kasım)

Uç yoklaması (Mac'ten, `tools/probe*.py`, 2 000 token'lık istem + ~60 token cevap):

| | Verda | NVIDIA build |
|---|---|---|
| Sakin anda toplam | 0,2–0,5 s | 0,8–1,1 s |
| Yoğun anda toplam (aynı gün, ~30 dk fark) | **6–14 s** (3 token'lık istek bile) | 0,8–1,1 s |
| `stream: true` + şema | cevap tek parça, başlıklar da sonda geliyor (vekil tamponluyor) | JSON tek parça (1 chunk); düz metin akıyor |
| Native tool calling | çalışıyor (`auto`, `required`, isimle) | çalışıyor |
| 4 eşzamanlı istek | sorun yok, süre aynı | — |

Sonuç: akıtarak konuşma şemalı cevapla mümkün değil; en büyük gecikme kaynağı ortak Verda ucunun yoğun anları. Bunu uç takibi + yarıştırma çözüyor.

Sohbet testi ve bellek testi sonuçları: bkz. §6.

## 5. Zaman çizelgesi nasıl okunur

Her sesli tur ve her kare `Library/Caches/muisti-trace.log` dosyasına bir satır yazar (kablosuz saha testi için):

```
turn “where was the pharmacy” · mic open 0.3 · last word 2.1 · end of question 3.3 · asking 3.3 · answer ready 4.2 · first sound 4.4 · spoken 7.9 · silence→sound 2.3 s · engine 900 ms · prepared while listening · vector 210 ms · … · answer call 640 ms (primary host)
frame #812 kept: perception 240 ms, stored 0.9 s after capture, 46 chars read
enrich #812: waited 1.4 s · extract 900 ms · embed 300 ms
safety alert [a1b2c3d4] 2.1 s after the frame: Careful: …
safety look: 800 ms, frame 0.6 s old
warning held until the turn ends: …
```

`silence→sound` = kullanıcının son kelimesinden ilk sese kadar geçen süre; hissi belirleyen sayı budur.

Dosyayı almak: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier fi.junction.powerpuffboys.muisti --source Library/Caches/muisti-trace.log --destination <yer>`.

## 6. Test sonuçları

Simülatör, aynı veri seti (14 Kasım). Gecikme = `QueryEngine.ask` süresi (dinleme ve konuşma hariç).

| Ölçüm | Önce | Yarıştırma + paralel arama | + native tool calling (son) |
|---|---|---|---|
| Sohbet testi (29 tur) doğru | 28/29 | 29/29 | 27/29 (üç koşu: 28, 26, 27) |
| Sohbet testi gecikme p50 / p90 | 3050 / 3422 ms | 1824 / 3719 ms | 1064 / 2229 ms |
| Bellek testi (68 soru) cevap / negatif | 64/68 · 11/11 | — | 64/68 · 11/11 |
| Bellek testi gecikme p50 / p90 | 3266 / 4718 ms | — | 2176 / 3291 ms |
| Bellek testi recall@1 / @3 / @8 | 60 / 64 / 65 | — | 58 / 62 / 65 |

Son sohbet koşusundaki iki "hata"da cevap doğru; bakıştan hemen sonraki takip sorusunu ("tam olarak ne yazıyor?", "peki bu ne demek?") test "baktı" bekliyor, model ise az önceki kareyi bellekten ya da sohbetten cevapladı. Koşular arası ±1–2 tur oynama var (model ve uç gecikmesi).

Telefonda (gözlükle) `silence→sound` ölçümü henüz yapılmadı.

## 7. Bilinen açıklar

- Güvenlik kareleri algının OCR + kafa tespitini yeniden çalıştırıyor (`SafetyFrame.prepare`); paylaşılmıyor.
- `checkEnriched` kuralları sırayla değerlendiriyor (kural sayısı az olduğu sürece küçük maliyet).
- Sesle araya girme yok (yalnız dokunuşla): gözlük hoparlörünün yankısı mikrofona giriyor.
- Bakıştan sonraki takip sorusunda model bazen yeniden bakmak yerine az önceki kareyi kaynak gösteriyor (cevap doğru, yol farklı).
- Cevap tek parça okunuyor; cümle cümle akıtma şemalı cevap tek parça geldiği için kazanç sağlamıyor.
- Arka planda kaydedilen video bölümleri öne gelince işlenir; bu kareler durum/tehlike kontrolüne girmez (yalnız metin kuralları).
