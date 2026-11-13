import argparse
import csv
import re
from collections import Counter
from pathlib import Path

import cv2
import numpy as np
from rayban_esik_testi import descriptor, aligned_score

cv2.setRNGSeed(42)
cv2.setNumThreads(1)
sift = cv2.SIFT_create(nfeatures=1000)

def prep(frame):
    if frame is None:
        raise ValueError("Missing frame")
    gray = cv2.cvtColor(frame,cv2.COLOR_BGR2GRAY)
    return frame, descriptor(frame), sift.detectAndCompute(gray,None)

def scores(a,b):
    return (float(np.mean([x@y for x,y in zip(a[1],b[1])])),
            aligned_score(a[0],b[0],a[2],b[2]))

def best(table, column):
    ranked=sorted(table, key=lambda k:table[k][column], reverse=True)
    lead=table[ranked[0]][column]
    runner=table[ranked[1]][column] if len(ranked)>1 else 0
    return ranked[0] if lead>=.45 and lead-runner>=.12 else None

def code(text):
    found=set(re.findall(r'\bSTAND\s*([A-Z]\d{2})\b',text.upper()))
    return next(iter(found)) if len(found)==1 else None

def decide(table, texts, query):
    raw, aligned = best(table,0),best(table,1)
    if raw is not None and aligned is not None and raw!=aligned:
        return None,'visual_conflict'
    ref=aligned if aligned is not None else raw
    if ref is None:
        return None,'low_evidence'
    a,b=code(texts.get(query,'')),code(texts.get(ref,''))
    if a and b and a!=b:
        return None,'stand_conflict'
    return ref,'both' if raw is not None and aligned is not None else ('raw' if aligned is None else 'aligned')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--street',type=Path,default=Path.home()/'Downloads'/'MUISTI-sokak60')
    parser.add_argument('--video',type=Path)
    args=parser.parse_args()
    if not args.video:
        from tkinter import Tk,filedialog
        root=Tk(); root.withdraw()
        video=filedialog.askopenfilename(title='28 saniyelik Trim videosunu sec',filetypes=[('MP4','*.mp4')])
        root.destroy()
    else: video=str(args.video)
    if not video: return
    cap=cv2.VideoCapture(video); frames={}
    for t in [2,8,17,18,21,22,22.5,23,23.5]:
        cap.set(cv2.CAP_PROP_POS_MSEC,t*1000)
        ok,img=cap.read()
        if not ok: raise ValueError(f"Frame unavailable: {t}")
        frames[t]=prep(img)
    cap.release()
    details=[]
    def evaluate(group,q,data,expected,texts):
        selected,reason=decide(data,texts,q)
        status=('dogru_es' if selected==expected else 'yanlis_es') if selected is not None else ('dogru_ret' if expected is None else 'kacan')
        details.append(dict(group=group,query=q,expected=expected,raw=best(data,0),aligned=best(data,1),selected=selected,status=status,reason=reason))
    for t in [21,22,22.5,23.5]:
        table={r:scores(frames[t],frames[r]) for r in [2,8,17,23]}
        evaluate('rayban',t,table,23,{})
        evaluate('rayban_neg',t,{r:v for r,v in table.items() if r!=23},None,{})
    evaluate('rayban_neg',18,{r:scores(frames[18],frames[r]) for r in [21,22,23]},None,{})
    with (args.street/'manifest.csv').open(encoding='utf-8') as f: rows=list(csv.DictReader(f))
    with (args.street/'ocr_results.csv').open(encoding='utf-8-sig') as f:texts={r['file']:r['found'] for r in csv.DictReader(f)}
    refs={r['scene']:r['file'] for r in rows if r['variant']=='original'}
    def load(name):return prep(cv2.imread(str(args.street/'images'/name)))
    reference={name:load(name) for name in refs.values()}
    for r in rows:
        if r['variant']=='original':continue
        q=r['file'];query=load(q); expected=refs[r['scene']]
        table={k:scores(query,v) for k,v in reference.items()}
        evaluate(r['variant'],q,table,expected,texts)
        evaluate('sokak_neg',q,{k:v for k,v in table.items() if k!=expected},None,texts)
    # Controlled replay of the measured A12/B47 visual score and actual OCR strings.
    evaluate('stand_replay','A',{'B':(.99,.999)},None,{'A':'STANDA12','B':'STANDB47'})
    assert decide({'A':(.9,.1),'B':(.1,.9)},{},'q')==(None,'visual_conflict')
    with open('birlesik_sonuclar.csv','w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=details[0]);w.writeheader();w.writerows(details)
    for group in dict.fromkeys(r['group'] for r in details):
        print(group,dict(Counter(r['status'] for r in details if r['group']==group)))
if __name__=='__main__': main()
