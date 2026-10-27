#!/usr/bin/env python3
"""Build an independent PHY-enabled Image by copying existing kernel objects.
No hardlinks, no parent writes, no firmware or board deployment.
"""
import json,shutil
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r93-board-usb-kernel-r1';c.OUT=OUT;CREATED=False
guard.install(c,Path(__file__),'r93-board-usb-kernel-r1')
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous Image');OUT.mkdir();CREATED=True
 base=R/'build/rv64/r93-plic-kernel-r1';bj=json.loads((base/'run-status.json').read_text())
 phy=R/'build/rv64/r93-usb-phy-compile-r1/run-status.json';pj=json.loads(phy.read_text())
 c.require(bj['status']=='PREPARED_R93_PLIC_TEST_KERNEL_NOT_BOOTED' and pj['status']=='PASS_RV64_GENERIC_USB_PHY_COMPILE_ONLY','prerequisites')
 for n,h in bj['source_sha256'].items():c.require(c.sha(R/n)==h,'base input changed '+n)
 for n,a in bj['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'base artifact changed '+n)
 kernel=base/'kernel-source'
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'base source changed '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'space reserve')
 build=OUT/'kernel-build';build.mkdir()
 # cp -a copies regular-file data (not -l). Source symlinks retain their locked
 # source targets. Every regular copied file must have a distinct inode.
 c.run('copy-objects',['cp','-a',str(base/'kernel-build')+'/.',build],timeout=180)
 checked=0
 for p in build.rglob('*'):
  if p.is_file() and not p.is_symlink():
   q=base/'kernel-build'/p.relative_to(build)
   c.require(p.stat().st_ino!=q.stat().st_ino,'hardlink to parent '+str(p));checked+=1
 c.run('config',[kernel/'scripts/config','--file',build/'.config','--enable','NOP_USB_XCEIV','--set-str','LOCALVERSION','-rv64lab-r93-board-usb-r1'],timeout=30)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
  'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=board-usb-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('olddefconfig',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text()
 for n in ['NOP_USB_XCEIV','USB_PHY','USB_CHIPIDEA_GENERIC','USB_CHIPIDEA_HOST','USB_EHCI_HCD','USB_STORAGE','BLK_DEV_SD','SIFIVE_PLIC','RV64LAB_DMA','DMA_GLOBAL_POOL','FPU','HVC_RISCV_SBI']:
  c.require('CONFIG_'+n+'=y\n' in config,'config missing '+n)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),base/'run-status.json',phy,R/'scripts/rv64/build_artifact_guard_v2.py']}
 pins.update(bj['source_sha256'])
 emit(OUT/'source-lock.json',pins);emit(OUT/'run-status.json',dict(status='RUNNING_R93_BOARD_USB_IMAGE_PREPARATION',source_sha256=pins))
 c.run('build-image',kb+['-j1','Image'],timeout=5400)
 for n,h in pins.items():c.require(c.sha(R/n)==h,'input changed '+n)
 for n,a in bj['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent artifact modified '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'parent source modified '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config']
 emit(OUT/'run-status.json',dict(status='PREPARED_PHY_ENABLED_BOARD_USB_IMAGE_NOT_BOOTED',source_sha256=pins,
  overlay_source=str(kernel.relative_to(R)),overlay_files_sha256=bj['overlay_files_sha256'],
  artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},steps=c.STEPS,
  regular_copied_files_with_distinct_inodes=checked,board_deployed=False,own_rtl_booted=False,usb_enumerated=False,disk_accessed=False,
  scope='Independent full Linux Image enabling NOP_USB_XCEIV dependency closure; unchanged R93/R88 code and Debian initramfs. Simulator selftest drivers remain built but require explicitly simulation-only DT nodes, absent from board candidate. No physical binding/IRQ/USB/desktop claim.'))
 print('PREPARED_PHY_ENABLED_BOARD_USB_IMAGE_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R93_BOARD_USB_IMAGE',error=str(ex),steps=c.STEPS))
  raise
