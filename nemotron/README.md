# MUISTI: Nemotron hattı (sunucu)

> Bu klasör iOS uygulamasından bağımsızdır. Bütün komutlar `nemotron/` klasöründen çalıştırılır.

Gözlükten gelen kareyi hafızaya çevirir. Sesli soruya kanıtlı cevap verir ya da "bilmiyorum" der.

```
iPhone (Apple Vision OCR, eleme, yüz blur) ──POST /ingest──▶ Nemotron extraction ─▶ kod doğrulayıcı ─▶ depo
                                   ◀─POST /ask─── soru ayrıştırma (Nemotron) ─▶ arama ─▶ kapı ─▶ cevap (Nemotron) ─▶ doğrulayıcı
```

**Ne hatırlıyor (v6):** Tabela yazılarının yanında sahnedeki işe yarar her şeyi de kaydediyor. Nesneler (merdiven, asansör, kanepe, çöp kutusu, QR kod, yangın söndürücü…) konumları ve ayrıntılarıyla tutuluyor. Nesneler arası ilişkiler de kaydediliyor ("directory screen left of elevator"). Yazılar OCR ile doğrulanıyor. Nesneler ise iki şekilde güvence altında: kaç karede görüldükleri sayılıyor, ve cevap sadece bir nesneye dayanıyorsa Nemotron kayıtlı kareye tekrar bakıp nesnenin orada olduğunu teyit ediyor.

## Kurulum

```bash
pip install -r requirements.txt
```

`.env` dosyası (repoya **koymayın**, `.gitignore`'da):
```
LLM_BASE_URL=https://containers.datacrunch.io/nemotron-3-5-super-vl-b300/v1
LLM_MODEL=nemotron-3.5-super-vl
VERDA_INFERENCE_KEY=...
```

## Çalıştırma

```bash
uvicorn server:app --host 0.0.0.0 --port 8000
```
Demo ekranı: http://localhost:8000/ . Soru yazılabilir ya da Chrome'da mikrofonla sorulabilir. Cevap sesli okunur, kanıt kareleri ve hafıza zaman çizelgesi gösterilir. Gözlük yokken canlı demo yedeği olarak kullanılabilir.

Kayıtlı bir videoyu telefon gibi sunucuya göndermek için:
```bash
python tools/replay_video.py video.mp4 --start 2026-11-14T10:00:00
```

## API (iPhone ekibi için)

**POST /ingest**
```json
{ "frame_jpeg_b64": "...", "seen_at": "2026-11-14T10:32:05", "lat": 60.17, "lon": 24.82,
  "ocr_observations": [ {"text": "ARDUINO", "conf": 0.98, "box": [0.12, 0.30, 0.25, 0.06]} ] }
```
- `ocr_observations` alanına Apple Vision çıktısını olduğu gibi gönderin. `box` normalize edilmiş x, y, genişlik, yükseklik değerleri; orijin **sol üst**. Vision'ın kendi orijini sol alt, yani `y = 1 - maxY` dönüşümü gerekiyor.
- OCR gönderilmezse sunucu geçici olarak Nemotron'u OCR olarak kullanır (`STANDIN_OCR=1`).
- Cevap: `{"stored": true, "memory_id": 12, "record": {...}, "rejected": [...]}`

**POST /ask**
```json
{ "question": "Which floor is the sauna on?", "now": "2026-11-14T10:40:00" }
```
Cevap:
```json
{ "answer": "The sauna is on the 7th floor.", "label": "SEEN", "label_tr": "GORDUM",
  "evidence": [{"memory_id": 7, "frame_url": "/frames/42.jpg", "seen_at": "22:04:21", "lat": null, "lon": null, "text": "..."}] }
```
- `label` değerleri: `SEEN` / `DONT_KNOW` / `FORGOT`. Türkçe karşılıkları `label_tr` alanında: GORDUM / BILMIYORUM / UNUTTUM.
- "Forget the last 10 minutes" gibi sesli komutlar da `/ask` üzerinden çalışır.
- `now` gönderilmezse sunucu "son hafıza + 2 dk" kullanır (`DEMO_CLOCK=latest`). Böylece kayıtlı videolar demo gününde de çalışır.

Diğer uç noktalar: `POST /forget {"minutes": 10}`, `GET /memories`, `GET /frames/{id}.jpg`, `GET /stats`.

## Apple Vision entegrasyonu

- **Uygulamada:** `VNRecognizeTextRequest` ile `.accurate` modunu kullanın, `usesLanguageCorrection = false` yapın (dil düzeltmesi rakamları "düzeltiyor"), dil `en-US`, `minimumTextHeight = 0.015`. Çıktıyı `ocr_observations` olarak gönderin.
- **Bilgisayarda test için:** `tools/vision_ocr.swift` script'ini Mac'te kare klasörü üzerinde çalıştırın, ardından JSON'u replay'e verin:
  ```bash
  swift tools/vision_ocr.swift results/<video>/v4/frames > vision.json
  python tools/replay_video.py video.mp4 --ocr-json vision.json
  ```
- `ocr_adapter.py`, Vision kutularını satırlara diziyor. Yan yana duran etiket ve değer (ör. "7TH FLOOR" ile "SAUNA AND POOL") aynı satıra düşüyor, çünkü doğrulayıcı liste öğelerini sadece tek satırdan kabul ediyor.

## Aiven (yapılacak)

`store.py` içindeki `SqliteStore` sınıfı Aiven'a takılmaya hazır. Aynı 5 metodu (`add_frame`, `frames`, `sightings`, `forget`, `latest_time`/`stats`) psycopg ile yazmak yeterli. `frames` tablosunun şeması dosyanın başında. Embedding için `nvidia/nemotron-3.5-embed-1b` önerilir. Bu model 2048 boyutlu vektör üretiyor; pgvector'de `halfvec(2048)` kullanın ya da vektörü 1024'e kırpıp yeniden normalize edin. Ayrıntılar araştırma raporunda.

## Değerlendirme

`results/`, `data/` ve `.env` repoya girmez (`.gitignore`). `results/` kareler içerir ve yüzler orada blur'suzdur. Test için önce videoları işleyin:

```bash
python process_video.py video1.mp4 --version v6
python eval/reextract.py --base v6 --out v7
```

| Komut | Ne yapar |
|---|---|
| `python process_video.py video.mp4 --version vX` | Videoyu kare kare işler, `results/<video>/vX/report.html` raporunu üretir |
| `python eval/evaluate.py results/.../results.json eval/gt_whatsapp_video_1.json` | Extraction'ı doğru cevaplara göre puanlar |
| `python eval/run_ask_tests.py [--server http://localhost:8000]` | 25 soruluk soru-cevap testini çalıştırır (14 cevaplanabilir, 11 tuzak; 10'u nesne sorusu) |
| `python eval/ablation.py` | Temperature ve reasoning karşılaştırmalarını çalıştırır |

Bütün iterasyonlar ve sonuçları `eval/ITERATIONS.md` dosyasında. Nemotron teslim metninin taslağı `docs/nemotron_submission.md` dosyasında.

## Dosyalar

| Dosya | Görev |
|---|---|
| `server.py` | FastAPI sunucusu |
| `extract.py` | Nemotron ile kayıt çıkarma ve kod doğrulayıcı |
| `ask.py` | Soru ayrıştırma, arama, kapı, cevap üretme, doğrulama |
| `merge.py` | Ardışık kareleri tek görülmeye birleştirme (oylama) |
| `store.py` | Depo (SQLite; Aiven için arayüz) |
| `ocr_adapter.py` | Apple Vision çıktısını satırlara çevirme |
| `process_video.py`, `tools/replay_video.py` | Offline test ve replay |
| `extract_v1.py` | İlk sürüm, karşılaştırma için duruyor |

## Mahremiyet

- Yüz blur'u **telefonda** yapılır (iPhone ekibi). Sunucu kareleri geldiği gibi işler ve saklar, yani blur'suz kare gönderilmemeli.
- Ham video saklanmaz. Sadece bilgi içeren kareler çıkarılmış kayıtla birlikte saklanır.
- "Forget the last N minutes" komutu o aralıktaki kareleri ve kayıtları siler.
- Prompt, modele insanları, yüzleri, kıyafetleri ve plakaları tarif etmeyi yasaklar.
