# MUISTI Agent Pipeline v2: inceleme ve hedef mimari

Kaynak: `~/Desktop/MUISTI/ios` (son commit `0962ebd hotfix`). Satır numaraları o commit'e göredir.

Okunanlar: `docs/PIPELINE.md`, `docs/AGENT.md` ve README, ayrıca şu dosyaların ilgili bölümleri:
- `AI/NemotronClient.swift`
- `Memory/EnrichmentWorker.swift`, `Memory/QueryEngine.swift`, `Memory/MemoryStore.swift`
- `Agent/AgentCenter.swift`, `Agent/Notice.swift`
- `Safety/SafetyMonitor.swift`
- `Pipeline/CaptureController.swift`

Hedef:
1. Muisti gerçek bir agent gibi otonom çalışsın.
2. Kullanıcı sorunca tetiklensin. Bu yol daha sonra eklenecek; tasarım şimdiden ona yer bıraksın.
3. Konuşma bağlamı kaybolmasın.
4. Sunucu kaldırdığı ve cevap hızlı geldiği sürece AI rahatça kullanılsın.

---

## 0. Kısa hüküm

Mevcut sistem iyi bir temel. Kanıt kuralı, kare şeridi, `InterventionPolicy`, tool calling ile tur kararı, niyetler ve rutinler yerinde. Asıl sorunlar mantıkta değil, **mimari varsayımlarda**. Kod, iki şeyin geçerli olduğu bir dünyaya göre yazılmış:

1. Sunucu yavaş ve paylaşımlı, dakikada 40 istek sınırı var.
2. Aynı anda tek iş yapılabilir.

Bu yüzden her yerde tekli kilit, iptal, en yeniyi tut, eskiyi at ve NVIDIA'ya kaçış var.

Artık bu varsayımlar geçerli değil:
- Sunucu sadece MUISTI'nin.
- Tek çağrı 0.1–0.9 sn sürüyor.
- 128 paralel görüntülü istek 2.8 sn'de bitiyor.
- İstek başına 8 görüntü gönderilebiliyor.
- KV cache 3.4M token.

Agent hissini öldüren üç şey var:
1. **Olaylar düşüyor.** Tekli kilitler yüzünden notice'ler, güvenlik bakışları ve arka plan kareleri kayboluyor.
2. **Bağlam unutuluyor.** Konuşma RAM'de son 6 tur, son 15 dk ve 4 turla sınırlı. Ajanın kendi konuşması ile kullanıcının konuşması ayrı yerlerde tutuluyor.
3. **Tek bir beyin yok.** Kare hakemi, güvenlik ve soru hattı üç ayrı "akıl". Birbirlerinin ne düşündüğünü görmüyorlar, sadece bazı notlar paylaşılıyor.

---

## 1. Bulgular (kanıtıyla)

### A. Kayıp ve tıkanma (en kritik)

| # | Yer | Ne oluyor | Sonuç |
|---|---|---|---|
| A1 | `AgentCenter.noticed` (~464) | `judging` true iken gelen notice `waitingNotice = n` ile tutuluyor: **sadece en sonuncusu**. Aradakiler sessizce kayboluyor | 1 hakem çağrısı sürerken 3 ilginç kare gelirse 2'si hiç değerlendirilmiyor. Örnek: ilaç kutusu, ardından açık ocak. Ocak kalır, ilaç kaybolur |
| A2 | `SafetyMonitor.consider` (168, 196) | `!inFlight` varsa kare hiç işlenmeden dönüyor | Güvenlik bakışı sürerken gelen alerjen etiketi ya da şerit karesi atılıyor |
| A3 | `CaptureController` (204) | `bufferingNewest(6)` | Algı yavaşlarsa eski kareler atılıyor. Olağan durumda sorun değil, ama düştüğü bilgisi hiçbir yere yazılmıyor |
| A4 | `EnrichmentWorker.run` (85–118) | Tek işçi: `pending(limit: 1)`, `ORDER BY seen_at DESC` (LIFO) | Yürürken kuyruk birikiyor ve eski kareler en sona kalıyor. Ajanın "görünce hatırlat" ve rutin tetikleri bu karelere bağlı, o yüzden gecikiyor ya da `late` olup sessize iniyor |
| A5 | `EnrichmentWorker.run` (97) | `while questionsInFlight > 0 { sleep }` | Kullanıcı konuştuğu sürece zenginleştirme ve onun arkasındaki bütün proaktif zincir duruyor |
| A6 | `NemotronClient.beginQuestion` (181–186) | Soru başlayınca bütün arka plan istekleri **iptal** ediliyor | Hakem ve güvenlik çağrıları yarıda kesiliyor. Güvenlik "soru bitince yeniden yapılıyor", yani gecikiyor |
| A7 | `ingestBackgroundSegment` (501) | Arka plan videosundan gelen kareler güvenlik ve tehlike kontrolüne girmiyor (PIPELINE.md §8 de bunu açık olarak listeliyor) | Telefon cepteyken çekilen her şey ajan için kör nokta |

Bunların hepsi "tek iş" ve "kıt sunucu" varsayımından geliyor. Kendi sunucumuzda bunlara gerek yok.

### B. Bağlam (context) kaybı

| # | Yer | Ne oluyor |
|---|---|---|
| B1 | `QueryEngine.conversation` (77–82) | RAM'de en fazla 6 tur. Uygulama kapanınca hepsi sıfırlanıyor |
| B2 | `QueryEngine` (192, 460) | İsteme sadece **son 15 dk içindeki son 4 tur** giriyor. "Sabah sana söylediğim şey" kayboluyor |
| B3 | `Turn` yapısı | Sadece soru, cevap, `ids`, `looked`. Hangi aracın çağrıldığı, hangi niyetin oluştuğu, hangi kuralın konduğu tutulmuyor. "Az önce kurduğun hatırlatmayı 5 dk ertele" gibi referanslar zayıf kalıyor |
| B4 | `AgentCenter.situation` (270) ve `Notice.judge` | Hakem konuşmayı **görmüyor**. Kullanıcı 1 dk önce "ilacımı aldım" dediyse `log_event` ile güvenlik günlüğüne düşüyor, bu iyi. Ama "şu an toplantıdayım, rahatsız etme", "Ali'yi bekliyorum" gibi konuşma bağlamı hakeme hiç ulaşmıyor |
| B5 | `noteMuistiSaid` | Ajanın söylediği şey konuşmaya sadece metin olarak giriyor; hangi niyet, hangi kanıt kaydı bilgisi kayboluyor |
| B6 | Uzun bağlam hiç kullanılmıyor | Model 65k token alıyor, sohbet bağlamı birkaç yüz token. Özet, uzun süreli kullanıcı modeli ve gün içi konuşma geçmişi yok |

### C. Sunucu ve ağ katmanı

| # | Yer | Ne oluyor | Öneri |
|---|---|---|---|
| C1 | `preferredRoute`, `hedged`, `fallbackAvailable` | Verda yavaşsa NVIDIA build'e kaçış: görüntülü arka plan çağrıları dahil | Görüntülü hiçbir çağrı NVIDIA'ya gitmesin (gizlilik: "Finlandiya'da işleniyor"). Hedging'i kapat. "Verda 6–14 sn" ölçümü eski paylaşımlı konteynere ait; kendi konteynerimizde ölçüm 0.1–0.9 sn |
| C2 | `URLSessionConfiguration.default` | Host başına bağlantı limiti varsayılan. HTTP/2 olduğu için tek bağlantıda çoğullanıyor, sorun değil | Eşzamanlılığı yönetmek için lane limiter ekle (aşağıda) |
| C3 | `stream: true` | Verda gateway yanıtı tamponluyor: tek parça geliyor (bugün test edildi, 556 ms'de tek chunk) | Akıtma yok. Bunun yerine kısa ilk cümle + devam stratejisi, ayrıntı §4.6'da |
| C4 | `pace` sadece `nvidia.com` için | Doğru | — |

### D. Tek beyin eksikliği

Şu an kendi kendine karar veren üç ayrı yer var:
1. **`SafetyMonitor`:** kendi `observe` çağrısı, kendi durum makinesi, kendi `fire` fonksiyonu.
2. **`AgentCenter`:** `tick` 15 sn, `noticed`, `review` 10 dk, `Notice.judge`.
3. **`QueryEngine`:** kullanıcı turu.

Hepsi sonunda `InterventionPolicy`'de birleşiyor; konuşma kapısı tek. Ama düşünce tek değil:
- Hakem, güvenliğin son baktığı şeyi bilmiyor; güvenlik günlüğü üzerinden dolaylı öğreniyor.
- Soru hattı, hakemin az önce "sustum çünkü…" dediğini bilmiyor.
- Hakemin sadece eylem araçları var (`stay_silent`, `tell_user`, `note_for_later`, …). **Okuma aracı yok**: karar vermeden önce belleğe, rotaya, takvime bakamıyor, sadece ona verilen paketi görüyor.

---

## 2. Hedef mimari

```
                         ┌─────────────────────────── KALICI DURUM (SQLite) ───────────────────────────┐
                         │ memory.sqlite (kayıtlar, kareler, embedding)  safety.sqlite  agent.sqlite    │
                         │ + YENİ dialog.sqlite: events, turns, summaries, working_memory, open_threads │
                         └──────────────────────────────────────────────────────────────────────────────┘
                                                        ▲   │
  GİRDİLER (hepsi Event olur)                           │   ▼
  ─ kare (algı sonrası)            ┌───────────────────────────────────────┐
  ─ zenginleştirilmiş kayıt        │            EVENT BUS (actor)            │  sıralı, kalıcı, öncelikli
  ─ güvenlik gözlemi               │  P0 safety | P1 user | P2 notice | P3 bg │
  ─ konum / hareket / bölge        └───────────────────────────────────────┘
  ─ saat tiki / takvim                              │
  ─ kullanıcı sözü (dokunuş, ileride wake word)     ▼
  ─ bildirim eylemi                ┌───────────────────────────────────────┐
                                   │          MUISTI BRAIN (actor)           │
                                   │  1. Kural filtresi (kod, 0 LLM)         │
                                   │  2. Bağlam derleyici (ContextBuilder)   │
                                   │  3. Agent döngüsü: Nemotron tool loop   │
                                   │     (okuma araçları → karar araçları,   │
                                   │      en çok 4 adım)                     │
                                   │  4. Kanıt denetimi (EvidenceRule)       │
                                   └───────────────────────────────────────┘
                                                    │ Action
                                                    ▼
                                   InterventionPolicy → ses / bildirim / sessiz kayıt / bellek yazımı
```

### 2.1 İlkeler

1. **Hiçbir olay düşmez.**
   - Her olay `events` tablosuna yazılır; durumu `queued → handled / merged / expired` olur.
   - Atılan olay için bile neden yazılır.
2. **Tek beyin, çok işçi.**
   - Karar veren tek bir `MuistiBrain` actor var.
   - Algı, zenginleştirme ve güvenlik bakışı işçileri paralel çalışır, sonuçlarını bus'a olay olarak bırakır.
3. **Kod filtreler, model düşünür, kod konuşturur.**
   - Ucuz kod kapıları (embedding, rerank, durum makinesi, eşikler) hangi olayın beyne gideceğini seçer.
   - Beyin karar verir.
   - Ne zaman ve ne kadar yüksek sesle konuşulacağına `InterventionPolicy` karar verir.
4. **Bağlam tek ve kalıcı.**
   - Kullanıcı turu, ajanın kendiliğinden söylediği, susma kararı ve önemli gözlem aynı `dialog` akışına yazılır.
   - Beyin her çağrıda aynı bağlam derleyicisinden geçer.
5. **Lane'ler kilit değil, kapasite.**
   - Her öncelik sınıfının kendi eşzamanlılık limiti var. Kimse kimseyi iptal etmez.

### 2.2 Lane'ler (öncelik sınıfları)

| Lane | Ne | Eşzamanlı | Kuyruk politikası | Zaman aşımı |
|---|---|---|---|---|
| **P0 safety** | Güvenlik bakışı (izlenen nesne, alerjen, şerit), tehlike hakemi | 6 | Aynı (rule, scene) için en yeni olay ötekileri **birleştirir** (merge, düşmez); en fazla 3 sn bekler | 6 sn |
| **P1 user** | Kullanıcı turu (karar, cevap, düzeltme), canlı bakış | 8 | FIFO | 20 sn |
| **P2 notice** | Hakem (niyet eşleşmesi, dikkat işareti, rutin sapması, periyodik bakış) | 6 | FIFO; 120 sn'den eski olay "late" etiketiyle yine işlenir, politika bildirime indirir | 10 sn |
| **P3 bg** | Zenginleştirme, embedding, görüntü embedding, bölüm özeti, gün özeti, konuşma özeti | 12 | FIFO (eskiden yeniye), yeni kare için "fast slot" | 30 sn |

Uygulama: `NemotronClient` içine `actor Lane { acquire(); release() }`. `beginQuestion`'daki iptali sil. `questionsInFlight` sadece telemetri için kalsın.

Neden güvenli: ölçülen kapasite 128 eşzamanlı. Bu tablonun toplamı 32. Pik anda P1 gecikmesi ölçümle +0.1–0.3 sn.

---

## 3. Kare hattı v2

```
Gözlük kare ─► Scheduler (aynı) ─► Perception (aynı: netlik, dHash, OCR ∥ head-blur, gizlilik kapısı)
     │
     ├─► Event(frame.kept)  ─► P3 Enrichment işçileri (N=6, FIFO + fast-slot)
     │                              └─ Frame Analyst çağrısı (tek birleşik şema, aşağıda)
     │                                    └─ Event(record.enriched) ─► Brain
     │
     └─► Kural kapısı (kod): izlenen nesne / alerjen / el görünüyor / mutfak bölgesi?
              └─ evet ─► P0 Safety Look (şerit ≤8 kare) ─► Event(safety.observed) ─► SafetyMonitor durum makinesi
                                                                                   └─ Event(safety.alert) ─► Brain
```

### 3.1 Değişiklikler

1. **`EnrichmentWorker`: çok işçi.**
   - `pending(limit: 1)` yerine `pending(limit: 12)` çek ve `withTaskGroup` ile P3 lane limitinde işle.
   - Sıra: **FIFO** (`seen_at ASC`). Ek olarak "fast slot": son 3 sn içindeki en yeni kare kuyruğu atlayıp hemen işlenir (canlı "bu ne?" ve tehlike için).
   - `while questionsInFlight > 0` satırını sil.
   - Aynı kayıt iki işçiye düşmesin: `status = 2 (in_progress)` + `claimed_at`; 60 sn'de geri alınır.
2. **`SafetyMonitor.consider`:** `inFlight` bayrağını kaldır.
   - Yerine `(rule set hash, room)` anahtarlı bir "en yeni bekleyen" haritası: aynı anahtara gelen yeni kare eskisinin yerine geçer (merge); farklı anahtarlar paralel çalışır.
   - `maxPerMinute` 20'den 60'a.
   - Şerit 8 kare.
3. **Arka plan segmentleri** (`ingestBackgroundSegment`):
   - Kareler `trigger: .background` ile bus'a düşsün.
   - Güvenlik ve dikkat değerlendirmesi de yapılsın. Ancak olay "late" sayılır: sesli değil, "bugün 14:20'de ocağı açık gördüm, kapattığını görmedim" gibi bir **retrospektif uyarı** olur.
   - Durum makinesi geçmiş zaman damgasıyla beslenir.
4. **Frame Analyst: tek birleşik şema.** Zenginleştirme zaten `attention` üretiyor. Şemaya güvenlik ve agent alanlarını ekle ki her karede ayrı istemler çelişmesin:

```json
{
  "...mevcut extraction alanları...": "...",
  "attention": "none|warning|time_limited|schedule|price|event|document|person_badge|personal|hazard",
  "attention_reason": "string",
  "object_states": [{"object": "stove|tap|door|window|iron|fridge|...", "state": "on|off|open|closed|unknown", "evidence": "string"}],
  "allergens_seen": [{"allergen": "strawberry|milk|...", "where": "label|plate|shelf", "quote": "string|null"}],
  "actions": [{"action": "locked_door|turned_off_stove|took_medicine|put_down_keys|...", "confidence": 0.0}],
  "landmarks": [{"kind": "exit|stairs|elevator|room_sign|shop", "text": "string|null", "direction": "left|right|ahead|null"}],
  "hold_items": ["keys", "wallet", "medicine:<name>"]
}
```

   - `SafetyMonitor`, P0 bakışı **yapmadığı** karelerde bu alanları ikinci kaynak olarak alır (durum makinesine "enrichment" kaynağıyla girer, ağırlığı daha düşük).
   - `landmarks`, bina içi yol tarifinin hafızası olur (§5.3).
   - Maliyet: aynı çağrı, biraz daha çok çıktı token'ı. Ek çağrı yok.

---

## 4. Bağlam (context) yönetimi: hiç kaybolmayan konuşma

### 4.1 Yeni tablo: `dialog.sqlite`

```sql
CREATE TABLE turns(            -- konuşmadaki her şey, iki yönlü
  id INTEGER PRIMARY KEY,
  at REAL NOT NULL,
  speaker TEXT NOT NULL,       -- 'user' | 'muisti' | 'muisti_proactive' | 'system_note'
  text TEXT NOT NULL,
  tool_calls TEXT,             -- JSON: [{name, args, result_summary}]
  record_ids TEXT,             -- JSON: dayanılan bellek kayıtları
  intent_ids TEXT,             -- oluşturulan/değinilen niyetler
  safety_event_ids TEXT,
  looked_frame TEXT,           -- canlı bakış karesi dosyası
  thread_id INTEGER            -- açık konu (ör. "ilaç onayı", "Kiasma rotası")
);
CREATE TABLE summaries(        -- yuvarlanan özetler
  id INTEGER PRIMARY KEY, from_turn INTEGER, to_turn INTEGER, at REAL, level TEXT, -- 'session'|'day'
  text TEXT NOT NULL
);
CREATE TABLE open_threads(     -- cevap bekleyen / devam eden konular
  id INTEGER PRIMARY KEY, opened_at REAL, kind TEXT, -- 'pending_yes_no'|'navigation'|'task'|'question_back'
  prompt TEXT, state TEXT, expires_at REAL
);
CREATE TABLE working_memory(   -- beynin kendi kısa notları (scratchpad), TTL'li
  key TEXT PRIMARY KEY, value TEXT, at REAL, expires_at REAL
);
CREATE TABLE user_model(       -- uzun süreli: kullanıcının söyledikleri + onaylı tercihler
  id INTEGER PRIMARY KEY, fact TEXT, source_turn INTEGER, at REAL, confidence REAL
);
```

- `QueryEngine.conversation` dizisi bu tabloya taşınır.
- `noteMuistiSaid`, `noteExchange` ve ajanın `interventions` kayıtları **aynı** `turns` akışına yazılır. Susma kararları `system_note` olarak yazılır ama bağlama sadece özetle girer.
- Mevcut `AgentStore.facts` doğrudan `user_model`'e eşlenir.

### 4.2 ContextBuilder: her çağrı aynı yoldan

Bütçe: Nemotron 65k context. Hedef **≤ 12k token** bağlam: hızlı kalır, prefix cache'ten yararlanır.

| Blok | İçerik | Bütçe | Sıra (prefix cache için sabit → değişken) |
|---|---|---|---|
| 1. Sistem | Muisti kimliği, kurallar, araç tanımları | ~3k | En başta, **byte-byte sabit** |
| 2. Kullanıcı modeli | `user_model` (alerji, ilaç, ev, iş, tercihler), kurallar özeti | ~1k | Gün içinde nadiren değişir |
| 3. Gün özeti | `summaries(level='day')` dün ve bugün | ~0.8k | Saatte bir güncellenir |
| 4. Oturum özeti | Bugünün eski turlarının yuvarlanan özeti | ~1k | Her 8 turda bir yenilenir |
| 5. Açık konular | `open_threads` + ajanın bekleyen sorusu + aktif rota + açık niyetler | ~0.8k | |
| 6. Son turlar (birebir) | Son **12 tur** (zaman sınırı yok, gün sınırı var), araç sonuçları özetli | ~3k | |
| 7. Durum | Saat, konum, hareket, bölge, son güvenlik durumları, son 3 kare açıklaması | ~0.8k | |
| 8. Görev | Bu çağrıya özgü olay veya soru + getirilen kayıtlar + görüntüler | geri kalan | En sonda |

Kurallar:
- **Özetleyici P3'te çalışır.** Turlar 20'yi geçince en eski 8 tur özetlenip `summaries`'e yazılır. Özet istemi: "kim ne istedi, ne söz verildi, ne kararlaştırıldı, hangi sayı ve isimler geçti". Sayı ve isimler korunur. Birebir turlar silinmez, sadece bağlamdan çıkar.
- **Referans çözümü:** "onu", "az önceki", "o hatırlatma" ifadeleri için 6. bloktaki `tool_calls` ve `intent_ids` sayesinde model doğru niyeti adlandırabilir. Her niyet satırına `#id` yaz.
- **Oturum sınırı yok:** uygulama kapanıp açılsa da 4–6. bloklar SQLite'tan gelir. "Yeni sohbet" düğmesi sadece 6. bloğu boşaltır, özetler kalır.
- **Hakem de aynı ContextBuilder'ı kullanır** (B4 çözümü): toplantıdayım / rahatsız etme / Ali'yi bekliyorum gibi bilgiler hakemin bağlamına girer. Bu tür ifadeler `working_memory`'ye TTL ile de yazılır.

### 4.3 Konuşmanın gözlemle bağlanması

- Kullanıcı bir şeye bakarken soru sorarsa canlı kare, `looked_frame` olarak tura bağlanır. Sonraki 10 turda (90 sn değil) takip sorusu gelirse aynı kare yeniden verilir.
- "Tekrar bak" denirse yeni kare alınır.

### 4.4 Paralel hazırlık (mevcut `prepare` mantığı korunur)

- Kullanıcı konuşurken 0.45 sn duraklamada tur kararı, embed, arama ve rerank başlıyor. Bu korunur.
- Ek olarak ContextBuilder blokları (1–5 ve 7) önbellekte hazır tutulur, her olayda artımlı güncellenir. Cevap çağrısı sadece 6 ve 8'i ekler.

### 4.5 Cevap biçimi

- Şemalı JSON kalır (kanıt alanları için gerekli), ama alan sırası `answer` önce olacak şekilde sabit tutulur.
- Akıtma Verda gateway yüzünden yok (C3).

### 4.6 Algılanan hız

Akıtma olmadığı için iki adım:
- (a) Tur kararı (0.2–0.3 sn) `say` ise doğrudan konuş.
- (b) Bellek cevabında mevcut `waitingTones` kalsın. İçerikli bir ön cümle ("sabah mutfakta…") eklenmesin: kanıt denetiminden geçmemiş bir cümle olur ve uydurma riskini artırır.

Asıl hız kazancı lane'lerden ve iptalin kalkmasından gelir.

---

## 5. Agent döngüsü (Brain)

### 5.1 Tetikler, hepsi Event

| Event | Kaynak | Kod kapısı (LLM'siz) | Beyne gider mi |
|---|---|---|---|
| `record.enriched` | Zenginleştirme | Niyet eşleşmesi (mevcut embedding + rerank), `attention != none`, standing cue'lar, `object_states`/`actions` değişimi | Eşleşme varsa P2 |
| `safety.alert` | `SafetyMonitor` | Durum makinesi (2 okuma vb.) | P0, hakem sadece **cümleyi** kurar, karar zaten verilmiş |
| `place.enter/exit`, `home.leave/arrive` | Konum, bölge | Mevcut `tick` hesapları | P2 |
| `route.deviation/turn/arrive` | `RouteGuide` | Mevcut eşikler | Dönüş ve varış doğrudan konuşulur (LLM yok); sapmada P1 kalitesinde hızlı cümle |
| `habit.missed` | `Habits` | +30 dk kuralı | P2 |
| `time.tick` | 15 sn | Zamanı gelen niyet, takvim | P2 |
| `review.periodic` | **Yeni:** kayıt açıkken her 2 dk (eskiden 10 dk) ve durum değiştiyse | Son 2 dk'nın olay özeti boş değilse | P2 |
| `user.utterance` | Dokunuş, ileride wake word veya Siri | — | P1 (tam agent turu) |
| `notification.action` | Bildirim düğmesi | — | P1 |

**"Sorunca tetiklensin" için şimdiden yer:** `user.utterance` dışında `user.summon` olayı tanımla. Dokunuş, wake word ya da Siri hepsi aynı olayı üretir. Payload'da `{source, partial_text?, live_frame?}` olur. İleride wake word eklemek sadece yeni bir üretici yazmak demek.

### 5.2 Agent turu: tool loop (P1 ve P2 için ortak)

Şu an tur kararı tek çağrı, hakem tek çağrı. Yeni hali: **en fazla 4 adımlı tool döngüsü**. Sunucu hızlı (araç çağrısı 0.26 sn), 2–3 adım 1 sn civarı tutar.

**Okuma araçları** (yan etkisiz, paralel çağrılabilir):
- `search_memory(query, from, to, place)`: mevcut
- `object_state(object)`: son görülme, durum, güven, kanıt karesi id'si. "Sütüm var mı?" buradan cevaplanır; cevap "son gördüğüm" biçimindedir
- `verify_action(action, since)`: mevcut `doneCheck` mantığı; şerit karelerini 8 resimle modele gösterir
- `safety_log(since, object?)`
- `route_status()`, `calendar(next_hours)`, `places(query)`: mevcut, araç olarak açılır
- `look_now()`: canlı kare
- `recall_dialog(query)`: eski turlar ve özetler içinde arama (FTS). Bağlam kaybının son emniyeti
- `working_memory_get(key)`

**Karar ve eylem araçları:**
- `say(text, urgency)`, `ask(text, expects: yes_no|free)`, `stay_silent(reason)`, `note_for_later(text)`
- `remember_intent`, `complete_intent`, `drop_intent`, `create_rule`, `log_event`, `set_destination`, `mute_topic`, `add_to_calendar` (sadece onayla), `working_memory_set(key, value, ttl)`

**Döngü kuralları:**
- **Adım 1:** Model okuma araçlarını (en çok 4 tanesini paralel) ya da doğrudan bir karar aracını çağırır.
- **Adım 2–3:** Araç sonuçları eklenir, model tekrar çağrılır.
- **Adım 4:** `tool_choice: required`, sadece karar araçları açık.
- **Kanıt kuralı:** `say` ve `ask` metni `EvidenceRule` ile denetlenir. Sayı ve alıntı, araç sonuçlarında geçmek zorunda.
- **Bütçe:**
  - P1: toplam 6 sn. Aşılırsa elde ne varsa onunla cevap verilir.
  - P2: 10 sn.
  - P0: 1 adım, sadece cümle.

### 5.3 Senaryolara göre akış

| Senaryo | Olay zinciri |
|---|---|
| **Ocak açık unutuldu** | P0 bakış "on" ×2 → durum makinesi → `home.leave` veya 20 dk mutfak görülmedi → `safety.alert` → Brain cümle kurar (kanıt kareli) → politika seviye 3 |
| **Süt** | Buzdolabı karesi → `object_states`/objects: `milk(half)` → `object_state` deposu. Markette süt rafı → `record.enriched` + standing cue "alışveriş" → Brain `object_state("milk")` → "en son dün 18:40'ta yarım süt gördüm" |
| **Çilek alerjisi** | `user_model` alerjisi → P0 kural kapısı (OCR'da çilek/mansikka/jordgubb ya da `allergens_seen`) → anında `safety.alert` |
| **"Kilitledim mi?"** | `user.utterance` → `verify_action("locked_door", today)` → şerit 8 kare → kanıtla cevap |
| **Görünce hatırlat** | `remember_intent(cue.sight)` → her `record.enriched`'te mevcut eşleşme → P2 Brain → `say` |
| **Bina içi yön** | `landmarks` her karede yazılır → "çıkış nerede?" → `search_memory(kind:landmark, since: giriş)` + `route_status` → ters sırayla tarif. Sapma: hedef yöne uymayan landmark → `route.deviation` |
| **Dış navigasyon** | Mevcut `RouteGuide` (MKDirections) + sapma event'i → "buradan dönecektin" |
| **Matematik** | `user.utterance` + `look_now` → thinking **açık** tek çağrı (bu turun bütçesi 15 sn) |
| **Rutin sapması** | `habit.missed` → P2 → `ask` ("bugün ilacını aldın mı?") → `open_threads(pending_yes_no)` → cevap `log_event` |

### 5.4 Thinking ne zaman açık

| Çağrı | Thinking |
|---|---|
| Frame Analyst, safety look, tur kararı, hakem | Kapalı |
| Matematik veya "açıkla" soruları, ilaç çift doz ve alerjen belirsizliği (gray zone), günlük özet | Açık (`max_tokens` ≥ 2048, bu çağrıların bütçesi 15 sn) |

Seçimi tur kararı yapsın: araçlara `reasoning_needed: bool` parametresi ekle.

---

## 6. Ağ katmanı değişiklikleri (`NemotronClient`)

1. `actor Lane` ve dört lane (§2.2). `chat`, `chatJSON`, `chatTools`, `embed`, `rerank` imzalarına `lane:` parametresi.
2. `beginQuestion` artık iptal etmesin. `NemotronError.preempted` yolunu kaldır.
3. **Hedging ve fallback:**
   - `fallbackAvailable` ancak `Settings.allowNvidiaFallback` (varsayılan **false**) açıksa true olsun.
   - Görüntü içeren istek **asla** fallback'e gitmesin.
   - Fallback sadece Verda 5xx ya da timeout verdiğinde devreye girsin.
4. **Retry:** 429/502/503/504 için 0.5–1–2 sn backoff (lane içinde).
5. **Telemetri:** `muisti-trace.log`'a lane, bekleme süresi ve kuyruk derinliği yaz.

---

## 7. Uygulama sırası (bu gece)

| Sıra | İş | Dosyalar | Süre | Kabul testi |
|---|---|---|---|---|
| 1 | Lane'ler, iptalin kaldırılması, fallback'in kapatılması | `NemotronClient.swift` | 1 sa | `agenteval` ve `conveval` gerilemesiz; trace'te `preempted` yok |
| 2 | `noticed` kuyruğu (A1), `SafetyMonitor` merge haritası (A2) | `AgentCenter.swift`, `SafetyMonitor.swift` | 1 sa | 5 ilginç kare art arda geldiğinde 5 hakem kaydı (`interventions` tablosunda 5 satır) |
| 3 | Zenginleştirmede N işçi, FIFO + fast slot, claim (A4, A5) | `EnrichmentWorker.swift`, `MemoryStore.swift` | 1 sa | 60 karelik ingest süresi en az 4× hızlanmış; soru sırasında zenginleştirme durmuyor |
| 4 | `dialog.sqlite` + ContextBuilder + konuşma özetleyici (B1–B6) | Yeni: `Agent/Dialog.swift`, `Agent/ContextBuilder.swift`; `QueryEngine`, `AgentCenter` | 2 sa | Yeni test: 30 turluk konuşmada 25. turda 3. turdaki bilgiyi sorma doğru; uygulama yeniden başladıktan sonra "az önce ne dedim?" doğru |
| 5 | Hakem + tur kararı → ortak tool loop, okuma araçları | `TurnTools.swift`, `Notice.swift`, `QueryEngine` | 2 sa | `agenteval` 43/43, sohbet 28/29 ve üstü |
| 6 | Birleşik Frame Analyst şeması (`object_states`, `actions`, `allergens_seen`, `landmarks`) | `Extraction.swift`, `SafetyMonitor` girişi | 1 sa | `safetyeval` 12/12; ocak doğruluğu en az 19/20 |
| 7 | Arka plan segmentlerinin güvenlik ve ajana girmesi (A7) | `CaptureController.ingestBackgroundSegment` | 30 dk | Simülatörde 25 sn arka plan, ocak karesi, retrospektif uyarı |

Zaman kısıtlıysa 1–4 şart (agent hissinin %80'i). 5–7 demo sonrası yapılabilir.

---

## 8. Ölçülecekler (demo öncesi)

- `silence→sound` (telefon + gözlük): p50 < 1.5 sn hedef.
- Pik yük: 64 eşzamanlı istek altında P1 p90 < 2.5 sn.
- Uzun konuşma testi (yeni): 30 tur, 3 referans sorusu, bir uygulama yeniden başlatması.
- Proaktif testi: 10 dk kayıt, 5 tetik olayı (ocak, ilaç, niyet, rutin, rota), hepsi ya konuşuldu ya da gerekçesiyle `interventions` tablosunda.