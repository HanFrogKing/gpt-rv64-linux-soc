#!/usr/bin/env python3
"""New initramfs retaining R108 tests and signed official modetest; no target run."""
import json,shutil,subprocess
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r109-graphics-userspace-r2';c.OUT=OUT
guard.install(c,Path(__file__),'r109-graphics-userspace-r2')
def emit(j):c.emit(OUT/'run-status.json',json.dumps(j,indent=2)+'\n')
def main():
 c.require(not OUT.exists(),'preserve attempt');OUT.mkdir(parents=True)
 emit(dict(status='RUNNING_R109_USERSPACE_PREPARATION_NOT_EXECUTED'))
 base=R/'build/rv64/r108-drm-userspace-r5';bj=json.loads((base/'run-status.json').read_text())
 graphics=R/'build/rv64/r108-graphics-package-prep-r2';gj=json.loads((graphics/'run-status.json').read_text())
 c.require(gj['status']=='PREPARED_SIGNED_OFFICIAL_MODETEST_OVERLAY_AND_NATIVE_APT_DESKTOP_PLAN_NOT_EXECUTED','signed package preparation')
 for n,a in bj['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent '+n)
 for n,h in gj['source_sha256'].items():c.require(c.sha(R/n)==h,'graphics source '+n)
 for d in gj['downloaded_diagnostic_packages']:c.require(c.sha(R/d['path'])==d['sha256'],'official deb '+d['package'])
 c.require(c.sha(R/gj['overlay']['path'])==gj['overlay']['sha256'],'official overlay')
 probe=R/'sw/rv64/r109-graphics/x11-ipc-probe-v2.c';wrapper=R/'sw/rv64/r108-graphics-preparation/modetest-inventory.sh'
 sdk=R/'build/rv64/linux/sdk-status.json';sj=json.loads(sdk.read_text());elf=OUT/'x11-ipc-probe.elf'
 compiler=sj['compiler_command']+sj['identity']['flags'].split()+['-D__linux__=1','-D__unix__=1','-Wall','-Wextra','-Werror','-static']
 c.run('target-probe-build',compiler+[probe,'-o',elf],timeout=120)
 c.run('probe-elf-audit',[c.CROSS+'readelf','-h','-A','-l',elf])
 c.run('host-probe-build',['gcc','-O2','-Wall','-Wextra','-Werror',probe,'-o',OUT/'host-ipc-probe'])
 c.run('host-probe-only-not-target',[OUT/'host-ipc-probe'],timeout=30)
 c.run('wrapper-syntax',['sh','-n',wrapper])
 lines=(base/'initramfs.list').read_text().splitlines();seen={l.split()[1]:l for l in lines}
 for line in (graphics/'overlay.list').read_text().splitlines():
  fields=line.split();path=fields[1]
  if path in seen:
   c.require(fields[0]=='dir' and seen[path].split()[0]=='dir','overlay collision '+path);continue
  lines.append(line);seen[path]=line
 anchor='echo DEBIAN_MINIMAL_INIT_END\n';old=(base/'rcS').read_text();c.require(old.count(anchor)==1,'rcS boundary')
 insert='/usr/local/libexec/rv64-x11-ipc-probe || fail x11-ipc\necho R109_MODETEST_BEGIN\n/bin/busybox timeout 30 /usr/local/libexec/rv64-modetest-inventory || fail official-modetest\necho R109_MODETEST_END rc=0\necho R109_GRAPHICS_PREREQUISITES_PASS official_modetest=1 unix_path=1 sysv_shm=1 inotify=1 desktop=0\n'
 rc=OUT/'rcS';rc.write_text(old.replace(anchor,insert+anchor));c.run('rcS-syntax',['sh','-n',rc])
 replaced=0
 for i,line in enumerate(lines):
  f=line.split()
  if f[:2]==['file','/etc/init.d/rcS']:f[2]=str(rc);lines[i]=' '.join(f);replaced+=1
 c.require(replaced==1,'one init replacement')
 for path,p in [('/usr/local/libexec/rv64-x11-ipc-probe',elf),('/usr/local/libexec/rv64-modetest-inventory',wrapper)]:
  c.require(path not in seen,'target path collision');lines.append(f'file {path} {p} 0755 0 0')
 listing=OUT/'initramfs.list';listing.write_text('\n'.join(lines)+'\n')
 archive=OUT/'initramfs.cpio';tool=R/'build/rv64/r54-linux-board-prep/gen_init_cpio'
 with archive.open('wb') as f:subprocess.run([tool,'-t','0',listing],stdout=f,check=True)
 members=subprocess.check_output(['cpio','-it','--quiet'],input=archive.read_bytes()).decode().splitlines()
 c.require(len(members)==len(set(members)),'duplicate archive members')
 # Compare every file/link/directory against its exact manifest entry, using
 # a private extraction. Device nodes are listed, never created on the host.
 unpack=OUT/'roundtrip';unpack.mkdir()
 patterns=OUT/'roundtrip-members.txt'
 patterns.write_text('\n'.join(l.split()[1].lstrip('/') for l in lines if l.split()[0]!='nod')+'\n')
 c.run('cpio-roundtrip',['bash','-c','cd "$2" && cpio --quiet -id --no-absolute-filenames --pattern-file="$3" < "$1"','r109',archive,unpack,patterns],timeout=60)
 for line in lines:
  f=line.split();p=unpack/f[1].lstrip('/')
  if f[0]=='file':c.require(p.read_bytes()==Path(f[2]).read_bytes(),'archive file '+f[1])
  elif f[0]=='slink':c.require(p.is_symlink() and str(p.readlink())==f[2],'archive link '+f[1])
  elif f[0]=='dir':c.require(p.is_dir(),'archive directory '+f[1])
 for name in 'ABC':shutil.copyfile(base/('frame-'+name+'.bin'),OUT/('frame-'+name+'.bin'))
 inputs=[Path(__file__),probe,wrapper,sdk,base/'run-status.json',base/'initramfs.cpio',base/'initramfs.list',base/'rcS',graphics/'run-status.json',graphics/'overlay.list',R/gj['overlay']['path'],R/'scripts/rv64/build_artifact_guard_v2.py']
 inputs += [Path(l.split()[2]) for l in lines if l.split()[0]=='file' and Path(l.split()[2]).is_relative_to(R)]
 inputs += [R/d['path'] for d in gj['downloaded_diagnostic_packages']]
 pins={str(p.relative_to(R)):c.sha(p) for p in inputs};pins.update(bj['source_sha256']);pins.update(gj['source_sha256'])
 artifacts=[elf,rc,listing,archive]+list(OUT.glob('frame-*.bin'))
 emit(dict(status='PREPARED_R109_SIGNED_GRAPHICS_INITRAMFS_NOT_TARGET_EXECUTED',source_sha256=pins,artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in artifacts},steps=c.STEPS,official_modetest_sha256=c.sha(graphics/'official-modetest-root/usr/bin/modetest'),host_IPC_is_target_acceptance=False,target_executed=False,board_deployed=False,desktop=False))
 print('PREPARED_R109_SIGNED_GRAPHICS_INITRAMFS_NOT_TARGET_EXECUTED',flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if OUT.exists():emit(dict(status='FAIL_R109_GRAPHICS_USERSPACE_PREPARATION',error=str(ex),steps=c.STEPS))
  raise
