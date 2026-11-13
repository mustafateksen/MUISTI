import csv
import sys
from pathlib import Path

import cv2
import numpy as np


def descriptor(frame):
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    result = []
    for w, h in [(128, 80), (64, 40)]:
        a = cv2.resize(gray, (w, h), interpolation=cv2.INTER_AREA).astype("float32")
        a = a[h//10:-(h//10), w//10:-(w//10)]
        v = np.concatenate([cv2.Sobel(a, cv2.CV_32F, *k).ravel() for k in [(1, 0), (0, 1)]])
        result.append(v / max(np.linalg.norm(v), 1e-8))
    return result


def aligned_score(a, b, fa, fb):
    pa, da = fa
    pb, db = fb
    if da is None or db is None or min(len(da),len(db)) < 2:
        return 0.0
    matcher = cv2.BFMatcher()
    def pairs(x,y):
        return {(m.queryIdx,m.trainIdx) for m,n in matcher.knnMatch(x,y,k=2) if m.distance < .8*n.distance}
    matches = sorted(pairs(da,db) & {(j,i) for i,j in pairs(db,da)})
    if len(matches) < 8:
        return 0.0
    x = np.float32([pa[i].pt for i,j in matches])
    y = np.float32([pb[j].pt for i,j in matches])
    H, mask = cv2.findHomography(x,y,cv2.RANSAC,3.0)
    if H is None or mask is None:
        return 0.0
    keep = mask.ravel().astype(bool)
    if keep.sum() < max(8,.5*len(matches)):
        return 0.0
    hull = cv2.convexHull(y[keep]).astype("int32")
    if cv2.contourArea(hull) < .05*b.shape[0]*b.shape[1]:
        return 0.0
    aligned = cv2.warpPerspective(a,H,(b.shape[1],b.shape[0]))
    left,top,width,height = cv2.boundingRect(hull)
    u = descriptor(aligned[top:top+height,left:left+width])
    v = descriptor(b[top:top+height,left:left+width])
    return float(np.mean([p @ q for p,q in zip(u,v)]))


def main():
    if len(sys.argv) > 1:
        video = sys.argv[1]
    else:
        from tkinter import Tk, filedialog
        root = Tk()
        root.withdraw()
        video = filedialog.askopenfilename(title="28 saniyelik Trim videosunu sec", filetypes=[("MP4", "*.mp4")])
        root.destroy()
        if not video:
            return
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        raise SystemExit("Video acilamadi.")
    cv2.setRNGSeed(42)
    sift = cv2.SIFT_create(nfeatures=1000)
    frames, local = {}, {}
    features = {}
    for t in [2, 8, 17, 18, 21, 22, 22.5, 23, 23.5]:
        cap.set(cv2.CAP_PROP_POS_MSEC, t*1000)
        ok, frame = cap.read()
        if not ok:
            raise SystemExit(f"{t} sn okunamadi. Ayni Trim dosyasini secin.")
        frames[t] = frame
        local[t] = sift.detectAndCompute(cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY),None)
        features[t] = descriptor(frame)
    cap.release()
    tests = [(t, [2, 8, 17, 23], 23) for t in (21, 22, 22.5, 23.5)]
    tests += [(t, [2, 8, 17], None) for t in (21, 22, 22.5, 23.5)]
    tests += [(18, [21, 22, 23], None)]
    with open('rayban_esik_sonuclari.csv','w',newline='',encoding='utf-8-sig') as f:
        out = csv.writer(f)
        out.writerow(['mode','query_second','refs','expected_screen_ref','first','score','margin','accepted'])
        for mode in ["raw","aligned"]:
            print(mode)
            for t, refs, expected in tests:
                ranks = sorted(((float(np.mean([x @ y for x,y in zip(features[t],features[r])])), r)
                                for r in refs),reverse=True)
                if mode == "aligned":
                    ranks = sorted(((aligned_score(frames[t],frames[r],local[t],local[r]),r) for r in refs),reverse=True)
                score, first = ranks[0]
                margin = score - ranks[1][0]
                accepted = score >= .45 and margin >= .12
                print(f"{t:g}s | hedef={expected} | ilk={first:g}s | puan={score:.3f} | fark={margin:.3f} | " +
                      ("ADAY" if accepted else "BELIRSIZ"))
                out.writerow([mode,t, refs, expected, first, score, margin, accepted])


if __name__ == '__main__':
    main()
