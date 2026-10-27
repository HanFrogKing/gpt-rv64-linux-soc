#!/usr/bin/env python3
"""Independent storage-capable kernel, unchanged R109 userspace/RTL/driver."""
from pathlib import Path
import json,shutil,traceback
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r111-storage-kernel-r2';c.OUT=OUT
guard.install(c,Path(__file__),'r111-storage-kernel-r2')
FEATURES=['MISC_FILESYSTEMS','BLK_DEV_LOOP','EXFAT_FS','SQUASHFS','SQUASHFS_XZ','SQUASHFS_ZLIB','OVERLAY_FS']
def emit(j):c.emit(OUT/'run-status.json',json.dumps(j,indent=2)+'\n')
def main():
 c.require(not OUT.exists(),'preserve attempt');OUT.mkdir(parents=True)
 emit(dict(status='RUNNING_R111_STORAGE_KERNEL_PREPARATION_NOT_BOOTED'))
 base=R/'build/rv64/r109-graphics-kernel-r1';j=json.loads((base/'run-status.json').read_text())
 c.require(j['status']=='PREPARED_R109_OFFICIAL_GRAPHICS_IMAGE_NOT_BOOTED','frozen parent')
 for n,h in j['source_sha256'].items():c.require(c.sha(R/n)==h,'source '+n)
 for n,a in j['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent artifact '+n)
 kernel=R/j['overlay_source']
 for n,h in j['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'parent overlay '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk reserve')
 build=OUT/'kernel-build';build.mkdir()
 c.run('copy-objects',['cp','-a',str(base/'kernel-build')+'/.',build],timeout=180)
 count=0
 for p in build.rglob('*'):
  if p.is_file() and not p.is_symlink():
   c.require(p.stat().st_ino!=(base/'kernel-build'/p.relative_to(build)).stat().st_ino,'no mutable hardlinks');count+=1
 command=[kernel/'scripts/config','--file',build/'.config','--set-str','LOCALVERSION','-rv64lab-r111-storage-r2']
 for n in FEATURES:command+=['--enable',n]
 c.run('storage-config',command)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld','KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=storage-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('olddefconfig',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text();old=(base/'kernel-build/.config').read_text()
 isa=lambda t:set(x for x in t.splitlines() if x.startswith('CONFIG_RISCV_ISA_') and x.endswith('=y'))
 c.require(isa(config)==isa(old),'ISA unchanged')
 for n in FEATURES+['DRM_RV64LAB_SHADOW','DRM_FBDEV_EMULATION','FRAMEBUFFER_CONSOLE','FPU','RV64LAB_DMA','USB_CHIPIDEA_HOST','USB_STORAGE','HVC_RISCV_SBI','UNIX','SYSVIPC','NLS_CODEPAGE_437','NLS_ISO8859_1']:
  c.require('CONFIG_'+n+'=y\n' in config,'feature '+n)
 def parse(t):return {x.split('=',1)[0]:x.split('=',1)[1] for x in t.splitlines() if x.startswith('CONFIG_') and '=' in x}
 a,b=parse(old),parse(config);diff={n:dict(before=a.get(n,'n'),after=b.get(n,'n')) for n in sorted(a.keys()|b.keys()) if a.get(n,'n')!=b.get(n,'n')}
 c.require(a['CONFIG_INITRAMFS_SOURCE']==b['CONFIG_INITRAMFS_SOURCE'],'exact old userspace, no new unchecked rootfs')
 pins=dict(j['source_sha256']);pins.update({str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),base/'run-status.json',base/'kernel-build/.config',R/'scripts/rv64/build_artifact_guard_v2.py']})
 emit(dict(status='RUNNING_R111_STORAGE_KERNEL_BUILD_NOT_BOOTED',source_sha256=pins,config_diff=diff))
 c.run('image',kb+['-j1','Image'],timeout=5400)
 for n,h in pins.items():c.require(c.sha(R/n)==h,'unchanged source '+n)
 for n,a in j['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent unchanged '+n)
 for n,h in j['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'overlay unchanged '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config',build/'drivers/gpu/drm/tiny/rv64lab-drm.o']
 emit(dict(status='PREPARED_R111_STORAGE_IMAGE_NOT_BOOTED',source_sha256=pins,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},overlay_source=j['overlay_source'],overlay_files_sha256=j['overlay_files_sha256'],distinct_inode_objects=count,config_diff=diff,steps=c.STEPS,enabled_CPU_ISA_unchanged=True,parent_driver_unchanged=True,initramfs_unchanged=True,rtl_changed=False,board_deployed=False,desktop=False,external_media_writes=False,scope='Compile only. New exFAT/loop/SquashFS/overlay support, same accepted R109 initramfs and hardware. Requires independent actual RTL/Linux and later physical mount/read tests; no disk write or desktop acceptance.'))
 print('PREPARED_R111_STORAGE_IMAGE_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if OUT.exists():emit(dict(status='FAIL_R111_STORAGE_KERNEL_BUILD',error=repr(ex),traceback=traceback.format_exc(),steps=c.STEPS))
  raise
