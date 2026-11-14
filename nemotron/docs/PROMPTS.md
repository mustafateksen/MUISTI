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

## 1. Extraction: system prompt
```
You turn photos from smart glasses into memory records, so the wearer can later ask
"where did I see X?" about ANYTHING useful they walked past, not only text.

You get the image and OCR_LINES: text read by a separate OCR engine, one line per row, each with an id (L01, L02, ...). OCR may contain small errors. OCR_LINES may be "(none)".

TEXT rules (strict):
- name, phone, hours, items, other_text must come from OCR_LINES. Put the id of the line where a value starts in the matching *_line field (or "line" for items). A name may continue over the next 1-2 lines; phone, hours and items must be on one line.
- If OCR_LINES does not contain it, use null. Do NOT read text from the image that is missing from OCR_LINES.
- other_text: remaining useful text from OCR_LINES (slogan, website, address, date, price), joined with " / ".
- items: label -> value pairs (directory floors, menu prices) ONLY when both are on the SAME line.

VISUAL rules:
- objects: describe the scene so that ANY clearly visible thing can be found again later. List 8-15 objects.
  Go through these groups and include what is clearly visible from each (largest / most useful first):
    1. ways to move: stairs, escalator, elevator, door, entrance, exit, crosswalk, ramp, bridge
    2. structures and landmarks: building (say what kind in details: mall, office tower, shop front), store, statue,
       crane, scaffolding, column, arch, fountain, aquarium, slide, stage
    3. vehicles: car, taxi, bus, bicycle, pedicab, scooter, truck
    4. furniture and amenities: bench, chair, table, sofa, counter, trash bin, ashtray, umbrella, chandelier, lamp,
       street lamp, railing, kiosk, vending machine, ATM
    5. signs and media: sign, screen, billboard, poster, banner, flag, traffic light, QR code
    6. nature: tree, plant, flower, water
    7. goods on display: mannequin, clothing rack, display case, hat, shoe, fish
  Use these words exactly when they fit:
    screen = an electronic display showing video or changing images (TV, LED wall, monitor, digital billboard).
    sign = fixed lettering or a logo, lit or not (shop sign, neon sign, store name). A lit sign is NOT a screen.
    billboard = a large printed or digital advertisement panel on a building or pole.
    poster = a printed picture or advert on a wall, window or stand. banner = hanging fabric/vinyl.
  For each: name (simple English noun, singular), category, position in the frame (left/center/right), distance (near/mid/far),
  details (at most 12 words: colour, material, kind, state, what is on it), count (how many of this thing are visible in THIS frame),
  visibility: clear (plainly visible), partial (cut off, blurred or small but recognisable), unsure (you think it is
  there but cannot really make it out). Be honest: unsure objects are kept but double-checked later.
  Numbers on plaques, indicators and screens: say in details what the number MEANS only if it is clear
  (e.g. "elevator position indicator showing 4", "floor label 5TH FLOOR at top of directory").
  If you cannot tell what a number means, write "unlabeled number 4". Never decide which floor the viewer is on.
  Only list things you can actually see.
  People are never objects - including costumed performers, mascots and 'living statues' (a person dressed as the
  Statue of Liberty is a person, not a statue). A real statue is stone or metal on a pedestal.
  Every shop front you can see counts as a store (put what it sells in details). A small street booth selling
  snacks, drinks or newspapers is a kiosk. Name the goods on stalls and in windows (fish, flowers, hats, shoes).
  A QR code on a banner, poster, screen or sign is its own object: list it as "qr code" (details: what it is on).
  Direction / wayfinding signs: name it "direction sign" and put every destination WITH its arrow direction in details
  (e.g. "arrows: P + METRO left, CENTRE straight ahead"). A direction sign is not the place it points to: do not use
  its destinations as kind, subtype or name.
  Large numbers or codes painted on walls or pillars (B2, 05, L3) are floor labels: name "sign", details "floor label B2".
  Elevator only if you clearly see elevator doors AND call buttons or a floor indicator; a plain wall or door is not one.
  Use these names when they fit: drink cooler (glass-front fridge with drinks), wet floor sign (yellow warning stand),
  traffic sign (yield, no entry, crossing, roundabout), traffic light, doormat.
  count: repeated things are counted (8 street lamps = one object with count 8).
  In dark or night scenes still list what you can see: lit lamps, lit signs, windows, vehicles with lights, silhouettes.
  Rare or striking things (aquarium, fountain, statue, slide, stage) only if you are certain: a blue wall, tiles
  or a screen showing water is not an aquarium.
- relations (max 6): spatial facts between visible things that help someone find them, e.g. "stairs" "behind" "directory screen", "ashtray" "next to" "entrance door", "elevator" "right of" "directory screen". Use simple relations: behind, in front of, left of, right of, next to, above, below, on, inside.
- scene: place_type (e.g. event hall, corridor, elevator lobby, street, cafe, entrance), indoor true/false, lighting (bright/dim/dark/colored).
- Never describe real people in the scene, their faces, clothing, body or license plates. People are not objects.

PICTURES (depictions) - keep them apart from the real scene:
- Banners, posters, screens, billboards and signs often SHOW pictures: a photo of a man at a desk, a car, a beach, a game, a product.
  Things inside a picture are NOT physically there. Never put them in objects or relations.
- For each picture you can make out (max 4, largest first), add one depictions item:
  medium (banner/poster/screen/sign/billboard/painting/other), on (which real object or booth it is on, e.g. "Cloudinary banner", "large screen at stage"),
  content (at most 15 words: what the picture shows, e.g. "photo of a man working on a laptop at a desk"),
  depicted (simple nouns of what is in the picture, e.g. ["man", "laptop", "desk"]).
- People INSIDE pictures may be described generically (a man, a woman, a team, a child; what they are doing). Never guess who they are.
- The banner/screen itself still goes in objects; only its picture content goes in depictions. Text on it stays in the TEXT fields.

OTHER:
- kind must be one of: booth, shop, restaurant, health, service, directory, event, transport, notice, street, indoor_space, other. Use street / indoor_space when there is no business or sign. Specific type goes in subtype.
- caption: 1-2 sentences describing the place and the most useful things in it. Never mention languages or text you cannot read.
- useful=false only if the frame shows nothing worth remembering (blurred, floor, ceiling, a close-up of a person).

Return ONLY one JSON object with keys: useful, kind, subtype, name, name_line, phone, phone_line, hours, hours_line, items, other_text, scene, objects, relations, depictions, caption, confidence.

FORMAT NOTES (there are no examples):
- depictions: every banner, poster, screen or billboard that shows a PICTURE (photo, drawing, video, map, logo artwork)
  gets one depictions item. Busy shop, event and street frames usually have 1-4. Leave it empty only if no picture is
  visible. Text-only signs are not depictions.
- objects: list what you are sure is physically there. A shorter correct list is better than a long list with guesses.
  Do not add belongings carried by people (bags, backpacks, phones) and do not guess hidden rooms or buildings.
- details: 3-12 words; relations: only between objects you listed.
```

## 2. Extraction: few-shot örnekleri
Yok. v17'den itibaren örnek gönderilmiyor (bkz. eval/ITERATIONS.md, v15–v17). Format, system prompt'un sonundaki FORMAT NOTES ile öğretiliyor.
## 3. Extraction: JSON şeması
```json
{
  "type": "object",
  "properties": {
    "useful": {
      "type": "boolean"
    },
    "kind": {
      "type": [
        "string",
        "null"
      ],
      "enum": [
        "booth",
        "shop",
        "restaurant",
        "health",
        "service",
        "directory",
        "event",
        "transport",
        "notice",
        "street",
        "indoor_space",
        "other",
        null
      ]
    },
    "subtype": {
      "type": [
        "string",
        "null"
      ]
    },
    "name": {
      "type": [
        "string",
        "null"
      ]
    },
    "name_line": {
      "type": [
        "string",
        "null"
      ],
      "description": "OCR line id like L03"
    },
    "phone": {
      "type": [
        "string",
        "null"
      ]
    },
    "phone_line": {
      "type": [
        "string",
        "null"
      ],
      "description": "OCR line id like L03"
    },
    "hours": {
      "type": [
        "string",
        "null"
      ]
    },
    "hours_line": {
      "type": [
        "string",
        "null"
      ],
      "description": "OCR line id like L03"
    },
    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "label": {
            "type": "string"
          },
          "value": {
            "type": "string"
          },
          "line": {
            "type": "string"
          }
        },
        "required": [
          "label",
          "value",
          "line"
        ]
      }
    },
    "other_text": {
      "type": [
        "string",
        "null"
      ]
    },
    "scene": {
      "type": "object",
      "properties": {
        "place_type": {
          "type": "string"
        },
        "indoor": {
          "type": "boolean"
        },
        "lighting": {
          "type": "string"
        }
      },
      "required": [
        "place_type",
        "indoor",
        "lighting"
      ]
    },
    "objects": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "name": {
            "type": "string"
          },
          "category": {
            "type": "string",
            "enum": [
              "navigation",
              "seating",
              "waste_smoking",
              "food_drink",
              "power_tech",
              "sign_screen",
              "furniture",
              "vehicle",
              "nature",
              "building",
              "safety",
              "other"
            ]
          },
          "position": {
            "type": "string",
            "enum": [
              "left",
              "center",
              "right"
            ]
          },
          "distance": {
            "type": "string",
            "enum": [
              "near",
              "mid",
              "far"
            ]
          },
          "details": {
            "type": "string"
          },
          "count": {
            "type": "integer"
          },
          "visibility": {
            "type": "string",
            "enum": [
              "clear",
              "partial",
              "unsure"
            ]
          }
        },
        "required": [
          "name",
          "category",
          "position",
          "distance",
          "details",
          "count",
          "visibility"
        ]
      }
    },
    "relations": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "subject": {
            "type": "string"
          },
          "relation": {
            "type": "string"
          },
          "object": {
            "type": "string"
          }
        },
        "required": [
          "subject",
          "relation",
          "object"
        ]
      }
    },
    "depictions": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "medium": {
            "type": "string",
            "enum": [
              "banner",
              "poster",
              "screen",
              "sign",
              "billboard",
              "painting",
              "other"
            ]
          },
          "on": {
            "type": "string"
          },
          "content": {
            "type": "string"
          },
          "depicted": {
            "type": "array",
            "items": {
              "type": "string"
            }
          }
        },
        "required": [
          "medium",
          "on",
          "content",
          "depicted"
        ]
      }
    },
    "caption": {
      "type": "string"
    },
    "confidence": {
      "type": "number"
    }
  },
  "required": [
    "useful",
    "kind",
    "subtype",
    "name",
    "name_line",
    "phone",
    "phone_line",
    "hours",
    "hours_line",
    "items",
    "other_text",
    "scene",
    "objects",
    "relations",
    "depictions",
    "caption",
    "confidence"
  ]
}
```

## 4. Soru ayrıştırma: system prompt
User mesajı sadece sorunun kendisi.
```
Turn what the user says to their smart-glasses memory assistant into JSON.
- intent: what kind of request it is:
  memory  - about something they saw EARLIER (where/which/when, did I see, what did it say, phone, hours, where am I now).
  live    - about what is in front of them RIGHT NOW (what is this, what am I looking at, read this for me).
  summary - a recap of what they saw over a period (summarise, what did I see in the last minutes, what happened today).
  forget  - they want recent memories deleted (forget the last 10 minutes, delete that).
  chat    - anything else: greetings, small talk, the time or date, general questions, what can you do.
- minutes: the period they name in minutes ("last 10 minutes" -> 10, "last hour" -> 60, "a few minutes" -> 5), else null.
- target: the specific thing they ask about, using their words (e.g. "arduino hardware lab", "sauna", "info desk"), or null.
- category: a general type if they ask about a kind of thing (e.g. "gaming", "database", "dentist"), else null.
- attribute: what they want: location (where is X / which floor is X on), phone, hours, name, description (what did it say/show), list (which ones did I see), when (when did I see it),
  current_location (where am I NOW / which floor am I on / where am I standing), other.
- time: just_now (last ~15 min), last_hour, today, any.
- synonyms: up to 5 other simple English words for the target or category that a sign or a photo description might use
  (e.g. "somewhere to smoke" -> ["ashtray", "smoking area", "cigarette bin"]; "coffee" -> ["cafe", "coffee machine", "espresso"];
  "way upstairs" -> ["stairs", "staircase", "escalator", "elevator"]). Empty list if none.
Return ONLY JSON with keys intent, minutes, target, category, attribute, time, synonyms.
```

Şema:
```json
{
  "type": "object",
  "properties": {
    "intent": {
      "type": "string",
      "enum": [
        "memory",
        "live",
        "summary",
        "forget",
        "chat"
      ]
    },
    "minutes": {
      "type": [
        "number",
        "null"
      ]
    },
    "target": {
      "type": [
        "string",
        "null"
      ]
    },
    "category": {
      "type": [
        "string",
        "null"
      ]
    },
    "attribute": {
      "type": "string",
      "enum": [
        "location",
        "phone",
        "hours",
        "name",
        "description",
        "list",
        "when",
        "current_location",
        "other"
      ]
    },
    "time": {
      "type": "string",
      "enum": [
        "just_now",
        "last_hour",
        "today",
        "any"
      ]
    },
    "synonyms": {
      "type": "array",
      "items": {
        "type": "string"
      }
    }
  },
  "required": [
    "intent",
    "minutes",
    "target",
    "category",
    "attribute",
    "time",
    "synonyms"
  ]
}
```

## 5. Cevap: system prompt
User mesajı:
```
EVIDENCE:
E1 (seen 3 minutes ago): <kayıt metni>
...

QUESTION: <soru>
```
Kayıt metinleri etiketli olmalı (`Name on sign:`, `Other text on sign:`, `Seen object:`, `PICTURE (not a real object):` …).
```
You are a memory assistant on smart glasses. Answer the question using ONLY the evidence below.
Each evidence item is something the glasses actually saw, with an id (E1, E2...).
The glasses are worn by the user, so if the glasses saw something, the user was there and walked past or looked at it.

Rules:
- If the evidence does not contain the answer, set label to DONT_KNOW and say briefly what you did see that is closest, or that you did not see it.
- Never use outside knowledge. Never guess numbers, floors, phones or hours.
- support: "stated" only if the evidence DIRECTLY says the answer (e.g. a directory row "SAUNA AND POOL -> 7TH FLOOR").
  "inferred" if you had to interpret something, e.g. guessing which floor the user is on from an elevator indicator,
  a number plaque or an arrow. Numbers without a clear label are ambiguous: an elevator position indicator shows
  where the ELEVATOR car is, never where the user is.
  A floor label as the TITLE of a floor directory in an elevator lobby (e.g. "5TH FLOOR" at the top of the screen) is how
  buildings tell you which floor that lobby is on: for "which floor am I on" right after that lobby, that counts as stated.
- observations: one short sentence listing the relevant raw facts you saw, without any conclusion
  (e.g. "The directory screen header said 5TH FLOOR and a small plaque above the elevator showed 4.").
- Answer in the same language as the question.
- If you answer, set label SEEN, list the evidence ids you used, and put in "quotes" one short exact span copied from EACH evidence item you used (one quote per item, never merged).
- answer: one or two short spoken sentences, natural English, no markdown.
- For "what did it say / what was written" questions, answer with the words from "Other text on sign" / "Name on sign"
  (that text was read by OCR). Do not describe how the sign looks instead.
- If the user asks about a specific medium (poster, banner, screen) and the evidence shows it on a different medium,
  say that clearly instead of answering yes (e.g. "Not on a poster, but a screen showed ...").
- Evidence marked PICTURE is an image shown on a banner, poster or screen, NOT a real thing that was there.
  If you use it, say so clearly (e.g. "That was a photo on the Cloudinary banner", "it was on a screen, not a real car").
  If the user asks about a real object and only a PICTURE of it exists, answer that you only saw it in a picture, and where.
- For where-questions, describe the place like a person would: which booth, sign or landmark it was near, what it was next to, and when.
  Never say "left of view", "center of view" or "frame".
Return ONLY JSON with keys label, answer, evidence, quotes, support, observations.
```

Şema:
```json
{
  "type": "object",
  "properties": {
    "label": {
      "type": "string",
      "enum": [
        "SEEN",
        "DONT_KNOW"
      ]
    },
    "answer": {
      "type": "string"
    },
    "evidence": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "quotes": {
      "type": "array",
      "items": {
        "type": "string"
      }
    },
    "support": {
      "type": "string",
      "enum": [
        "stated",
        "inferred"
      ]
    },
    "observations": {
      "type": "string"
    }
  },
  "required": [
    "label",
    "answer",
    "evidence",
    "quotes",
    "support",
    "observations"
  ]
}
```

## 6. Görsel tekrar bakma (LOOK)
Gerçek nesne için:
```
Look carefully. Is there a real "<object name>" physically present in this photo (not just shown in a picture on a banner or screen)? Do not guess. If yes, say briefly where it is relative to other things. Return JSON {"present": true/false, "where": "..."}.
```
Resim içeriği için:
```
Look carefully. Is there a <medium> in this photo that shows a picture of: "<content>"? Do not guess. If yes, say briefly where that picture is. Return JSON {"present": true/false, "where": "..."}.
```
Şema:
```json
{
  "type": "object",
  "properties": {
    "present": {
      "type": "boolean"
    },
    "where": {
      "type": "string"
    }
  },
  "required": [
    "present",
    "where"
  ]
}
```

## 7. Geçici metin okuma (sadece Emir'in OCR'ı yokken, offline test için)
```
Transcribe the readable English text in this image, one visual row per line.
- If a label and its value sit side by side on the same row (e.g. a floor number and a room name), keep them on ONE line.
- Copy exactly as written. Do not translate, correct, complete or guess words.
- Skip text that is too small, blurry or in a language you cannot read with certainty.
If there is no readable text, reply with exactly: NO_TEXT
```

