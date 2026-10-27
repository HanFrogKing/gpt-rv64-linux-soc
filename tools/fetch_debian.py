#!/usr/bin/env python3
"""Fetch/verify the locked Debian package set. Never install or execute a DEB."""
from pathlib import Path
import argparse,json,os,urllib.request
from fetch_sources import ROOT,sha
p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,default=ROOT/'downloads/debian');p.add_argument('--verify-only',action='store_true');a=p.parse_args()
cache=a.cache.resolve();cache.mkdir(parents=True,exist_ok=True)
plan=json.loads((ROOT/'software/desktop/packages.lock.json').read_text())
for pkg in plan['packages']:
 name=Path(pkg['Filename']).name;dest=cache/name
 if not dest.exists():
  if a.verify_only:raise RuntimeError('Missing '+name)
  tmp=dest.with_name(dest.name+'.part')
  if tmp.exists():raise RuntimeError('Preserve partial package: '+str(tmp))
  with urllib.request.urlopen('https://deb.debian.org/debian/'+pkg['Filename'],timeout=60) as src,tmp.open('xb') as out:
   while True:
    b=src.read(1048576)
    if not b:break
    out.write(b)
  if sha(tmp)!=pkg['SHA256']:raise RuntimeError('Downloaded SHA mismatch '+name)
  os.replace(tmp,dest)
 if dest.stat().st_size!=int(pkg['Size']) or sha(dest)!=pkg['SHA256']:raise RuntimeError('Package mismatch '+name)
print('DEBIAN_PACKAGE_HASH_PASS',len(plan['packages']),'no installation or target execution')
