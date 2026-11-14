import json, os, sys, urllib.parse, urllib.request, urllib.error
UA = {"User-Agent": "muisti-eval/0.1 (research script)"}
TOPICS = {
 "q_red_sofa": "red sofa living room", "q_basketball_hoop": "basketball hoop outdoor", "q_qr_code": "QR code poster",
 "q_bicycle": "bicycle parked street", "q_fire_extinguisher": "fire extinguisher wall", "q_traffic_light": "traffic light street",
 "q_coffee_cup": "coffee cup table", "q_umbrella": "umbrella rain street", "q_laptop": "laptop on desk", "q_dog": "dog on leash street",
 "d_kitchen": "kitchen interior", "d_bus_stop": "bus stop Helsinki", "d_shop_shelf": "supermarket shelf", "d_office": "office interior desk",
 "d_park": "park bench trees", "d_tram": "tram Helsinki", "d_bookshelf": "bookshelf library", "d_stairs": "staircase building interior",
 "d_corridor": "corridor school", "d_shopfront": "shop front Helsinki street",
}
import time
def get(url):
    for a in range(5):
        try:
            time.sleep(1.5)
            return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read()
        except urllib.error.HTTPError as e:
            if e.code != 429: raise
            time.sleep(10 * (a + 1))
    raise RuntimeError("rate limited")
for key, q in TOPICS.items():
    if len([f for f in os.listdir("img") if f.startswith(key + "_")]) >= 3: continue
    api = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode({"action": "query", "generator": "search",
        "gsrsearch": "filetype:bitmap " + q, "gsrnamespace": 6, "gsrlimit": 12, "prop": "imageinfo", "iiprop": "url|mime",
        "iiurlwidth": 512, "format": "json"})
    pages = json.loads(get(api)).get("query", {}).get("pages", {})
    n = 0
    for p in sorted(pages.values(), key=lambda p: p.get("index", 0)):
        ii = (p.get("imageinfo") or [{}])[0]
        if ii.get("mime") not in ("image/jpeg", "image/png") or "thumburl" not in ii: continue
        try:
            data = get(ii["thumburl"])
        except Exception as e:
            continue
        open(f"img/{key}_{n}.jpg", "wb").write(data); n += 1
        if n == 3: break
    print(key, n)
