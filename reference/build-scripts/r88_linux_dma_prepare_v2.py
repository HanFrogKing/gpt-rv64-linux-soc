#!/usr/bin/env python3
"""Independent kernel overlay: unchanged upstream source files via read-only use.
Only selected symlinks are replaced by ordinary patched files in this phase.
No source hardlinks, global tool changes, board writes or rootfs package edits.
"""
import difflib,json,shutil,os
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r88-linux-dma-r2';c.OUT=OUT
guard.install(c,Path(__file__),'r88-linux-dma-r2');CREATED=False
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous kernel');OUT.mkdir();CREATED=True
 emit(OUT/'run-status.json',dict(status='RUNNING_R88_LINUX_DMA_PREPARATION'))
 base=R/'build/rv64/r72-debian-hvc-r5';bj=json.loads((base/'run-status.json').read_text())
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'base artifact changed '+n)
 gate=R/'build/rv64/r88-dma-protocol-r2/run-status.json';gj=json.loads(gate.read_text())
 c.require(gj['status']=='PASS_R88_SHARED_DMA_SOFTWARE_ON_REAL_CPU_NOT_LINUX','shared protocol missing')
 for n,h in gj['source_sha256'].items():c.require(c.sha(R/n)==h,'protocol candidate stale '+n)
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk gate')
 original=R/'build/rv64/linux/src/linux-6.6.80';kernel=OUT/'kernel-source';kernel.mkdir()
 # Mirror directories, symlink files; mutations below unlink ONLY overlay links.
 c.run('source-overlay',['cp','-as',str(original)+'/.',kernel],timeout=180)
 patches={};parents={};inputs={}
 def patch(name,text):
  p=kernel/name
  c.require(p.is_symlink() and p.resolve()==(original/name).resolve(),'overlay link '+name)
  old=p.read_text();parents[name]=c.sha(original/name);p.unlink();p.write_text(text)
  patches[name]=c.sha(p)
  inputs[name]=''.join(difflib.unified_diff(old.splitlines(True),text.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
 name='arch/riscv/Kconfig';s=(kernel/name).read_text()
 at='config RISCV_NONSTANDARD_CACHE_OPS\n';c.require(s.count(at)==1,'Kconfig anchor')
 add='''config RV64LAB_DMA
	bool "RV64 laboratory fixed physical noncoherent DMA"
	depends on 64BIT && MMU && OF
	select RISCV_DMA_NONCOHERENT
	select RISCV_NONSTANDARD_CACHE_OPS
	select DMA_GLOBAL_POOL
	select DMA_NONCOHERENT_MMAP
	help
	  Fixed physical 8 MiB uncached range and R85 line-maintenance MMIO.
	  Requires explicit matching platform/controller/pool device tree.
	  Does not advertise Zicbom, Svpbmt or hardware cache coherency.

config RV64LAB_DMA_SELFTEST
	bool "RV64 laboratory simulation-only DMA API test"
	depends on RV64LAB_DMA
	help
	  Only probes the explicitly simulation-only test device. Requires an
	  external modeled RAM agent at a separate reserved mailbox page.
	  Must not be added to a physical USB device tree.

'''
 patch(name,s.replace(at,add+at))
 name='arch/riscv/kernel/setup.c';s=(kernel/name).read_text()
 at='#include <asm/cacheflush.h>\n';c.require(s.count(at)==1,'setup header anchor')
 s=s.replace(at,at+'#include <asm/rv64lab-dma.h>\n')
 at='\triscv_init_cbo_blocksizes();\n';c.require(s.count(at)==1,'setup CBO anchor')
 patch(name,s.replace(at,at+'\trv64lab_dma_early_init();\n'))
 name='arch/riscv/mm/Makefile';s=(kernel/name).read_text()
 patch(name,s+'''\nobj-$(CONFIG_RV64LAB_DMA) += rv64lab-dma.o
obj-$(CONFIG_RV64LAB_DMA_SELFTEST) += rv64lab-dma-selftest.o
CFLAGS_rv64lab-dma.o += -Werror
CFLAGS_rv64lab-dma-selftest.o += -Werror
''')
 sw=R/'sw/rv64/r88-linux-dma-v2'
 c.require(c.sha(sw/'rv64lab-dma-protocol.h')==gj['source_sha256']['sw/rv64/r88-linux-dma/rv64lab-dma-protocol.h'],'shared protocol differs from CPU-tested copy')
 for name,dst in [('rv64lab-dma.h','arch/riscv/include/asm/rv64lab-dma.h'),
   ('rv64lab-dma-protocol.h','arch/riscv/mm/rv64lab-dma-protocol.h'),
   ('rv64lab-dma.c','arch/riscv/mm/rv64lab-dma.c'),
   ('rv64lab-dma-selftest.c','arch/riscv/mm/rv64lab-dma-selftest.c')]:
  c.require(not (kernel/dst).exists(),'new overlay file exists');shutil.copy2(sw/name,kernel/dst);patches[dst]=c.sha(kernel/dst)
 c.emit(OUT/'upstream.patch',''.join(inputs.values()))
 emit(OUT/'overlay-manifest.json',dict(parent_source=str(original.relative_to(R)),parent_original_sha256=parents,ordinary_overlay_files_sha256=patches,
   unchanged_files='absolute symlink farm to locked existing Linux6.6.80 tree, no hardlinks; not a standalone full upstream archive'))
 build=OUT/'kernel-build';build.mkdir();shutil.copyfile(base/'kernel-build/.config',build/'.config')
 c.run('target-config',[kernel/'scripts/config','--file',build/'.config','--set-str','LOCALVERSION','-rv64lab-r88-linux-dma-r2',
   '--enable','RV64LAB_DMA','--enable','RV64LAB_DMA_SELFTEST'],timeout=30)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
   'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=linux-dma-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('kernel-config',kb+['olddefconfig'],timeout=120)
 config=(build/'.config').read_text()
 for n in ['RV64LAB_DMA','RV64LAB_DMA_SELFTEST','RISCV_DMA_NONCOHERENT','RISCV_NONSTANDARD_CACHE_OPS','DMA_GLOBAL_POOL','DMA_NONCOHERENT_MMAP','FPU','HVC_RISCV_SBI']:
  c.require('CONFIG_'+n+'=y\n' in config,'missing config '+n)
 c.require('CONFIG_RISCV_ISA_ZICBOM=y' not in config and 'CONFIG_DMA_DIRECT_REMAP=y' not in config,'unexpected fallback architecture')
 c.emit(OUT/'config.diff',''.join(difflib.unified_diff((base/'kernel-build/.config').read_text().splitlines(True),config.splitlines(True),fromfile='R72',tofile='R88')))
 source_files=[Path(__file__),R/'scripts/rv64/build_artifact_guard_v2.py',*sw.iterdir(),gate,base/'initramfs.cpio',base/'run-status.json',R/'build/rv64/linux/source-status.json']
 pins={str(p.relative_to(R)):c.sha(p) for p in source_files}
 for n in patches:
  p=OUT/'source'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(kernel/n,p)
 emit(OUT/'source-lock.json',pins)
 c.run('kernel-build',kb+['-j1','Image'],timeout=5400)
 c.require(pins=={n:c.sha(R/n) for n in pins},'input changed during build')
 for n,h in parents.items():c.require(c.sha(original/n)==h,'upstream source changed '+n)
 for n,h in patches.items():c.require(c.sha(kernel/n)==h,'overlay source changed '+n)
 for n,j in bj['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'base changed during build '+n)
 artifacts=[build/'.config',build/'arch/riscv/boot/Image',build/'vmlinux',OUT/'config.diff',OUT/'upstream.patch',OUT/'overlay-manifest.json']
 emit(OUT/'run-status.json',dict(status='PREPARED_R88_NONCOHERENT_DMA_KERNEL_NOT_BOOTED',
   source_sha256=pins,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in artifacts},
   overlay_files_sha256=patches,parent_original_sha256=parents,steps=c.STEPS,hardware_changed=False,
   physical_board_booted=False,own_rtl_booted=False,usb_accepted=False,hdmi_accepted=False,
   initramfs_sha256=c.sha(base/'initramfs.cpio'),scope='Independent Linux overlay + built-in DMA hooks/global physical uncached pool/API selftest driver. Reuses unchanged signed Debian userspace archive. No upstream original/global tool edits. Not boot/DMA/USB acceptance.'))
 print('PREPARED_R88_NONCOHERENT_DMA_KERNEL_NOT_BOOTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R88_LINUX_DMA_PREPARATION',error=str(ex),steps=c.STEPS))
  raise
