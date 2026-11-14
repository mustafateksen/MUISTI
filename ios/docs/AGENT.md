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

## Yön tarifi

iOS, başka bir uygulamada (Apple Haritalar, Google Haritalar) çalışan navigasyonu okumaya izin vermiyor; Even Realities ve Meta da kendi rotalarını hesaplıyor. Muisti de öyle yapıyor (`RouteGuide.swift`): kullanıcı "X'e gidiyorum" deyince hedef bulunur, Apple'ın yol tarifi servisinden (`MKDirections`, yürüyüş) rota istenir ve:

- rota hazır olunca özet söylenir ("Kiasma: 300 m, yürüyerek 5 dk. Elielinaukio'dan başla");
- her dönüş, kullanıcı 28 m yaklaşınca Apple'ın kendi cümlesiyle söylenir ("30 m sonra: Mannerheimintie'ye sağa yönel");
- rotadan 45 m'den fazla ve art arda 3 konum boyunca çıkılırsa yeni rota istenir ("Yeni rota: 660 m, 9 dk");
- varışta söylenir ve hedef kapanır.

Bu cümleler günlük bütçeye ve aralık kuralına takılmaz (kullanıcının beklediği şey); sessiz saatler ve susturma geçerlidir. Rota bilgisi modele de verilir: "nerede döneceğim", "ne kadar kaldı" soruları buradan cevaplanır. Rotası bulunamayan hedefte eski davranış sürer (uzaklaşınca yönüyle söylenir, tabelası görülürse söylenir).

## Pipeline v2'de değişenler (15 Kasım)

Ayrıntı ve tablo: `PIPELINE.md` §9. Ajan tarafı için özet:
- **Hiçbir kayıt düşmüyor:** hakem meşgulken gelen kayıtlar sıraya girer (`waitingNotices`, en çok 40); her biri ya söylenir ya da gerekçesiyle `interventions` tablosuna "sustu" diye yazılır. Testte aynı anda gelen 5 işaretli kaydın 5'i de yargılandı.
- **Hakem konuşmayı okuyor:** soru hattının okuduğu aynı bağlam (özetler, Muisti'nin kendi notları, bugünün son turları) hakemin istemine de girer. Kullanıcı "toplantıdayım" derse model bunu `note_to_self` ile süreli not olarak tutar; sonraki her tur ve her hakem çağrısı onu görür.
- **Karar öncesi bakabiliyor:** hakem artık `find_in_memory`, `object_state`, `safety_log`, `recall_dialog`, `route_status`, `calendar`, `places` araçlarıyla bakıp sonra karar veriyor (en çok 3 model çağrısı; son adımda yalnız karar araçları). Baktıkları, söylediği cümlenin kanıt denetiminde gösterilmiş sayılır.
- **Geç kareler:** telefon ceptayken kaydedilen ya da kuyrukta beklemiş kare "o saatten bir kare" notuyla yargılanır; önemi sürüyorsa "00:44'te ocağı yanık gördüm, hâlâ açık mı?" diye geriye dönük sorulur, canlı uyarı olarak seslendirilmez.
- **Periyodik bakış** 2 dakikada bir (durum değiştiyse); susma kararları konuşma akışına `system_note` olarak yazılır.

## Kendiliğinden kolladıkları

Zenginleştirmenin işaretine ek olarak dört sabit "görünce" ipucu her karede embedding + rerank ile denenir (`AgentCenter.standing`): yakından görülen ilaç, bırakılmış kişisel eşya, evde açık kalan şey, yürünen yerdeki tehlike (ıslak zemin levhası, kırmızı yaya ışığı, bisiklet yolu, kazı). Eşleşirse hakem, notlara ve güvenlik günlüğüne bakıp söyler ya da sorar. Tehlike ipucu yalnız kare 20 saniyeden yeniyse hakeme gider.

## Rutinler

`Habits` (yeni dosya) güvenlik günlüğünün son 14 gününü sayar: aynı kayıt (nesne + değer, ör. "medicine taken", "front door locked") önceki günlerin en az 3'ünde ve günlük tutulan günlerin en az yarısında varsa alışkanlık sayılır; ilk görülme saatlerinin en erkeni ve en geçi "olağan aralık"tır. Kod neyin ilaç neyin kapı olduğunu bilmez, günlükte ne varsa onu sayar. Olağan saat 30 dakika geçtiği halde bugün kayıt yoksa bu, ajanın periyodik bakışını (`review`) tetikler; satırlar hakeme verilir ve ne diyeceğine hakem karar verir (istem: yapmadığını iddia etme, soru olarak sor; gözlük görmemiş olabilir). Aynı satırlar akşam özetine de girer. Sürücüde `log` komutu geçmiş günlere kayıt ekler (demo verisi), `habits` satırları gösterir, `tick --review` bakışı hemen çalıştırır.

## Gizlilik kapısı

Özel sahneden sonraki 20 saniye boyunca hiçbir kare tutulmaz (sınıflandırıcı aynı odanın bazı açılarını kaçırıyor; her özel kare süreyi yeniden başlatır; `PerceptionEngine.privatePause`). Banyo, tuvalet ya da duş sahnesi gösteren kare telefondan çıkmaz ve kaydedilmez (`PerceptionEngine.showsPrivateScene`, Apple'ın telefondaki sahne sınıflandırıcısı; fikir Android tarafından). Bellek, güvenlik bakışı ve canlı bakış aynı kapıdan geçer. Mac'te aynı Vision isteğiyle: 11 banyo fotoğrafının 8'i 0,45–0,97 puan aldı (eşik 0,40), 106 sıradan test fotoğrafının en yükseği 0,27. Simülatörde sınıflandırıcı çalışmadığı için orada kapı kapalıdır; telefonda sınıflandırıcı hata verirse kare geri çevrilir.

## Yapılmayanlar

- Pusula yönü kullanılmıyor; "sağında / arkanda" GPS rotasından hesaplanıyor, dururken pusula yönü ("kuzeyde") verilir.
- Toplu taşıma, fiş/garanti, son kullanma tarihi için ayrı kod yok; hakem + `note_for_later` bunları kapsıyorsa çalışır, ölçülmedi.
- Akşam özeti yalnız o saatte uygulama çalışıyorsa üretilir.
- Eylem algılama (kapıyı kilitledi mi, ocağı kapattı mı, ilacı aldı mı) art arda karelerden şeritle yapılıyor ve cevap kareleriyle doğrulanıyor, ama gerçek eylem görüntüsüyle ölçülmedi (elde eylem içeren çekim yok).
- Rutinler yalnız güvenlik günlüğünden sayılıyor; bellekteki kayıtlardan ("3 gündür sebze görmedim") rutin çıkarılmıyor.
- Arka plan uyanmaları (bölge, ziyaret, yenileme) simülatörde tetiklenemedi; yalnız derlendi.

## Ölçüm

Aşağıdaki sayılar simülatörde `agenteval` ile alınır (`--script-only=waitidle@0,agenteval@1`).

### 14 Kasım, simülatör (73 kayıtlı test belleği, son koşu)

| Adım | Sonuç |
|---|---|
| Tur kararı, 13 istek (niyet, hedef, bilgi, güvenlik kuralı, gün özeti, Türkçe istek, bellek sorusu) | 13/13 doğru araç; karar 0,2–0,9 s |
| Zamanlı hatırlatma | vaktinden önce sessiz, vaktinde bir kez |
| Politika (bütçe, aralık, susturma, güvenlik) | 5/5 |
| Yön hesabı (yaklaşma, uzaklaşma, varış) | 3/3 |
| "Eczane görünce söyle" niyeti: 5 eczane karesi | 5/5 söylendi |
| Aynı niyet: 40 başka kare | 0 yanlış alarm; 45 kareden yalnız 5'i hakeme gitti |
| Niyet yokken 25 sıradan kare | 8'i işaretlendi, 0'ı söylendi |
| Girdi olmadan karar (7 fotoğraf: 2 ilaç, yanan ocak, kapalı ocak, anahtar, TV, tabela) | 7/7 |
| Yere bağlı niyet, sahte GPS + gerçek Apple Haritalar | market bulundu, 80 m'de söylendi |
| Hedef, sahte GPS | uzaklaşınca yönüyle söylendi, varınca söylendi ve kapandı |
| Park (araç → yürüme) | yer "car" olarak kaydedildi |
| Takvim (9 dakika sonraki etkinlik) | okundu ve söylendi |
| Bildirim düğmeleri (Tamam / Sonra / Bir daha söyleme) | 3/3 |
| Hakem çağrısı süresi | 0,3–1,9 s |
| Toplam | 43/43 kontrol (tam koşu), 41/41 (hızlı koşu, son sürüm) |
| Sohbet gerilemesi (29 tur) | 28/29, öncekiyle aynı |
| Bellek testi (68 soru), yeni zenginleştirme istemiyle baştan işlenmiş | 66/68 · olumsuz 10/11 · recall@1/3/8 49/59/63 · p50 4,8 s (o saatte uç yavaştı); 73 karenin işlenmesi sırasında ajan 0 kez konuştu |

Ölçülmeyenler: gerçek gözlükle saha; arka plan uyanmaları (bölge, ziyaret, yenileme); kare şeridiyle eylem algılama (elde eylem içeren görüntü yok); akşam özeti zamanlaması. İşaret (`attention`) aynı karede koşudan koşuya değişebiliyor; bu yüzden kişisel eşya için sabit eşleştirme de var.
