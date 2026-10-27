#!/usr/bin/env python3
from pathlib import Path
import argparse,json,shutil,tarfile
from fetch_sources import ROOT,sha,fetch
p=argparse.ArgumentParser();p.add_argument('--archive',type=Path);p.add_argument('--cache',type=Path,default=ROOT/'downloads');p.add_argument('--output',type=Path,default=ROOT/'build/opensbi-source');a=p.parse_args()
out=a.output.resolve()
if out.exists():raise RuntimeError('Refuse existing output: '+str(out))
lock=json.loads((ROOT/'software/sources.lock.json').read_text())['opensbi']
archive=a.archive.resolve() if a.archive else fetch('opensbi',a.cache)
if sha(archive)!=lock['sha256']:raise RuntimeError('OpenSBI SHA256 mismatch')
out.mkdir(parents=True)
with tarfile.open(archive,'r:gz') as t:
 for m in t.getmembers():
  if m.name.startswith('/') or '..' in Path(m.name).parts:raise RuntimeError('Unsafe archive path')
 t.extractall(out)
src=out/lock['directory']
name='lib/utils/serial/cadence-uart.c'
shutil.copy2(ROOT/'software/opensbi/overlay'/name,src/name)
assert sha(src/name)==sha(ROOT/'software/opensbi/overlay'/name)
print('OPENSBI_SOURCE_READY',src)
