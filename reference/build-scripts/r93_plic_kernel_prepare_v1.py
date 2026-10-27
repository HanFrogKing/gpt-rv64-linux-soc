#!/usr/bin/env python3
"""Independent R88-kernel overlay with an explicitly simulator-only IRQ test."""
import json,shutil,difflib
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r93-plic-kernel-r1';c.OUT=OUT;CREATED=False
guard.install(c,Path(__file__),'r93-plic-kernel-r1')
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous kernel');OUT.mkdir();CREATED=True
 base=R/'build/rv64/r88-linux-dma-r2';bj=json.loads((base/'run-status.json').read_text())
 c.require(bj['status']=='PREPARED_R88_NONCOHERENT_DMA_KERNEL_NOT_BOOTED','parent kernel missing')
 for n,h in bj['source_sha256'].items():c.require(c.sha(R/n)==h,'stale parent input '+n)
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'stale parent artifact '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(base/'kernel-source'/n)==h,'stale parent overlay '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk reserve')
 kernel=OUT/'kernel-source';kernel.mkdir()
 c.run('overlay',['cp','-as',str(base/'kernel-source')+'/.',kernel],timeout=180)
 name='arch/riscv/mm/Makefile';p=kernel/name;c.require(p.is_symlink(),'Makefile not link');old=p.read_text();p.unlink()
 p.write_text(old+'\nobj-$(CONFIG_SIFIVE_PLIC) += rv64lab-plic-selftest.o\nCFLAGS_rv64lab-plic-selftest.o += -Werror\n')
 src=R/'sw/rv64/r93-plic-system-probe/rv64lab-plic-selftest.c';dst='arch/riscv/mm/rv64lab-plic-selftest.c'
 c.require(not (kernel/dst).exists(),'new driver exists');shutil.copy2(src,kernel/dst)
 c.emit(OUT/'kernel.patch',''.join(difflib.unified_diff(old.splitlines(True),p.read_text().splitlines(True),fromfile='R88/'+name,tofile='R93/'+name)))
 overlay=dict(bj['overlay_files_sha256']);overlay.update({name:c.sha(p),dst:c.sha(kernel/dst)})
 build=OUT/'kernel-build';build.mkdir();shutil.copyfile(base/'kernel-build/.config',build/'.config')
 c.run('target-config',[kernel/'scripts/config','--file',build/'.config','--set-str','LOCALVERSION','-rv64lab-r93-plic-r1'],timeout=30)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
  'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=plic-test','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('kernel-config',kb+['olddefconfig'],timeout=120)
 for n in ['SIFIVE_PLIC','RV64LAB_DMA','RV64LAB_DMA_SELFTEST','RISCV_DMA_NONCOHERENT','DMA_GLOBAL_POOL','HVC_RISCV_SBI','FPU']:
  c.require('CONFIG_'+n+'=y\n' in (build/'.config').read_text(),'config '+n)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),src,base/'run-status.json',base/'kernel-source'/name,
  R/'scripts/rv64/build_artifact_guard_v2.py',R/'build/rv64/r72-debian-hvc-r5/initramfs.cpio']}
 pins.update(bj['source_sha256'])
 emit(OUT/'source-lock.json',pins)
 for n in overlay:
  d=OUT/'source'/n;d.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(kernel/n,d)
 emit(OUT/'run-status.json',dict(status='RUNNING_R93_PLIC_TEST_KERNEL',source_sha256=pins))
 c.run('kernel-build',kb+['-j1','Image'],timeout=5400)
 for n,h in pins.items():c.require(c.sha(R/n)==h,'input changed '+n)
 for n,h in overlay.items():c.require(c.sha(kernel/n)==h,'overlay changed '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(base/'kernel-source'/n)==h,'parent changed '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config',OUT/'kernel.patch']
 emit(OUT/'run-status.json',dict(status='PREPARED_R93_PLIC_TEST_KERNEL_NOT_BOOTED',source_sha256=pins,overlay_files_sha256=overlay,
  artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},steps=c.STEPS,
  board_deployed=False,usb_accepted=False,hdmi_accepted=False,
  scope='R88 unchanged DMA hooks and Debian initramfs; simulator-only PLIC source test. Requires explicit simulator-only DT node. Not Linux boot/IRQ/USB acceptance.'))
 print('PREPARED_R93_PLIC_TEST_KERNEL_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R93_PLIC_TEST_KERNEL',error=str(ex),steps=c.STEPS))
  raise
