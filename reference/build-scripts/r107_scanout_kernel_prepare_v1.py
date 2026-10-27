#!/usr/bin/env python3
"""Separate R107 diagnostic Linux source overlay/object copy. Never deploy."""
import json,shutil,difflib
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r107-scanout-kernel-r1';c.OUT=OUT;CREATED=False
guard.install(c,Path(__file__),'r107-scanout-kernel-r1')
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve kernel attempt');OUT.mkdir();CREATED=True
 base=R/'build/rv64/r93-board-usb-kernel-r1';bj=json.loads((base/'run-status.json').read_text())
 c.require(bj['status']=='PREPARED_PHY_ENABLED_BOARD_USB_IMAGE_NOT_BOOTED','parent kernel status')
 pattern=R/'build/rv64/r107-pattern-r1/run-status.json';pj=json.loads(pattern.read_text())
 c.require(pj['status']=='PASS_PATTERN_C_BYTES_VS_INDEPENDENT_PYTHON_AND_THREE_CORRUPTIONS' and pj['crc32']=='a0117b86','independent pattern')
 for n,h in pj['source_sha256'].items():c.require(c.sha(R/n)==h,'pattern input changed '+n)
 for n,h in bj['source_sha256'].items():c.require(c.sha(R/n)==h,'parent input changed '+n)
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'parent artifact changed '+n)
 parent_kernel=R/bj['overlay_source']
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(parent_kernel/n)==h,'parent source changed '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk reserve')
 kernel=OUT/'kernel-source';kernel.mkdir()
 c.run('overlay',['cp','-as',str(parent_kernel)+'/.',kernel],timeout=180)
 changes={}
 for n in ['arch/riscv/Kconfig','arch/riscv/mm/Makefile']:
  p=kernel/n;c.require(p.is_symlink(),'not overlay link '+n);old=p.read_text();p.unlink()
  extra=('\nconfig RV64LAB_SCANOUT_PROBE\n\tbool "RV64 lab persistent scanout diagnostic"\n\tdepends on RV64LAB_DMA && OF && 64BIT\n\tselect CRC32\n\thelp\n\t  Explicit DT opt-in diagnostic, no DRM or runtime buffer release.\n' if n.endswith('Kconfig') else '\nobj-$(CONFIG_RV64LAB_SCANOUT_PROBE) += rv64lab-scanout-probe.o\nCFLAGS_rv64lab-scanout-probe.o += -Werror\n')
  p.write_text(old+extra);changes[n]=c.sha(p)
  c.emit(OUT/(p.name+'.patch'),''.join(difflib.unified_diff(old.splitlines(True),p.read_text().splitlines(True),fromfile='R93/'+n,tofile='R107/'+n)))
 src=R/'sw/rv64/r107-linux-scanout'
 for a,b in [('rv64lab-scanout-probe.c','rv64lab-scanout-probe.c'),('pattern.h','r107-pattern.h')]:
  n='arch/riscv/mm/'+b;c.require(not (kernel/n).exists(),'new source collision');shutil.copy2(src/a,kernel/n);changes[n]=c.sha(kernel/n)
 build=OUT/'kernel-build';build.mkdir()
 c.run('copy-objects',['cp','-a',str(base/'kernel-build')+'/.',build],timeout=180)
 count=0
 for p in build.rglob('*'):
  if p.is_file() and not p.is_symlink():
   q=base/'kernel-build'/p.relative_to(build)
   c.require(p.stat().st_ino!=q.stat().st_ino,'hardlink parent '+str(p));count+=1
 c.run('set-config',[kernel/'scripts/config','--file',build/'.config','--enable','RV64LAB_SCANOUT_PROBE','--set-str','LOCALVERSION','-rv64lab-r107-scanout-r1'])
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld','KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=scanout-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('olddefconfig',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text()
 for n in ['RV64LAB_SCANOUT_PROBE','RV64LAB_DMA','RISCV_DMA_NONCOHERENT','DMA_GLOBAL_POOL','CRC32','NOP_USB_XCEIV','USB_CHIPIDEA_HOST','USB_STORAGE','BLK_DEV_SD','SIFIVE_PLIC','FPU','HVC_RISCV_SBI']:
  c.require('CONFIG_'+n+'=y\n' in config,'missing config '+n)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),src/'pattern.h',src/'rv64lab-scanout-probe.c',base/'run-status.json',pattern,R/'scripts/rv64/build_artifact_guard_v2.py',R/'rtl/rv64/board/rv64_board_system_video.sv',R/'rtl/rv64/video/rv64_scanout_control.sv']}
 pins.update(pj['source_sha256']);pins.update(bj['source_sha256']);overlay=dict(bj['overlay_files_sha256']);overlay.update(changes)
 emit(OUT/'source-lock.json',pins);emit(OUT/'run-status.json',dict(status='RUNNING_R107_DIAGNOSTIC_KERNEL_PREPARATION',source_sha256=pins,overlay_files_sha256=overlay))
 for n in overlay:
  p=OUT/'source'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(kernel/n,p)
 c.run('compile-driver',kb+['-j1','arch/riscv/mm/rv64lab-scanout-probe.o'],timeout=600)
 c.run('build-image',kb+['-j1','Image'],timeout=5400)
 for n,h in pins.items():c.require(c.sha(R/n)==h,'input changed '+n)
 for n,h in overlay.items():c.require(c.sha(kernel/n)==h,'overlay changed '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(parent_kernel/n)==h,'parent source modified '+n)
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'parent artifact modified '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config',build/'arch/riscv/mm/rv64lab-scanout-probe.o']
 emit(OUT/'run-status.json',dict(status='PREPARED_R107_SCANOUT_DIAGNOSTIC_IMAGE_NOT_BOOTED',source_sha256=pins,overlay_files_sha256=overlay,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},steps=c.STEPS,distinct_inode_objects=count,own_rtl_booted=False,physical_booted=False,scope='Cross-compile/link only. Explicit DT opt-in, persistent DMA API allocation, no module/unbind/free after RUN. No DRM/KMS/desktop/actual USB coexistence acceptance. Simulator-only R88/R93 drivers remain unbound on physical DT. Parent kernel unchanged.'))
 print('PREPARED_R107_SCANOUT_DIAGNOSTIC_IMAGE_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R107_DIAGNOSTIC_KERNEL_PREPARATION',error=str(ex),steps=c.STEPS))
  raise
