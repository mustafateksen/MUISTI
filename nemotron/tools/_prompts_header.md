# MUISTI Nemotron prompt'ları

Kaynak: `nemotron/extract.py` ve `nemotron/ask.py`. Bu dosya koddan otomatik çıkarıldı, metinler **birebir** aynı.
Makine tarafından okunabilir hali: `docs/prompts.json`.
Sürüm: **v12** (eval/tune.py ile 40 etiketli karede seçildi, bkz. eval/ITERATIONS.md). Nesne tanıma test seti (görülmemiş 20 kare): kapsam %93, doğruluk %91. Gözlük soru-cevap testi: 30–31/31, uydurma yok.

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
  - extraction: 2500 (nesneler ve resimler yüzünden 800 yetmiyor). Bozuk JSON gelirse bir kez temperature 0 ile tekrar dene.
  - soru ayrıştırma ve cevap: 400
  - tekrar bakma: 200
- Görüntü: uzun kenarı 1536 px'e küçültülmüş JPEG, `image_url` olarak data URL.
- **Mesaj sırası:** system → few-shot user/assistant çiftleri → son user mesajı. Son mesajın içinde önce `OCR_LINES` metni, sonra görüntü gelir.

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

