#!/usr/bin/env python3
"""Materialize pristine Linux 6.6.80 plus the exact physical-kernel project overlay."""
from pathlib import Path
import argparse,json,shutil,tarfile
from fetch_sources import ROOT,sha,fetch
def main():
 p=argparse.ArgumentParser();p.add_argument('--archive',type=Path);p.add_argument('--cache',type=Path,default=ROOT/'downloads');p.add_argument('--output',type=Path,default=ROOT/'build/linux-source');a=p.parse_args()
 out=a.output.resolve()
 if out.exists():raise RuntimeError('Refuse existing output: '+str(out))
 if shutil.disk_usage(out.parent if out.parent.exists() else ROOT).free<3*1024**3:raise RuntimeError('At least 3 GiB free is required')
 lock=json.loads((ROOT/'software/sources.lock.json').read_text())['linux']
 archive=a.archive.resolve() if a.archive else fetch('linux',a.cache)
 if sha(archive)!=lock['sha256']:raise RuntimeError('Upstream Linux SHA256 mismatch')
 # Only extract the trusted, pinned upstream archive. Never merge into a checkout.
 out.mkdir(parents=True)
 with tarfile.open(archive,'r:xz') as t:
  for m in t.getmembers():
   if m.name.startswith('/') or '..' in Path(m.name).parts:raise RuntimeError('Unsafe archive path')
  t.extractall(out)
 src=out/lock['directory'];pins=json.loads((ROOT/'software/linux/overlay.lock.json').read_text())
 for name,h in pins.items():
  source=ROOT/'software/linux/overlay'/name
  if sha(source)!=h:raise RuntimeError('Overlay SHA256 mismatch: '+name)
  dest=src/name;dest.parent.mkdir(parents=True,exist_ok=True)
  if dest.is_symlink():dest.unlink()
  shutil.copy2(source,dest)
  if sha(dest)!=h:raise RuntimeError('Copy verification failed: '+name)
 (out/'preparation.json').write_text(json.dumps(dict(upstream_sha256=lock['sha256'],overlay_files=len(pins),status='PASS_SOURCE_PREPARATION_NOT_KERNEL_BUILD'),indent=2)+'\n')
 print('LINUX_SOURCE_READY',src,'verified_project_files='+str(len(pins)))
if __name__=='__main__':main()
