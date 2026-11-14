# MUISTI Nemotron prompt'ları

Kaynak: `nemotron/extract.py` ve `nemotron/ask.py`. Bu dosya koddan otomatik çıkarıldı, metinler **birebir** aynı.
Makine tarafından okunabilir hali: `docs/prompts.json`.
Sürüm: **v18** (v17 + nesne başına `visibility` alanı; belirsiz nesneler kodda işaretlenir). Ürünle aynı okuyucuyla test (Apple Vision + yakınlaştırma, Mac'te): gözlük soru-cevap **30/31** (2 çalıştırma), 13 tuzak sorunun hepsinde "bilmiyorum", uydurma 0. Nesne testi (53 kare): kapsam %89–99, doğruluk %86–88, emin olunan nesnelerde doğruluk %90–93, afiş/ekran resmi 25/25.

## Telefon tarafı: yazı okuma (Apple Vision)

- Yazıyı **kutularıyla** gönderin: `POST /ingest` içinde `ocr_observations` = `[{text, conf, box:[x,y,w,h]}]` (0..1, sol üst köşe başlangıç). Düz metin (`ocr_text`) gönderilirse tabela satırlarını birleştirme çalışmaz.
- Vision ayarları `tools/vision_ocr.swift` ile aynı olmalı: `.accurate`, `usesLanguageCorrection = false`, `recognitionLanguages = ["en-US"]`, `minimumTextHeight = 0.015`.
- İsteğe bağlı yakınlaştırma: `tools/vision_ocr_zoom.swift` (yazı yerini bul → küçük yazıyı büyütüp tekrar oku). Testte 29/31 → 30/31. Telefonda hıza göre karar verilecek.
- Sunucu gelen satırları kendisi düzeltir (`ocr_adapter.py` + `ocr_repair.py`): kat yazıları ("STH FLOOR" → "5TH FLOOR"), yapışık kelimeler, iki satıra bölünmüş tabela değerleri.

## iOS'a taşırken mutlaka bilinmesi gerekenler

Prompt tek başına yetmiyor. Test sırasında model "OCR'da yoksa yazma" kuralını açıkça çiğnedi; yanlışları **kod** yakaladı. Aşağıdakiler olmadan aynı sonuç çıkmaz.

**İstek ayarları (Verda, OpenAI uyumlu):**
- `extra_body` / gövdede: `"chat_template_kwargs": {"enable_thinking": false}`
  - Reasoning varsayılan olarak açık ve `max_tokens`'ı yiyor; açık kalırsa `content` boş dönebiliyor.
  - Ölçtük: açıkken kare başına 6.3 sn, kapalıyken 0.44 sn, doğruluk farkı yok.
- `temperature`:
  - extraction: 0.2
  - soru ayrıştırma, cevap ve tekrar bakma: 0
  - geçici OCR: 0
- `response_format`: `{"type": "json_schema", "json_schema": {"name": "...", "schema": <aşağıdaki şema>}}`. Reddedilirse `{"type": "json_object"}` kullanın.
- `max_tokens`:
  - extraction: 2500 (nesneler ve resimler yüzünden 800 yetmiyor). Bozuk JSON gelirse bir kez temperature 0 ile tekrar dene; yine bozuksa son tam nesneden kesip parantezleri kapat (JSON onarımı).
  - soru ayrıştırma ve cevap: 400
  - tekrar bakma: 200
- Görüntü: uzun kenarı 1536 px'e küçültülmüş JPEG, `image_url` olarak data URL.
- **Mesaj sırası:** system → user mesajı (önce `OCR_LINES` metni, sonra görüntü). Few-shot yok.

**OCR satırları şu formatta verilmeli** (Apple Vision çıktısından):
```
OCR_LINES:
L01 5TH FLOOR
L02 7TH FLOOR  SAUNA AND POOL
L03 5TH FLOOR  ARDUINO HARDWARE LAB
```
- Satırlar yukarıdan aşağıya, aynı satırdaki kutular soldan sağa birleştirilmeli. Yan yana duran etiket ve değer tek satır olmalı.
  - Mantık `nemotron/ocr_adapter.py` içinde.
  - Vision'ın kutu orijini sol altta, dönüştürmeyi unutmayın.
- Yazı yoksa: `OCR_LINES:
(none)`.

**Few-shot YOK:** Örnek sahneler modeli yönlendiriyordu: olmayan asansör ve küllük ekliyor, yön tabelasındaki okları örnekten kopyalıyordu. Örnek kaldırılınca afiş/ekran resimleri de kayboldu. Bu yüzden prompt'un sonuna yazılı format notları (FORMAT NOTES) eklendi. iOS'ta da örnek gönderilmesin ama FORMAT NOTES mutlaka kalsın. Kod kuralları ölçümle gerekli çıktı: kapatılınca kostümlü insan yine "heykel" oldu.

**Kod tarafı kontroller** (`extract.py` içindeki `verify` ve `_clean_visual` fonksiyonları), cevap modelden döndükten sonra:
1. `name`, `phone` ve `hours` alanları, kendi `*_line` ID'sindeki OCR satırında geçmeli.
   - `name` en fazla 3 ardışık satıra yayılabilir.
   - Sayılar birebir eşleşmeli: "5TH" ile "7TH" eşleşmez.
   - Harfler küçük OCR hatalarını tolere eder.
2. `items` (kat → oda gibi eşleşmeler): etiket ve değer **aynı satırda** değilse reddedilir. Bu kural yanlış kat eşleştirmelerini 5'ten 0'a indirdi.
3. `objects`:
   - İnsan içeren isimler atılır.
   - Ayrıntısında neon/ışıklı tabela/logo geçen "screen" → "sign" olur (video/görüntü geçmiyorsa).
   - Ayrıntısında kostüm/sanatçı/maskot geçen statue/mannequin atılır (o bir insandır).
   - İsim kendi ayrıntısında geçmiyorsa ve ayrıntının başı bilinen başka bir nesneyi söylüyorsa ayrıntı kazanır: "ashtray | yellow wet floor sign" → wet floor sign, "car | silver taxi" → taxi, "vending machine | drink cooler" → drink cooler.
   - Çoğullar tekile çevrilir.
   - En fazla 15 tane tutulur.
   - `count` 1–50 arasına sıkıştırılır.
4. `relations`: listede olmayan bir nesneye atıf varsa atılır.
5. `depictions` içindeki şeyler gerçek nesne değildir, `objects`'e karıştırılmaz.

**Cevap tarafı kontroller** (`ask.py`):
- **Kanıt kontrolü:**
  - `quotes` içindeki her alıntı, atıf yapılan kanıtta geçmeli.
  - Cevaptaki her sayı kanıtta bulunmalı.
  - Biri tutmazsa cevap BILMIYORUM olur.
- **Yorum kontrolü:** `support == "inferred"` ise cevap verilmez. `observations` gösterilir ve etiket EMIN_DEGILIM olur. Asansör "4" hatası bununla düzeldi.
- **Görsel tekrar bakma:** Cevap sadece nesne veya resim kaydına dayanıyorsa:
  - Kayıtlı kareye `LOOK` sorusu sorulur.
  - Sorulan nesneye en çok benzeyen nesneyle başlanır, en fazla 3 kareye bakılır.
  - Hiçbiri `present:true` demezse cevap BILMIYORUM olur.
- **Ortam kontrolü:** Soru basılı bir ortam (poster/banner/billboard/tabela) sorup kanıt bir ekrandaysa (ya da tersi) düz "evet" denmez: "Poster değil, ama bir ekranda … gördüm".
- **Kodla verilen cevaplar:** Liste soruları ("hangi gaming stantlarını gördüm") modele değil koda cevaplatılır. Sadece kendi kaydında kategori geçen ve isimli olan kayıtlar sayılır.
- **"Şu an neredeyim / hangi kattayım":** kelime araması değil, son 3 dakikanın kayıtları kullanılır.

