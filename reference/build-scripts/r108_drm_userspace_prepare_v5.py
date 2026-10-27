#!/usr/bin/env python3
"""Compile target DRM test + independent images + signed-Debian initramfs.
No target execution, installation, global SDK changes or media I/O.
"""
import json,shutil,subprocess,zlib
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r108-drm-userspace-r5';c.OUT=OUT;CREATED=False
guard.install(c,Path(__file__),'r108-drm-userspace-r5')
def emit(p,j):c.emit(p,json.dumps(j,indent=2)+'\n')
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve previous preparation');OUT.mkdir();CREATED=True
 sdk=R/'build/rv64/linux/sdk-status.json';sj=json.loads(sdk.read_text())
 c.require(sj['status']=='PASS_STATIC_LIBC_BUILD_NOT_BOOTED','existing SDK')
 libc=Path(sj['identity']['prefix'])/'lib/libc.a';specs=R/'build/rv64/linux/static-musl.specs'
 c.require(c.sha(libc)==sj['libc_sha256'] and c.sha(specs)==sj['static_specs_sha256'],'SDK changed')
 source=R/'sw/rv64/r108-linux-drm/drm-selftest-v4.c';pattern=R/'sw/rv64/r107-linux-scanout/pattern.h'
 base=R/'build/rv64/r72-debian-hvc-r5';bj=json.loads((base/'run-status.json').read_text())
 for n in ['initramfs.list','initramfs.cpio']:
  c.require(c.sha(base/n)==bj['artifacts'][n]['sha256'],'accepted Debian archive changed '+n)
 pdir=OUT/'source';pdir.mkdir();shutil.copy2(source,pdir/source.name);shutil.copy2(pattern,pdir/'pattern.h')
 compiler=sj['compiler_command']+sj['identity']['flags'].split()+['-D__linux__=1','-D__unix__=1','-Wall','-Wextra','-Werror','-static']
 elf=OUT/'drm-selftest.elf';c.run('compile-real-drm-ioctl-test',compiler+[source,'-o',elf],timeout=120)
 audit=c.run('elf-audit',[c.CROSS+'readelf','-h','-A','-l',elf],timeout=30)
 data=elf.read_bytes();c.require(data[:6]==b'ELF' and int.from_bytes(data[18:20],'little')==243 and int.from_bytes(data[48:52],'little')&6==0 and 'Requesting program interpreter' not in audit,'target static ELF class/machine/actual soft-float ABI flag')
 reference=R/'build/rv64/r107-pattern-r1';pj=json.loads((reference/'run-status.json').read_text())
 a=(reference/'frame.bin').read_bytes();c.require(len(a)==1920000 and c.sha(reference/'frame.bin')==pj['sha256']=='ef26040b7bebcd4f158bc82d491334437b4e570857b589d7a370df74b11832b8','independent accepted R107 pattern')
 for n,h in pj['source_sha256'].items():c.require(c.sha(R/n)==h,'pattern source changed '+n)
 b=bytearray(a)
 for i in range(0,len(b),4):
  for lane in range(3):b[i+lane]^=255
 d=bytearray(b)
 for y in range(51,58):
  for x in range(37,46):d[(y*800+x)*4:(y*800+x+1)*4]=(0x5a24d9af).to_bytes(4,'little')
 references={}
 for name,data in [('A',a),('B',b),('C',d),('black',bytes(len(a)))]:
  p=OUT/('frame-'+name+'.bin');p.write_bytes(data);references[name]=dict(bytes=len(data),sha256=c.sha(p),crc32=f'{zlib.crc32(data):08x}')
 # Reuse all official files, original process/MMU/FP/TTY tests and exact
 # manifest. Replace only custom rcS; add one project target test ELF.
 rc=R/'sw/rv64/r72-debian-hvc-r3/rcS';old=rc.read_text();anchor='echo DEBIAN_MINIMAL_INIT_END\n'
 c.require(old.count(anchor)==1,'rcS anchor')
 insert='/usr/local/libexec/rv64-drm-selftest || fail drm-kms\n/bin/busybox cat /sys/class/graphics/fb0/name || fail fbdev-sysfs\n/bin/busybox cat /sys/bus/platform/devices/4000000.scanout/scanout_state || fail drm-state\n/bin/busybox grep -q "qualified=1 failed=0.*retained=1" /sys/bus/platform/devices/4000000.scanout/scanout_state || fail scanout-health\n'
 custom=OUT/'rcS';custom.write_text(old.replace(anchor,insert+anchor));c.run('rcS-syntax',['sh','-n',custom],timeout=10)
 lines=[];found=0
 for line in (base/'initramfs.list').read_text().splitlines():
  fields=line.split()
  if fields[:2]==['file','/etc/init.d/rcS']:fields[2]=str(custom);found+=1
  c.require(fields[1]!='/usr/local/libexec/rv64-drm-selftest','ELF member collision')
  lines.append(' '.join(fields))
 c.require(found==1,'one init replacement')
 lines.append(f'file /usr/local/libexec/rv64-drm-selftest {elf} 0755 0 0')
 listing=OUT/'initramfs.list';listing.write_text('\n'.join(lines)+'\n')
 tool=R/'build/rv64/r54-linux-board-prep/gen_init_cpio';archive=OUT/'initramfs.cpio'
 with archive.open('wb') as f:subprocess.run([tool,'-t','0',listing],stdout=f,check=True)
 members=subprocess.check_output(['cpio','-it','--quiet'],input=archive.read_bytes()).decode().splitlines()
 oldmembers=subprocess.check_output(['cpio','-it','--quiet'],input=(base/'initramfs.cpio').read_bytes()).decode().splitlines()
 c.require(set(members)==set(oldmembers)|{'usr/local/libexec/rv64-drm-selftest'},'rootfs members unexpectedly changed')
 # Verify every retained member byte with the real archive reader, including
 # official Debian ELF/loader and original project validation programs.
 for member in oldmembers:
  if member=='etc/init.d/rcS':continue
  olddata=subprocess.check_output(['cpio','--quiet','-i','--to-stdout',member],input=(base/'initramfs.cpio').read_bytes(),stderr=subprocess.DEVNULL)
  newdata=subprocess.check_output(['cpio','--quiet','-i','--to-stdout',member],input=archive.read_bytes(),stderr=subprocess.DEVNULL)
  c.require(olddata==newdata,'retained archive member changed '+member)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),source,pattern,sdk,specs,base/'run-status.json',base/'initramfs.list',base/'initramfs.cpio',rc,reference/'run-status.json',R/'scripts/rv64/build_artifact_guard_v2.py']}
 artifacts=[elf,custom,listing,archive]+list(OUT.glob('frame-*.bin'))
 emit(OUT/'run-status.json',dict(status='PREPARED_R108_STATIC_DRM_TEST_AND_DEBIAN_INITRAMFS_NOT_EXECUTED',source_sha256=pins,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in artifacts},frame_references=references,retained_archive_members_identical=len(oldmembers)-1,steps=c.STEPS,own_rtl_executed=False,board_executed=False,SDK_reused=True,media_writes=False,scope='Compiled target ioctl test and deterministic reference data only. No libdrm/QEMU emulation substituted for actual Linux. Negative DRM modesets/format, padded pitch+offset, partial damage, software event and graphical console write still require real target execution.'))
 print('PREPARED_R108_STATIC_DRM_TEST_AND_DEBIAN_INITRAMFS_NOT_EXECUTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if CREATED:emit(OUT/'run-status.json',dict(status='FAIL_R108_DRM_USERSPACE_PREPARATION',error=str(ex),steps=c.STEPS))
  raise
