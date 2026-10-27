#!/usr/bin/env python3
"""Independent R109 objects: official graphics diagnostic and X11 prerequisites."""
from pathlib import Path
import json,shutil
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r109-graphics-kernel-r1';c.OUT=OUT
guard.install(c,Path(__file__),'r109-graphics-kernel-r1')
def emit(j):c.emit(OUT/'run-status.json',json.dumps(j,indent=2)+'\n')
def verify(pins):
 for n,h in pins.items():c.require(c.sha(R/n)==h,'source '+n)
def main():
 c.require(not OUT.exists(),'preserve attempt');OUT.mkdir(parents=True)
 emit(dict(status='RUNNING_R109_KERNEL_PREPARATION_NOT_BOOTED'))
 base=R/'build/rv64/r108-drm-kernel-r5';bj=json.loads((base/'run-status.json').read_text())
 user=R/'build/rv64/r109-graphics-userspace-r2';uj=json.loads((user/'run-status.json').read_text())
 audit=R/'build/rv64/r108-xorg-config-audit-r2';aj=json.loads((audit/'run-status.json').read_text())
 c.require(uj['status']=='PREPARED_R109_SIGNED_GRAPHICS_INITRAMFS_NOT_TARGET_EXECUTED','userspace ready')
 c.require(aj['status']=='PREPARED_KCONFIG_RESOLVED_XORG_PREREQUISITES_NOT_BUILT_OR_BOOTED','config audit')
 for directory,j in [(base,bj),(user,uj)]:
  verify(j['source_sha256'])
  for n,a in j['artifacts'].items():c.require(c.sha(directory/n)==a['sha256'],'parent artifact '+n)
 verify(aj['source_sha256'])
 sdk=R/'build/rv64/linux/sdk-status.json';sj=json.loads(sdk.read_text())
 libc=Path(sj['identity']['prefix'])/'lib/libc.a';specs=R/'build/rv64/linux/static-musl.specs'
 c.require(c.sha(libc)==sj['libc_sha256'] and c.sha(specs)==sj['static_specs_sha256'],'frozen musl')
 binary=(user/'x11-ipc-probe.elf').read_bytes()
 c.require(binary[:6]==b'\x7fELF\x02\x01' and int.from_bytes(binary[18:20],'little')==243 and int.from_bytes(binary[48:52],'little')&6==0,'probe ELF64 RISC-V soft float ABI')
 kernel=R/bj['overlay_source']
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'immutable overlay '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk reserve')
 build=OUT/'kernel-build';build.mkdir();c.run('copy-objects',['cp','-a',str(base/'kernel-build')+'/.',build],timeout=180)
 count=0
 for p in build.rglob('*'):
  if p.is_file() and not p.is_symlink():
   c.require(p.stat().st_ino!=(base/'kernel-build'/p.relative_to(build)).stat().st_ino,'no mutable hardlinks');count+=1
 # Use the already resolved candidate as a starting point, then resolve again
 # under the pinned 2.38 linker. Preserve the accepted parent's ISA set.
 c.require(c.sha(audit/'kernel-config-only/.config')==aj['new_config_sha256'],'audited config')
 shutil.copyfile(audit/'kernel-config-only/.config',build/'.config')
 c.run('candidate-config',[kernel/'scripts/config','--file',build/'.config','--set-str','INITRAMFS_SOURCE',user/'initramfs.cpio','--set-str','LOCALVERSION','-rv64lab-r109-graphics-r1'])
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld','KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=graphics-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('olddefconfig',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text()
 isa=lambda s:set(l for l in s.splitlines() if l.startswith('CONFIG_RISCV_ISA_') and l.endswith('=y'))
 c.require(isa(config)==isa((base/'kernel-build/.config').read_text()),'no newly enabled ISA')
 c.require('CONFIG_LD_VERSION=23800\n' in config,'pinned Linux linker')
 for n in ['NET','UNIX','SYSVIPC','INOTIFY_USER','TMPFS_POSIX_ACL','FHANDLE','DRM_RV64LAB_SHADOW','DRM_FBDEV_EMULATION','FRAMEBUFFER_CONSOLE','FB_DEVICE','FPU','RV64LAB_DMA','USB_CHIPIDEA_HOST','USB_STORAGE','HVC_RISCV_SBI']:
  c.require('CONFIG_'+n+'=y\n' in config,'feature '+n)
 c.require('CONFIG_INET=y' not in config.splitlines(),'no unrequested TCP/IP')
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),base/'run-status.json',user/'run-status.json',audit/'run-status.json',audit/'kernel-config-only/.config',sdk,specs,R/'scripts/rv64/build_artifact_guard_v2.py']}
 pins.update(bj['source_sha256']);pins.update(uj['source_sha256']);pins.update(aj['source_sha256'])
 emit(dict(status='RUNNING_R109_GRAPHICS_KERNEL_BUILD_NOT_BOOTED',source_sha256=pins))
 c.run('image',kb+['-j1','Image'],timeout=5400)
 verify(pins)
 for n,a in bj['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent artifact unchanged '+n)
 for n,h in bj['overlay_files_sha256'].items():c.require(c.sha(kernel/n)==h,'overlay unchanged '+n)
 arts=[build/'arch/riscv/boot/Image',build/'vmlinux',build/'.config',build/'drivers/gpu/drm/tiny/rv64lab-drm.o']
 emit(dict(status='PREPARED_R109_OFFICIAL_GRAPHICS_IMAGE_NOT_BOOTED',source_sha256=pins,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in arts},overlay_source=bj['overlay_source'],overlay_files_sha256=bj['overlay_files_sha256'],distinct_inode_objects=count,steps=c.STEPS,enabled_CPU_ISA_unchanged=True,parent_driver_unchanged=True,rtl_changed=False,board_deployed=False,desktop=False,scope='Independent kernel Image with official modetest inventory and actual X11 IPC probe; compile only. Current physical R108 and all accepted inputs retained. NET/UNIX/SYSVIPC/inotify prerequisites are not desktop, TCP/IP, or filesystem handle acceptance.'))
 print('PREPARED_R109_OFFICIAL_GRAPHICS_IMAGE_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if OUT.exists():emit(dict(status='FAIL_R109_GRAPHICS_KERNEL_BUILD',error=str(ex),steps=c.STEPS))
  raise
