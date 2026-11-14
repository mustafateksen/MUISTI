"""Fetch a fixed, spread-out sample of TextVQA validation (100 images + their questions).

Source: lmms-lab-encoder/textvqa on Hugging Face (parquet mirror of TextVQA 0.5.1), rows API only,
so nothing big is downloaded. Images go to results/textvqa/images (git-ignored, not committed).
Output: results/textvqa/questions.json = [{qid, image, question, answers[10], majority}]
"""
import ast, collections, json, os, sys, time, urllib.request
N = int(sys.argv[1]) if len(sys.argv) > 1 else 100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results", "textvqa")
API = "https://datasets-server.huggingface.co/rows?dataset=lmms-lab-encoder/textvqa&config=default&split=validation"

def get(url):
    for i in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "muisti-eval"}), timeout=60) as r:
                return r.read()
        except Exception as ex:
            if i == 3: raise
            time.sleep(10 + 20 * i)

# 5 blocks of 100 rows spread over the 5000-row split (few API calls: the rows API rate-limits),
# N/5 images from each block, all questions of a chosen image kept.
qs, seen = [], set()
per_block = N // 5
for off in (0, 1000, 2000, 3000, 4000):
    rows = json.loads(get(f"{API}&offset={off}&length=100"))["rows"]
    taken = set()
    for row in (r["row"] for r in rows):
        img = row["image_id"]
        if img not in taken and (len(taken) >= per_block or img in seen):
            continue
        if img not in taken:
            path = os.path.join(OUT, "images", f"{img}.jpg")
            if not os.path.exists(path):
                open(path, "wb").write(get(row["image"]["src"]))
                time.sleep(0.4)
            taken.add(img)
            seen.add(img)
        ans = row["answers"] if isinstance(row["answers"], list) else ast.literal_eval(row["answers"])
        qs.append({"qid": row["question_id"], "image": f"{img}.jpg", "question": row["question"], "answers": ans,
                   "majority": collections.Counter(a.lower().strip() for a in ans).most_common(1)[0][0]})
    time.sleep(2)
json.dump(qs, open(os.path.join(OUT, "questions.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print(f"{len(seen)} images, {len(qs)} questions")
