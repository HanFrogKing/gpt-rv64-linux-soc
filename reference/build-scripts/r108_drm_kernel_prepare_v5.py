#!/usr/bin/env python3
"""Keep R108 driver/source frozen; add target DRM tests and fb0 interface."""
import json,shutil
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r108-drm-kernel-r5';c.OUT=OUT;CREATED=False
guard.install(c,Path(__file__),'r108-drm-kernel-r5')
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous attempt');OUT.mkdir();CREATED=True
 base=R/'build/rv64/r108-drm-kernel-r4';bj=json.loads((base/'run-status.json').read_text())
 user=R/'build/rv64/r108-drm-userspace-r5';uj=json.loads((user/'run-status.json').read_text())
 c.require(bj['status']=='PREPARED_R108_DRM_TEST_IMAGE_NOT_BOOTED','parent build')
 c.require(uj['status']=='PREPARED_R108_STATIC_DRM_TEST_AND_DEBIAN_INITRAMFS_NOT_EXECUTED','target test/rootfs build')
 for directory,j in [(base,bj),(user,uj)]:
  for n,a in j['artifacts'].items():c.require(c.sha(directory/n)==a['sha256'],'parent artifact '+n)
  for n,h in j['source_sha256'].items():c.require(c.sha(R/n)==h,'source changed '+n)
 kernel=R/bj['overlay_source']
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'immutable driver source '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk reserve')
 build=OUT/'kernel-build';build.mkdir();c.run('copy-objects',['cp','-a',str(base/'kernel-build')+'/.',build],timeout=180)
 count=0
 for p in build.rglob('*'):
  if p.is_file() and not p.is_symlink():
   c.require(p.stat().st_ino!=(base/'kernel-build'/p.relative_to(build)).stat().st_ino,'no mutable hardlinks');count+=1
 c.run('target-config',[kernel/'scripts/config','--file',build/'.config','--enable','FB_DEVICE','--set-str','INITRAMFS_SOURCE',user/'initramfs.cpio','--set-str','LOCALVERSION','-rv64lab-r108-drm-r5'])
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld','KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=drm-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('olddefconfig',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text()
 for n in ['DRM_RV64LAB_SHADOW','DRM','DRM_GEM_SHMEM_HELPER','DRM_FBDEV_EMULATION','FRAMEBUFFER_CONSOLE','FB_DEVICE','VT','VT_CONSOLE','DEVTMPFS','RV64LAB_DMA','DMA_GLOBAL_POOL','USB_CHIPIDEA_HOST','USB_STORAGE','FPU','HVC_RISCV_SBI']:
  c.require('CONFIG_'+n+'=y\n' in config,'feature '+n)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),base/'run-status.json',user/'run-status.json',user/'initramfs.cpio',R/'scripts/rv64/build_artifact_guard_v2.py']}
 pins.update(bj['source_sha256']);pins.update(uj['source_sha256'])
 emit(OUT/'run-status.json',dict(status='RUNNING_R108_DRM_TEST_KERNEL_BUILD_NOT_BOOTED',source_sha256=pins))
 c.run('image',kb+['-j1','Image'],timeout=5400)
 for n,h in pins.items():c.require(c.sha(R/n)==h,'input modified '+n)
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'parent artifact modified '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'source modified '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config',build/'drivers/gpu/drm/tiny/rv64lab-drm.o']
 emit(OUT/'run-status.json',dict(status='PREPARED_R108_DRM_TEST_IMAGE_NOT_BOOTED',source_sha256=pins,overlay_source=str(kernel.relative_to(R)),overlay_files_sha256=bj['overlay_files_sha256'],artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},distinct_inode_objects=count,steps=c.STEPS,parent_driver_unchanged=True,rtl_changed=False,board_deployed=False,drm_runtime_verified=False,scope='Independent mutable object copy using immutable R108 r1 source. Adds FB_DEVICE and separate Debian initramfs with target test; compile/link only, no actual KMS/HDMI/USB/desktop acceptance. Physical R107 remains running.'))
 print('PREPARED_R108_DRM_TEST_IMAGE_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R108_DRM_TEST_KERNEL_BUILD',error=str(ex),steps=c.STEPS))
  raise
