#!/usr/bin/env python3
"""Independent Linux/HVC image with signed minimal Debian initramfs, not booted."""
import difflib,json,re,shutil,subprocess
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r72-debian-hvc-r5';c.OUT=OUT
guard.install(c,Path(__file__),'r72-debian-hvc-r5');CREATED=False
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous kernel output')
 OUT.mkdir(parents=True);CREATED=True
 c.emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING_R72_DEBIAN_HVC_KERNEL_PREPARATION'))+'\n')
 base=R/'build/rv64/r69-gc-tty';rootfs=R/'build/rv64/r71-debian-minimal-r3'
 parent=json.loads((base/'run-status.json').read_text());deb=json.loads((rootfs/'run-status.json').read_text())
 c.require(parent['status']=='PASS_R69_TTY_DRAIN_KERNEL_PREPARED_NOT_BOOTED','parent kernel missing')
 c.require(deb['status']=='PREPARED_SIGNED_DEBIAN_MINIMAL_INITRAMFS_NOT_EXECUTED','rootfs missing')
 for n,j in parent['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'parent image/config stale '+n)
 for n,h in deb['source_sha256'].items():c.require(c.sha(R/n)==h,'rootfs generator changed '+n)
 cpio=R/deb['cpio']['path'];c.require(c.sha(cpio)==deb['cpio']['sha256'],'Debian initramfs changed')
 sw=R/'sw/rv64/r72-debian-hvc-r3'
 # Rebuild one archive from the checked base manifest, adding only project
 # init/validation helpers and absent BusyBox command symlinks.
 for rel,entry in deb['rootfs_manifest'].items():
  p=rootfs/'rootfs'/rel.lstrip('/')
  if 'sha256' in entry:c.require(c.sha(p)==entry['sha256'],'rootfs base file changed '+rel)
  else:c.require(p.is_symlink() and p.readlink().as_posix()==entry['link'],'rootfs base link changed '+rel)
 old_cpio=(base/'initramfs.cpio').read_bytes()
 helper=R/'build/rv64/r54-linux-board-prep/rootfs/bin/linux-selftest'
 old_helper=subprocess.check_output(['cpio','--quiet','-i','--to-stdout','bin/linux-selftest'],input=old_cpio)
 c.require(helper.read_bytes()==old_helper and len(old_helper)>1000,'accepted process/MMU helper changed')
 fpbase=R/'build/rv64/r65-gc-linux';fpj=json.loads((fpbase/'run-status.json').read_text())
 fp=fpbase/'fp-context-test.elf';drain=base/'tty-drain.elf'
 c.require(c.sha(fp)==fpj['artifacts']['fp-context-test.elf']['sha256'],'FP helper changed')
 c.require(c.sha(drain)==parent['artifacts']['tty-drain.elf']['sha256'],'TTY drain helper changed')
 helpers={'rv64-selftest':helper,'rv64-fp-context':fp,'tty-drain':drain}
 helper_headers=c.run('validation-helpers-static-audit',[c.CROSS+'readelf','-l',*helpers.values()],timeout=30)
 c.require('Requesting program interpreter' not in helper_headers,'validation helpers must be static')
 lines=[];paths=set()
 for line in (rootfs/'initramfs.list').read_text().splitlines():
  fields=line.split();paths.add(fields[1])
  if fields[:2]==['file','/etc/init.d/rcS']:fields[2]=str(sw/'rcS')
  if fields[:2]==['file','/etc/inittab']:fields[2]=str(sw/'inittab')
  lines.append(' '.join(fields))
 for directory in ['/usr/local','/usr/local/libexec']:
  if directory not in paths:lines.append(f'dir {directory} 0755 0 0');paths.add(directory)
 profile=rootfs/'rootfs/usr/share/base-files/profile'
 c.require('/etc/profile' not in paths,'profile already exists')
 c.require(c.sha(profile)==deb['rootfs_manifest']['/usr/share/base-files/profile']['sha256'],'official profile template changed')
 lines.append(f'file /etc/profile {profile} 0644 0 0')
 c.run('official-profile-syntax',['sh','-n',profile],timeout=10)
 for name,path in helpers.items():lines.append(f'file /usr/local/libexec/{name} {path} 0755 0 0')
 applets='cat ls mkdir mount umount chmod sync uname id tty cp rm mv dmesg ps sleep stty printf test env poweroff reboot halt'.split()
 for name in applets:
  if '/usr/bin/'+name not in paths:lines.append(f'slink /usr/bin/{name} busybox 0777 0 0')
 if '/usr/bin/awk' not in paths:lines.append('slink /usr/bin/awk mawk 0777 0 0')
 c.require('/dev/hvc0' not in paths,'hvc0 node already exists')
 lines.append('nod /dev/hvc0 0600 0 0 c 229 0')
 hvc=R/'build/rv64/linux/src/linux-6.6.80/drivers/tty/hvc/hvc_console.c'
 c.require(re.search(r'#define HVC_MAJOR\s+229',hvc.read_text()) is not None and re.search(r'#define HVC_MINOR\s+0',hvc.read_text()) is not None,'HVC device numbers changed')
 c.emit(OUT/'initramfs.list','\n'.join(lines)+'\n')
 c.run('rcS-syntax',['sh','-n',sw/'rcS'],timeout=10)
 tool=R/'build/rv64/r54-linux-board-prep/gen_init_cpio'
 c.require(c.sha(tool)==deb['cpio']['gen_init_cpio_sha256'],'cpio tool changed')
 cpio=OUT/'initramfs.cpio'
 with cpio.open('wb') as f:subprocess.run([tool,'-t','0',OUT/'initramfs.list'],stdout=f,check=True)
 members=subprocess.check_output(['cpio','-it','--quiet'],input=cpio.read_bytes()).decode().splitlines()
 c.require(all('usr/local/libexec/'+name in members for name in helpers),'missing validation helper')
 prepared_cpio=dict(path=str(cpio.relative_to(R)),bytes=cpio.stat().st_size,sha256=c.sha(cpio),
  official_packages_unchanged=True,project_validation_helpers={name:c.sha(path) for name,path in helpers.items()},
  base_debian_cpio=deb['cpio'])
 elfs=[]
 for entry in deb['elfs']:
  p=rootfs/'rootfs'/entry['path'];c.require(c.sha(p)==entry['sha256'],'official ELF changed '+entry['path']);elfs.append(p)
 attrs=c.run('official-elf-isa-audit',[c.CROSS+'readelf','-h','-A',*elfs],timeout=90)
 arches=re.findall(r'Tag_RISCV_arch:\s*"([^"]+)"',attrs)
 c.require(len(arches)==len(elfs),'ELF architecture tag missing')
 allowed={'m','a','f','d','c','zicsr','zifencei','zmmul','zaamo','zalrsc'}
 for arch in arches:
  parts=arch.split('_');c.require(re.fullmatch(r'rv64i\d+p\d+',parts[0]) is not None,'unexpected base ISA '+arch)
  for part in parts[1:]:
   match=re.fullmatch(r'([a-z]+)\d+p\d+',part)
   c.require(match is not None and match[1] in allowed,'unsupported extension '+part)
 isa_audit=dict(elf_count=len(elfs),unique_arches=sorted(set(arches)),
  subset_aliases='Zmmul is covered by M; Zaamo/Zalrsc by A; this is a static attribute audit, not target execution')
 kernel=R/'build/rv64/linux/src/linux-6.6.80';build=OUT/'kernel-build'
 old=R/'build/rv64/r72-debian-hvc-r2';oldj=json.loads((old/'run-status.json').read_text())
 c.require(oldj['status']=='PREPARED_R72_LINUX_DEBIAN_HVC_NOT_BOOTED','cached kernel parent absent')
 for n,entry in oldj['artifacts'].items():c.require(c.sha(old/n)==entry['sha256'],'cached kernel artifact changed '+n)
 # Independent ordinary copies. Never hardlink mutable build outputs to evidence.
 c.require((old/'kernel-build/source').is_symlink(),'kernel cache must retain source symlink')
 shutil.copytree(old/'kernel-build',build,copy_function=shutil.copy2,symlinks=True)
 c.require((build/'source').is_symlink() and (build/'source').resolve()==kernel.resolve(),'kernel source link changed')
 shutil.copyfile(base/'kernel-build/.config',build/'.config')
 c.run('target-config',[kernel/'scripts/config','--file',build/'.config',
  '--set-str','LOCALVERSION','-rv64lab-r72-debian-hvc-r5','--set-str','INITRAMFS_SOURCE',cpio,
  '--enable','RISCV_SBI_V01','--enable','HVC_RISCV_SBI',
  '--disable','SERIAL_8250','--disable','SERIAL_8250_CONSOLE','--disable','SERIAL_OF_PLATFORM',
  '--disable','SERIAL_XILINX_PS_UART','--disable','SERIAL_XILINX_PS_UART_CONSOLE'],timeout=30)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
  'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=debian-hvc-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('kernel-config',kb+['olddefconfig'],timeout=90)
 config=(build/'.config').read_text()
 required=['RISCV_SBI','RISCV_SBI_V01','HVC_RISCV_SBI','HVC_DRIVER','FPU','RISCV_ISA_C','DEVTMPFS','FUTEX']
 for name in required:c.require('CONFIG_'+name+'=y\n' in config,'required kernel feature absent '+name)
 for name in ['SERIAL_8250','SERIAL_XILINX_PS_UART']:c.require('CONFIG_'+name+'=y\n' not in config,'native UART competing with firmware')
 diff=''.join(difflib.unified_diff((base/'kernel-build/.config').read_text().splitlines(True),config.splitlines(True),fromfile='R69',tofile='R72'))
 c.emit(OUT/'config.diff',diff)
 source_files=[Path(__file__),sw/'rcS',sw/'inittab',hvc,*helpers.values(),kernel/'scripts/config',kernel/'drivers/tty/hvc/Kconfig',kernel/'drivers/tty/hvc/hvc_riscv_sbi.c',kernel/'arch/riscv/Kconfig',kernel/'arch/riscv/kernel/fpu.S']
 before={str(p.relative_to(R)):c.sha(p) for p in source_files}
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'kernel disk gate')
 c.run('kernel-build',kb+['-j1','Image'],timeout=3600)
 profile=R/'build/rv64/r67-gc50-profile-r2';pj=json.loads((profile/'model-status.json').read_text())
 for name in ['simulation-only.dts','boot-seed.bin']:c.require(c.sha(profile/name)==pj['input_sha256'][name],'frozen DT changed')
 dts=(profile/'simulation-only.dts').read_text();old='console=ttyS0,115200 earlycon=uart8250,mmio,0x10000000'
 c.require(dts.count(old)==1,'simulation DT console anchor')
 c.emit(OUT/'simulation-only-hvc.dts',dts.replace(old,'console=hvc0 earlycon=sbi'))
 shutil.copyfile(profile/'boot-seed.bin',OUT/'boot-seed.bin')
 c.run('dtc-simulation-only',['dtc','-I','dts','-O','dtb','-o',OUT/'simulation-only-hvc.dtb',OUT/'simulation-only-hvc.dts'],timeout=30)
 c.require(before=={n:c.sha(R/n) for n in before},'source changed during kernel build')
 for n,j in parent['artifacts'].items():c.require(c.sha(base/n)==j['sha256'],'parent modified by build')
 c.require(c.sha(cpio)==prepared_cpio['sha256'],'rootfs modified during build')
 artifacts=[cpio,OUT/'initramfs.list',build/'.config',build/'arch/riscv/boot/Image',build/'vmlinux',OUT/'simulation-only-hvc.dts',OUT/'simulation-only-hvc.dtb',OUT/'boot-seed.bin']
 report=dict(status='PREPARED_R72_LINUX_DEBIAN_HVC_NOT_BOOTED',kernel='6.6.80-rv64lab-r72-debian-hvc-r5',
  initramfs=prepared_cpio,official_elf_isa_audit=isa_audit,console='SBI legacy HVC hvc0; UART owned by OpenSBI',
  device_tree='simulation-only 16550 stdout for OpenSBI; not the physical Cadence board DT',
  physical_board_booted=False,own_rtl_booted=False,source_sha256=before,
  parent_status_sha256=c.sha(base/'run-status.json'),debian_status_sha256=c.sha(rootfs/'run-status.json'),
  software_source_status_sha256=c.sha(R/'build/rv64/linux/source-status.json'),
  artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in artifacts},steps=c.STEPS)
 c.emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n');print(report['status'],flush=True)
if __name__=='__main__':
 try:main()
 except Exception as e:
  if CREATED:c.emit(OUT/'run-status.json',json.dumps(dict(status='FAIL_R72_DEBIAN_HVC_PREPARATION',error=str(e),steps=c.STEPS),indent=2)+'\n')
  raise
