# Muisti Ajan: sormadan fark eden, gerektiğinde konuşan taraf

**Temel kural:** Muisti yaşayan biri gibi davranır; kullanıcıdan girdi beklemez, kendi kararını verir. Kural ya da hatırlatma dikte edilmesi şart değildir: ilacı görürse "bugün aldın mı?" diye kendisi sorar. Konuşkan olabilir; sınırlar gevşektir. Değişmeyenler: söylediği gördüğüne dayanır, geri alınamayan işi sormadan yapmaz, tıbbi tavsiye vermez.

Soru-cevap hattı için `PIPELINE.md`'ye bakın. Bu belge `Muisti/Agent/` modülünü anlatır: Muisti'nin kullanıcı sormadan devreye girdiği yol.

## Akış

```
Olaylar ──► Durum ──► Tetik kademesi ──► Müdahale politikası ──► Eylem
kare/kayıt    nerede     telefonda hesap    ne kadar yüksek sesle,   sessiz kayıt
konum         nereye     embedding+rerank   ne zaman                 bildirim
hareket türü  niyetler   model hakemi                                kısa ses
saat/takvim   takvim                                                 cümle (+soru)
kullanıcı sözü
```

Model yalnız ucuz kontroller bir neden bulduğunda sorulur; söylediği cümle gösterilenlerle denetlenir; ne kadar yüksek sesle ve ne zaman söyleneceğine kod karar verir.

## Parçalar

| Dosya | İş |
|---|---|
| `AgentModels.swift` | `Intent` (hatırlatma, yapılacak, hedef, izleme, park, ajan notu), `Cue` (zaman / yer / görülecek şey / evden çıkış-varış), `NamedPlace`, `UserFact`, `Intervention`, `Mute`, `AgentCommand` |
| `AgentStore.swift` | `agent.sqlite`: `intents`, `places`, `facts`, `interventions`, `mutes`. Bellek veritabanının yanında, aynı dosya koruması |
| `AgentSettings.swift` | Aç/kapa, kategori anahtarları, günlük sesli bütçe, en az aralık, sessiz saatler |
| `InterventionPolicy.swift` | Tek kapı: Turva uyarıları dahil kendiliğinden söylenen her şey buradan geçer |
| `Notice.swift` | Hakem çağrısı (tool calling), araçları ve kanıt denetimi |
| `Places.swift` | Apple Haritalar araması, yön hesabı, `Navigator` (uzaklaşma / varış) |
| `CalendarReader.swift` | Sonraki 24 saatin etkinlikleri (izinle), takvime ekleme |
| `AgentNotifications.swift` | Bildirimler, zamanlı ve yere bağlı sistem hatırlatmaları, bildirim eylemleri |
| `AgentCenter.swift` | Hepsini bağlar: tetikler, komutlar, modele verilen durum metni, gün özeti |
| `AgentEval.swift` | Simülatör ölçümü (yalnız DEBUG) |

## Tetik kademesi

1. **Telefonda hesap (model yok)**, 15 saniyede bir (`AgentCenter.tick`):
   - zamanı gelen niyet (yazıldığı andaki cümleyle söylenir);
   - evden çıkış / varış ipucu;
   - yere bağlı niyet: kullanıcının adlandırdığı yer ya da Apple Haritalar'da 90 m içindeki eşleşme (150 m yürüdükçe yeniden aranır);
   - hedef: 30 saniyedir uzaklaşma ve en yakın noktadan 60 m öte → "yanlış yön"; 35 m içi → "vardın";
   - araç → yürüme geçişi (en az 60 s sürüş): yer "car" adıyla sessizce kaydedilir;
   - 15 dakika içinde başlayan takvim etkinliği;
   - 10 dakikada bir genel gözden geçirme (yalnız yakalama açıkken ve durum değiştiyse);
   - akşam özeti.
2. **Embedding + rerank** (`AgentCenter.matching`): "görünce" ipucu olan her niyetin sorgu vektörü, yeni zenginleşmiş kaydın vektörüyle karşılaştırılır (kosinüs ≥ 0,15 olanlar reranker'a gider; rerank ≥ −3,1 ise aday olur; reranker yoksa kosinüs ≥ 0,30).
3. **Dikkat işareti**: zenginleştirme çağrısı (zaten her karede yapılıyor) `attention` alanını doldurur: `none`, `warning`, `time_limited`, `schedule`, `price`, `event`, `document`, `person_badge`, `personal` (ilaç, anahtar, cüzdan gibi kişisel eşya; açık kalmış ocak, musluk, kapı). Ek çağrı yok.
4. **Hakem** (`Notice.judge`): yukarıdakilerden biri aday ürettiyse tek çağrı. Araçlar: `stay_silent`, `tell_user`, `note_for_later`, `complete_intent`, `save_place`, `offer_calendar_event`. Girdi: durum metni, olan şey, kaydın metni ve karesi, bellekte aynı şeyle ilgili eski kayıtlar (fiyat karşılaştırması buradan doğar), aday niyetler.
5. **Kanıt denetimi** (`Notice.check`): cümledeki her sayı ve modelin dayanak gösterdiği alıntı, modele gösterilen metinde olmalı; yoksa cümle söylenmez ve günlüğe "refused" yazılır. Konu bir niyetse, niyet oluşturulurken yazılmış cümle söylenir.

## Müdahale politikası

| Seviye | Ne | Kim |
|---|---|---|
| 0 | yalnız günlük | `fyi`, susturulmuş konu, süresi geçmiş, aynı konu son 5 dk içinde |
| 1 | bildirim | bütçe dolunca ya da sessiz saatte `timely`; geç işlenen kareler |
| 2 | kısa ses + bildirim | `useful`; son sesli müdahaleden beri en az aralık dolmadıysa |
| 3 | sesli cümle | `safety` (her zaman), `timely` |

- Günlük sesli bütçe (varsayılan 40) ve en az aralık (2 dk) güvenlik dışındakilere uygulanır; ayarlardan değişir.
- Araçtayken bekleyebilen müdahale tutulur; sürüş bitince söylenir, 2–5 dakikada bitmezse bildirime iner.
- Kullanıcı konuşurken hiçbir şey araya girmez; tur bitince, güvenlik en önde olacak şekilde söylenir (`VoiceAssistant.announce`).
- Bir konu art arda üç kez geri çevrilirse bir seviye sessizleşir.
- Her karar, susma kararları dahil, `interventions` tablosuna nedeniyle yazılır.

## Kullanıcının komutları (`AI/TurnTools.swift`)

`remember_intent`, `set_destination`, `cancel_destination`, `complete_intent`, `drop_intent`, `remember_fact`, `name_place`, `mute_topic`, `summarize_day`, `add_to_calendar`. `snooze_warning` ("şimdi değil") son söylenen ajanınsa ona uygulanır; `confirm_pending` / `cancel_pending` ajanın bekleyen sorusunu da cevaplar. `search_memory` artık zaman aralığı alır (`from`, `to`).

Ajanın notları (açık niyetler, hedef, adlı yerler, kullanıcının söyledikleri, takvim, son müdahale) hem tur kararına hem cevaba verilir: "arabam nerede", "ne alacaktım" ek kod olmadan cevaplanır.

## Onay kuralı

Onaysız: yalnız Muisti'nin kendi belleğine yazan ve geri alınabilen işler (niyet, not, park yeri). Kullanıcı kendisi "takvime ekle" derse eklenir; ajan kendiliğinden yalnız sorar, "evet" gelmeden eklemez. Arama, mesaj, satın alma yok.

## Gizlilik

- İnsanlarla ilgili notlar varsayılan kapalı; açıkken de yalnız yaka kartı ya da kartvizitten okunan metin kullanılır. Yüz tanıma ve duygu çıkarımı yok.
- Takvim okuma varsayılan kapalı. Açılırsa etkinlik başlığı, saati ve yeri modele gider.
- Niyet metinleri ve kullanıcının söyledikleri modele gider; yer adları Apple Haritalar'a gider (kapatılabilir).
- "Son N dakikayı unut" ajan tablolarını da siler; günlük ve bitmiş niyetler saklama süresine uyar.

## Uygulama kapalıyken

- Zamanlı ve yere bağlı niyetlerin birer sistem bildirimi vardır; Muisti kapalıyken de gelir. Muisti çalışıyorsa kendi söyler ve sistemdeki kopyayı kaldırır.
- Kullanıcı "Her zaman" konum izni verirse (`BackgroundRuntime`): belirgin yer değişimi, bir yere varış/ayrılış ve niyetlerin bekleyen yerlerine giriş (en çok 18 bölge) uygulamayı arka planda uyandırır; bir ajan turu koşar ve gerekirse bildirim atar. Arka plan yenilemesi (yaklaşık 15 dakikada bir, sistemin izin verdiği sıklıkta) takvimi kontrol eder.
- Kareye dayalı her şey yalnız yakalama açıkken çalışır.

## Ekran

Ayarlar › Assistant › "Reminders, places and what Muisti said" (`UI/Agent/AgentNotesView.swift`): açık niyetler (kaydırarak bitir / sil), adlı yerler, kullanıcının söyledikleri ve Muisti'nin kendiliğinden söylediği ya da sustuğu her şeyin günlüğü, nedeniyle.

## Kendiliğinden kolladıkları

Zenginleştirmenin işaretine ek olarak üç sabit "görünce" ipucu her karede embedding + rerank ile denenir (`AgentCenter.standing`): yakından görülen ilaç, bırakılmış kişisel eşya, evde açık kalan şey. Eşleşirse hakem, notlara ve güvenlik günlüğüne bakıp söyler ya da sorar.

## Yapılmayanlar

- Pusula yönü kullanılmıyor; "sağında / arkanda" GPS rotasından hesaplanıyor, dururken pusula yönü ("kuzeyde") verilir.
- Toplu taşıma, fiş/garanti, son kullanma tarihi için ayrı kod yok; hakem + `note_for_later` bunları kapsıyorsa çalışır, ölçülmedi.
- Akşam özeti yalnız o saatte uygulama çalışıyorsa üretilir.
- Eylem algılama (ocağı kapattı mı, ilacı aldı mı) hâlâ tek kareye bakıyor; art arda karelerden şerit denenmedi (elde eylem içeren görüntü yok).
- Arka plan uyanmaları (bölge, ziyaret, yenileme) simülatörde tetiklenemedi; yalnız derlendi.

## Ölçüm

Aşağıdaki sayılar simülatörde `agenteval` ile alınır (`--script-only=waitidle@0,agenteval@1`).

### 14 Kasım, simülatör (73 kayıtlı test belleği)

| Adım | Sonuç |
|---|---|
| Tur kararı, 13 istek (niyet, hedef, bilgi, güvenlik kuralı, gün özeti, Türkçe istek, bellek sorusu) | 13/13 doğru araç; karar 0,2–0,9 s |
| Zamanlı hatırlatma | vaktinden önce sessiz, vaktinde bir kez |
| Politika (bütçe, aralık, susturma, güvenlik) | 5/5 |
| Yön hesabı (yaklaşma, uzaklaşma, varış) | 3/3 |
| "Eczane görünce söyle" niyeti: 5 eczane karesi | 5/5 söylendi |
| Aynı niyet: 40 başka kare | 0 yanlış alarm |
| Niyet yokken 25 sıradan kare | 5'i işaretlendi, 0–1'i söylendi (iki koşu) |
| Girdi olmadan karar (7 fotoğraf: ilaç, yanan ocak, kapalı ocak, anahtar, TV, tabela) | 6/7; yakın çekim bir ilaç blisteri işaretlenmedi |
| Hakem çağrısı süresi | 0,3–1,9 s |
| Sohbet gerilemesi (29 tur) | 28/29, öncekiyle aynı |

Ölçülmeyenler: gerçek gözlükle saha, yere bağlı niyet (Apple Haritalar araması), yanlış yön uyarısının gerçek GPS ile davranışı, park algılama, takvim, bildirim eylemleri, bellek testi (68 soru) zenginleştirme istemi değiştikten sonra. İşaret (`attention`) aynı karede koşudan koşuya değişebiliyor.
