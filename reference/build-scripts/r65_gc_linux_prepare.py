#!/usr/bin/env python3
"""Targeted C/FPU Linux plus FP context test and signed Debian package overlay."""
import json,shutil,subprocess,re
from pathlib import Path
import integer_core_check as c
R=c.ROOT;OUT=R/'build/rv64/r65-gc-linux';c.OUT=OUT
OLD=R/'build/rv64/linux';P54=R/'build/rv64/r54-linux-board-prep';SW=R/'sw/rv64/r65-gc-linux'
KERNEL=OLD/'src/linux-6.6.80';BUILD=OUT/'kernel-build'
def run(tag,args,**kw):
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'disk budget')
 return c.run(tag,args,**kw)
def main():
 OUT.mkdir(parents=True,exist_ok=True);c.emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING_GC_LINUX_SOFTWARE_PREPARATION'))+'\n')
 sdk=json.loads((OLD/'sdk-status.json').read_text());prefix=Path(sdk['identity']['prefix'])
 c.require(c.sha(prefix/'lib/libc.a')==sdk['libc_sha256'],'pinned musl changed')
 c.require(c.sha(OLD/'static-musl.specs')==sdk['static_specs_sha256'],'pinned static specs changed')
 elf=OUT/'fp-context-test.elf';flags=sdk['identity']['flags'].replace('-march=rv64ima_zicsr_zifencei','-march=rv64imafdc_zicsr_zifencei').split()
 run('fp-context-build',[*sdk['compiler_command'],*flags,'-D__linux__=1','-D__unix__=1','-Wall','-Wextra','-Werror',SW/'fp-context.c',SW/'fp-registers.S','-o',elf])
 attrs=run('fp-context-attributes',[c.CROSS+'readelf','-h','-A',elf]);c.require('rv64i' in attrs and '_f' in attrs and '_d' in attrs and '_c' in attrs,'FP test ISA attributes')
 # Reuse the musl LP64 runtime (no FP instructions). The assembly tests all FPRs;
 # actual LP64D ABI was separately executed by R64, not inferred from this ELF.
 listing=(P54/'initramfs.list').read_text().splitlines();new=[]
 for line in listing:
  fields=line.split()
  if fields[:2]==['file','/init']:fields[2]=str(SW/'init')
  if fields[:2]==['file','/etc/rcS']:fields[2]=str(SW/'rcS')
  new.append(' '.join(fields))
 new.append(f'file /bin/fp-context-test {elf} 755 0 0')
 new+=(R/'build/rv64/r60-debian-package-prep/overlay.list').read_text().splitlines()
 c.emit(OUT/'initramfs.list','\n'.join(new)+'\n')
 with (OUT/'initramfs.cpio').open('wb') as f:subprocess.run([str(P54/'gen_init_cpio'),'-t','0',str(OUT/'initramfs.list')],stdout=f,check=True)
 for src in ['init','rcS']:run('shell-syntax-'+src,['sh','-n',SW/src])
 BUILD.mkdir(exist_ok=True);shutil.copyfile(P54/'kernel-build/.config',BUILD/'.config')
 run('kernel-options',[KERNEL/'scripts/config','--file',BUILD/'.config','-e','RISCV_ISA_C','-e','FPU','-e','HIGH_RES_TIMERS','-d','RISCV_ISA_V','-d','SMP','--set-str','INITRAMFS_SOURCE',OUT/'initramfs.cpio','--set-str','LOCALVERSION','-rv64lab-r65-gc'])
 kb=['make','-C',KERNEL,'O='+str(BUILD),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
  'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=gc-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 run('kernel-config',kb+['olddefconfig'])
 cfg=(BUILD/'.config').read_text()
 for name in ['FPU','RISCV_ISA_C','MMU','BINFMT_ELF','FUTEX','SIGNALFD','HIGH_RES_TIMERS']:
  c.require('CONFIG_'+name+'=y' in cfg,'kernel feature absent '+name)
 run('kernel-build',kb+['-j2','Image'],timeout=1800)
 image=BUILD/'arch/riscv/boot/Image';c.require(image.read_bytes()[48:56]==b'RISCV\0\0\0','Image magic')
 commands={};architectures=set()
 for p in BUILD.rglob('.*.cmd'):
  lines=p.read_text(errors='replace').splitlines()
  if not lines or c.CROSS+'gcc ' not in lines[0] or ' -c ' not in lines[0]:continue
  m=re.search(r'(?:^|\s)-march=([^\s]+)',lines[0]);c.require(m is not None and ' -mabi=lp64 ' in lines[0],'kernel compiler ABI absent')
  commands[str(p.relative_to(BUILD))]=c.sha(p);architectures.add(m[1])
 c.require(len(commands)>100,'compiler command coverage')
 c.emit(OUT/'compile-audit.json',json.dumps(dict(commands=commands,architectures=sorted(architectures)),indent=2)+'\n')
 dts=(P54/'simulation-only.dts').read_text().replace('rv64ima_zicsr_zifencei','rv64imafdc_zicsr_zifencei')
 dts=dts.replace('            mmu-type =', '            riscv,isa-base = \"rv64i\";\n            riscv,isa-extensions = \"i\", \"m\", \"a\", \"f\", \"d\", \"c\", \"zicsr\", \"zifencei\", \"zicntr\", \"svadu\";\n            mmu-type =')
 shutil.copyfile(P54/'boot-seed.bin',OUT/'boot-seed.bin')
 c.require('rv64imafdc_zicsr_zifencei' in dts,'DT ISA replace')
 c.emit(OUT/'simulation-only.dts',dts);run('dtb',['dtc','-I','dts','-O','dtb','-o',OUT/'simulation-only.dtb',OUT/'simulation-only.dts'])
 actual=run('dtb-isa',['fdtget',OUT/'simulation-only.dtb','/cpus/cpu@0','riscv,isa']);c.require('rv64imafdc' in actual,'DT ISA readback')
 files=[SW/'fp-context.c',SW/'fp-registers.S',SW/'rcS',SW/'init',Path(__file__)]
 report=dict(status='PASS_R65_GC_KERNEL_INITRAMFS_BUILT_NOT_BOOTED',linux_booted=False,
  fp_context_abi='LP64 musl static test with explicit F/D assembly; LP64D separately accepted by real RTL R64 probe',
  artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in [elf,image,OUT/'initramfs.cpio',OUT/'simulation-only.dtb',BUILD/'.config']},
  source_sha256={str(p.relative_to(R)):c.sha(p) for p in files},steps=c.STEPS)
 c.emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n');print(report['status'],flush=True)
if __name__=='__main__':main()
