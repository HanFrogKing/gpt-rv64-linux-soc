#!/usr/bin/env python3
"""Run the existing real-RTL timing bench; bounded build, no waveform capture."""
from pathlib import Path
import datetime,json,os,shutil,subprocess,sys
ROOT=Path(__file__).resolve().parents[1]
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
out=ROOT/'build/tests'/('video-'+stamp)
if out.exists():raise RuntimeError('Refuse existing run directory')
if shutil.disk_usage(ROOT).free<3*1024**3:raise RuntimeError('At least 3 GiB free required')
verilator=os.environ.get('VERILATOR') or shutil.which('verilator')
if not verilator:raise RuntimeError('Set VERILATOR or put verilator on PATH')
out.mkdir(parents=True);obj=out/'obj'
def clean_pch():
 # Same narrow policy as the original build_artifact_guard_v2: only this owned
 # Verilator directory, matching generated PCH/header and __verFiles identity.
 for p in obj.rglob('*.gch'):
  if p.is_symlink() or not p.resolve().is_relative_to(obj.resolve()):raise RuntimeError('Unsafe PCH path')
  if '__pch.h.' not in p.name:continue
  h=p.with_name(p.name.split('__pch.h.',1)[0]+'__pch.h')
  if h.is_file() and list(p.parent.glob('*__verFiles.dat')):p.unlink()
cmd=[verilator,'--cc','--exe','--build','-j','2','--top-module','rv64_video_timing','--Mdir',str(obj),'-CFLAGS','-std=c++17',str(ROOT/'rtl/rv64/video/rv64_video_timing.sv'),str(ROOT/'tests/reference/r95_video_timing_test.cpp')]
try:
 with (out/'build.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=300)
finally:clean_pch()
with (out/'test.log').open('w') as log:subprocess.run([str(obj/'Vrv64_video_timing')],stdout=log,stderr=subprocess.STDOUT,check=True,timeout=120)
result=(out/'test.log').read_text();assert 'R95_VIDEO_TIMING_PASS' in result
(out/'status.json').write_text(json.dumps(dict(status='PASS_VIDEO_TIMING_ONLY',result=result.strip(),board_actions=False),indent=2)+'\n')
print(result.strip());print('LOGS',out)
