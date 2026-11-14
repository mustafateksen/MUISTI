import json, os, sys, numpy as np, onnxruntime as ort, urllib.request
from tokenizers import Tokenizer
from PIL import Image
M = sys.argv[1]; KEY = os.environ["VKEY"]
tok = Tokenizer.from_file(M + "/tokenizer.json"); tok.no_padding(); tok.no_truncation()
tm = ort.InferenceSession(M + "/text_model_quantized.onnx"); vm = ort.InferenceSession(M + "/vision_model.onnx")
def tvec(texts):
    ids = np.zeros((len(texts), 77), dtype=np.int64)
    for i, t in enumerate(texts):
        e = tok.encode(t).ids[:77]; ids[i, :len(e)] = e
    v = tm.run(None, {tm.get_inputs()[0].name: ids})[0]; return v / np.linalg.norm(v, axis=1, keepdims=True)
def ivec(path):   # exactly as PrivacyGuard: shortest edge 256, centre crop, 0..1
    im = Image.open(path).convert("RGB"); w, h = im.size; s = 256 / min(w, h)
    im = im.resize((max(256, round(w * s)), max(256, round(h * s))), Image.BILINEAR); w, h = im.size
    x = np.asarray(im.crop(((w-256)//2, (h-256)//2, (w-256)//2+256, (h-256)//2+256)), dtype=np.float32) / 255.0
    v = vm.run(None, {vm.get_inputs()[0].name: x.transpose(2, 0, 1)[None]})[0][0]; return v / np.linalg.norm(v)
EXCLUDE = {"q_fire_extinguisher_2.jpg"}; NOT = {"q_coffee_cup_0.jpg", "q_dog_2.jpg", "q_red_sofa_1.jpg"}
files = sorted(f for f in os.listdir("img") if f not in EXCLUDE)
I = np.stack([ivec("img/" + f) for f in files])
Q = {"red_sofa": "a red sofa", "basketball_hoop": "a basketball hoop", "qr_code": "a QR code", "bicycle": "a bicycle",
     "fire_extinguisher": "a fire extinguisher", "traffic_light": "a traffic light", "coffee_cup": "a coffee cup",
     "umbrella": "an umbrella", "laptop": "a laptop", "dog": "a dog"}
GT = {"blue_sofa": {"q_red_sofa_1.jpg"}, "hanging_umbrellas": {"q_umbrella_0.jpg"}, "dog_sign": {"q_dog_0.jpg", "q_dog_1.jpg"},
      "cup_laptop": {"q_laptop_2.jpg"}}
Q.update({"blue_sofa": "a blue sofa", "hanging_umbrellas": "colourful umbrellas hanging over a street", "dog_sign": "a sign about dogs",
          "cup_laptop": "a white mug next to a laptop and a notebook"})
def score(qv):
    hits = 0
    for k, qq in Q.items():
        top = np.argsort(-(I @ qv[k]))[:3]
        ok = any((files[i] in GT[k]) if k in GT else (files[i].startswith("q_" + k) and files[i] not in NOT) for i in top); hits += ok
        print(f"  {k:18s} {'HIT ' if ok else 'miss'} {[files[i][:-4] for i in top]}")
    return hits
print("A: MobileCLIP text encoder ('a photo of ...')")
A = {k: v for k, v in zip(Q, tvec(["a photo of " + q for q in Q.values()]))}
a = score(A)
# B: query -> Nemotron text embedding -> nearest phrases of a generic bank -> their MobileCLIP text vectors
COCO = "person bicycle car motorcycle airplane bus train truck boat traffic_light fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee skis snowboard sports_ball kite baseball_bat baseball_glove skateboard surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch potted_plant bed dining_table toilet tv laptop mouse remote keyboard cell_phone microwave oven toaster sink refrigerator book clock vase scissors teddy_bear hair_drier toothbrush".split()
EXTRA = ["sign", "poster", "QR code", "barcode", "menu board", "price tag", "door", "window", "staircase", "elevator", "escalator", "shop front", "shelf", "counter", "desk", "lamp", "painting", "map", "basketball hoop", "football goal", "fire extinguisher", "exit sign", "tram", "bus stop", "street", "tree", "car park", "kitchen", "living room", "office", "corridor", "bridge", "statue", "fountain", "bicycle rack", "trash can", "mailbox", "phone booth", "coffee machine", "cash register"]
bank = [c.replace("_", " ") for c in COCO] + EXTRA
def nem(texts, kind):
    body = json.dumps({"model": "nemotron-3.5-embed", "input_type": kind, "embedding_types": ["float"], "truncate": "END",
        "inputs": [{"content": [{"type": "text", "text": t}]} for t in texts]}).encode()
    r = urllib.request.Request("https://containers.datacrunch.io/muisti-retrieval/v2/embed", body,
        {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    v = np.array(json.loads(urllib.request.urlopen(r, timeout=60).read())["embeddings"]["float"]); return v / np.linalg.norm(v, axis=1, keepdims=True)
Bn = nem(bank, "document"); Bc = tvec(["a photo of a " + b for b in bank])
qn = nem(["where did I see " + q for q in Q.values()], "query")
B = {}
for k, v in zip(Q, qn):
    s = Bn @ v; top = np.argsort(-s)[:3]; w = np.exp((s[top] - s[top].max()) * 20); w /= w.sum()
    m = (w[:, None] * Bc[top]).sum(0); B[k] = m / np.linalg.norm(m)
    print(f"  bank for {k}: {[bank[i] for i in top]}")
print("B: Nemotron embedding -> prompt bank -> MobileCLIP text vectors")
b = score(B)
print(f"RESULT A {a}/{len(Q)}  B {b}/{len(Q)}  (images {len(files)})")
