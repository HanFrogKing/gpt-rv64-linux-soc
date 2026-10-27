#!/usr/bin/env python3
"""Fetch pinned source archives without installing anything."""
from pathlib import Path
import argparse,hashlib,json,os,urllib.request
ROOT=Path(__file__).resolve().parents[1]
def sha(path):
 h=hashlib.sha256()
 with Path(path).open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
def fetch(component,cache):
 lock=json.loads((ROOT/'software/sources.lock.json').read_text())[component]
 cache=Path(cache).resolve();cache.mkdir(parents=True,exist_ok=True);dest=cache/lock['archive']
 if dest.exists():
  if sha(dest)!=lock['sha256']:raise RuntimeError('Existing archive hash mismatch: '+str(dest))
  return dest
 tmp=dest.with_name(dest.name+'.part')
 if tmp.exists():raise RuntimeError('Preserve partial download: '+str(tmp))
 with urllib.request.urlopen(lock['url'],timeout=60) as source,tmp.open('xb') as out:
  while True:
   b=source.read(1048576)
   if not b:break
   out.write(b)
 if sha(tmp)!=lock['sha256']:raise RuntimeError('Downloaded archive hash mismatch; partial file retained')
 os.replace(tmp,dest);return dest
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('component',choices=['linux','opensbi','musl','busybox']);p.add_argument('--cache',type=Path,default=ROOT/'downloads');a=p.parse_args()
 print(fetch(a.component,a.cache))
