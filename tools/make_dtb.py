#!/usr/bin/env python3
"""Compile the real board DT with a fresh host seed for EACH new boot bundle."""
from pathlib import Path
import argparse,os,shutil,subprocess,json
from fetch_sources import ROOT,sha
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();out=a.output.resolve()
if out.exists():raise RuntimeError('Refuse existing DT output (do not reuse boot entropy)')
dtc=shutil.which('dtc')
if not dtc:raise RuntimeError('dtc is required')
out.mkdir(parents=True);seed=out/'boot-seed.bin';seed.write_bytes(os.urandom(64));seed.chmod(0o600)
shutil.copy2(ROOT/'software/dts/board.dts',out/'board.dts')
subprocess.run([dtc,'-I','dts','-O','dtb','-o',str(out/'board.dtb'),str(out/'board.dts')],check=True,cwd=out)
manifest=dict(status='PREPARED_DTB_NOT_BOOTED',seed_source='64 fresh bytes from host OS, not hardware RNG',dtb_sha256=sha(out/'board.dtb'))
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(out/'board.dtb')
