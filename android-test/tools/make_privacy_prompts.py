"""Privacy gate: text embeddings of the private/safe scene sentences for MobileCLIP-S0 (computed once, here).
The phone only runs the image encoder and compares against these vectors; editing the sentence list is the
whole "training". Needs: pip install onnxruntime tokenizers pillow numpy, and the model files from
https://huggingface.co/Xenova/mobileclip_s0 (onnx/text_model_quantized.onnx, onnx/vision_model.onnx, tokenizer.json)
in --models (default: next to this script, folder mobileclip/).
Usage: python -I make_privacy_prompts.py ../app/src/main/assets/privacy_prompts.json [test images...]"""
import hashlib, json, sys, os
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer
from PIL import Image

D = os.environ.get("MOBILECLIP_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "mobileclip")

# kind: stop = camera must stop (rooms), drop = frames are discarded (screens/cards/PIN), safe = normal
CLASSES = {
    "bathroom":  ("stop", ["a toilet in a bathroom", "a public restroom with toilet stalls", "a urinal in a men's room",
                           "a bathroom sink and mirror", "a shower cubicle", "inside a toilet stall"]),
    "changing":  ("stop", ["a locker room", "a changing room in a clothing store", "a fitting room with a curtain and mirror",
                           "a sauna dressing room with benches"]),
    "nudity":    ("stop", ["a naked person", "a person undressing", "a person in underwear", "a topless person",
                           "a naked body in a mirror"]),
    "medical":   ("stop", ["a doctor's examination room", "a hospital bed with a patient", "a dentist chair"]),
    "pin":       ("drop", ["a hand entering a PIN on an ATM keypad", "an ATM cash machine screen", "a card payment terminal",
                           "a hand typing a code on a keypad"]),
    "screen":    ("drop", ["a phone screen showing a banking app", "a laptop showing online banking", "a password on a screen"]),
    "card":      ("drop", ["a credit card held in a hand", "a passport or ID card", "a bank card on a table"]),
    "document":  ("drop", ["a letter or medical document on a table", "a printed bill with personal details"]),
    # safe: everyday places the glasses normally see
    "street":    ("safe", ["a street with shops", "a city sidewalk", "a bus stop", "a parking lot", "a building entrance"]),
    "shop":      ("safe", ["a supermarket shelf", "a shop sign", "a store interior", "a pharmacy counter", "a cafe counter"]),
    "indoor":    ("safe", ["an office", "a corridor with doors", "a conference hall with booths", "a classroom",
                           "an elevator lobby", "a staircase", "a kitchen", "a restaurant table", "a living room",
                           "a person standing in an elevator", "a cafe with tables and chairs", "a baby stroller next to a table",
                           "a self-service ordering kiosk in a fast food restaurant", "a person taking a selfie"]),
    "signs":     ("safe", ["a poster on a wall", "a sign with text", "a direction sign in a building", "a notice on a door",
                           "a restroom sign on a wall in a corridor",
                           "a WC sign with man and woman symbols", "a menu board", "a printed poster with text on a screen"]),
    "people":    ("safe", ["a fully clothed person", "a person wearing a jacket", "people in a swimming pool",
                           "people talking at an event", "a person at a desk with a laptop", "a crowd of people"]),
}


def tokenize(tok, texts):
    ids = np.zeros((len(texts), 77), dtype=np.int64)
    for i, t in enumerate(texts):
        e = tok.encode(t).ids[:77]
        ids[i, :len(e)] = e
    return ids


def main():
    out = sys.argv[1]
    tok = Tokenizer.from_file(os.path.join(D, "tokenizer.json"))
    tok.no_padding(); tok.no_truncation()
    tm = ort.InferenceSession(os.path.join(D, "text_model_quantized.onnx"))
    print("text inputs", [(i.name, i.shape, i.type) for i in tm.get_inputs()], [o.name for o in tm.get_outputs()])
    rows = []
    for name, (kind, prompts) in CLASSES.items():
        for p in prompts:
            rows.append((name, kind, p))
    feeds = {tm.get_inputs()[0].name: tokenize(tok, [r[2] for r in rows])}
    for extra in tm.get_inputs()[1:]:
        feeds[extra.name] = (feeds[tm.get_inputs()[0].name] != 0).astype(np.int64)
    emb = tm.run(None, feeds)[0]
    emb = emb / np.linalg.norm(emb, axis=1, keepdims=True)
    # the app build fails if this script changes without regenerating the json (gradle checkPrivacyPrompts, defect D2)
    src = open(os.path.abspath(__file__), "rb").read().replace(b"\r\n", b"\n")
    json.dump({"model": "Xenova/mobileclip_s0 vision_model.onnx", "size": 256, "scale": 100.0,
               "source_sha256": hashlib.sha256(src).hexdigest(),
               "prompts": [{"cls": r[0], "kind": r[1], "text": r[2], "vec": [round(float(x), 5) for x in v]}
                           for r, v in zip(rows, emb)]}, open(out, "w"))
    print("wrote", out, len(rows), "prompts dim", emb.shape[1])

    vm = ort.InferenceSession(os.path.join(D, "vision_model.onnx"))
    print("vision inputs", [(i.name, i.shape) for i in vm.get_inputs()])
    for path in sys.argv[2:]:
        im = Image.open(path).convert("RGB")
        w, h = im.size; s = 256 / min(w, h)
        im = im.resize((max(256, round(w * s)), max(256, round(h * s))), Image.BICUBIC)
        w, h = im.size; l, t = (w - 256) // 2, (h - 256) // 2
        x = np.asarray(im.crop((l, t, l + 256, t + 256)), dtype=np.float32) / 255.0
        x = x.transpose(2, 0, 1)[None]
        v = vm.run(None, {vm.get_inputs()[0].name: x})[0][0]
        v = v / np.linalg.norm(v)
        logits = 100.0 * emb @ v
        p = np.exp(logits - logits.max()); p /= p.sum()
        by = {}
        for (name, kind, _), pi in zip(rows, p):
            by[(name, kind)] = by.get((name, kind), 0) + pi
        priv = sum(pi for (n, k), pi in by.items() if k != "safe")
        top = sorted(by.items(), key=lambda kv: -kv[1])[:3]
        print(f"{os.path.basename(path)[:28]:28s} private={priv:.2f}  " + "  ".join(f"{n}:{pi:.2f}" for (n, k), pi in top))


main()
