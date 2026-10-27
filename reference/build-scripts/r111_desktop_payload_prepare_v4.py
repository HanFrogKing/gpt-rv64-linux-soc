#!/usr/bin/env python3
"""Signed Debian desktop payload as an ordinary read-only filesystem file.

Not a configured installed distribution. No maintainer scripts or target ELF
execute on the host. Existing R109 boot/probes stay byte-identical.
"""
from pathlib import Path,PurePosixPath
import hashlib,json,os,posixpath,re,shutil,stat,subprocess,traceback
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r111-desktop-payload-r4';c.OUT=OUT
HOST=Path('${HOST_OUTPUTS}/rv64-r111-desktop-image-r4')
PACK=HOST.parent/'rv64-r110-desktop-package-prep-r2'
guard.install(c,Path(__file__),'r111-desktop-payload-r4')
def sha(p):
 h=hashlib.sha256()
 with Path(p).open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def emit(j):c.emit(OUT/'run-status.json',json.dumps(j,indent=2)+'\n')
def target(root,name):
 """Resolve absolute guest symlinks inside root, never against host /usr."""
 parts=list(PurePosixPath('/'+name.lstrip('/')).parts[1:]);done=[];hops=0
 while parts:
  part=parts.pop(0)
  if part in ('','.'):continue
  if part=='..':
   c.require(bool(done),'guest path underflow');done.pop();continue
  p=root.joinpath(*done,part)
  if p.is_symlink():
   hops+=1;c.require(hops<=40,'guest symlink loop')
   link=os.readlink(p)
   if link.startswith('/'):done=[]
   parts=list(PurePosixPath(link).parts)+(parts)
   if parts and parts[0]=='/':parts.pop(0)
  else:done.append(part)
 return root.joinpath(*done)
def inventory(root):
 entries={}
 for base,dirs,files in os.walk(root,followlinks=False):
  for name in sorted(dirs+files):
   p=Path(base)/name;n='/'+p.relative_to(root).as_posix();s=p.lstat();mode=stat.S_IMODE(s.st_mode)
   if p.is_symlink():entries[n]=dict(type='link',mode=mode,target=os.readlink(p))
   elif p.is_dir():entries[n]=dict(type='dir',mode=mode)
   elif p.is_file():entries[n]=dict(type='file',mode=mode,bytes=s.st_size,sha256=sha(p))
   else:raise RuntimeError('unexpected payload type '+n)
 return entries
def write_guest(root,name,text,mode=0o644):
 p=target(root,name);c.require(not p.exists() and not p.is_symlink(),'new file only '+name)
 p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(mode)
def main():
 c.require(not OUT.exists() and not HOST.exists(),'preserve attempts')
 c.require(shutil.disk_usage('/mnt/e').free>=10*1024**3 and shutil.disk_usage('/').free>=5*1024**3 and shutil.disk_usage('/mnt/c').free>=3*1024**3,'space reserve')
 OUT.mkdir(parents=True);HOST.mkdir();emit(dict(status='RUNNING_DESKTOP_PAYLOAD_NOT_CONFIGURED_OR_EXECUTED'))
 prep=R/'build/rv64/r110-desktop-package-prep-r2/run-status.json';pj=json.loads(prep.read_text())
 c.require(pj['status']=='PREPARED_SIGNED_OFFICIAL_DESKTOP_DEBS_NOT_UNPACKED_INSTALLED_OR_EXECUTED' and pj['package_count']==228,'signed package set')
 base=R/'build/rv64/r109-graphics-userspace-r2';bj=json.loads((base/'run-status.json').read_text())
 for n,h in bj['source_sha256'].items():c.require(sha(R/n)==h,'base source '+n)
 for n,a in bj['artifacts'].items():c.require(sha(base/n)==a['sha256'],'base artifact '+n)
 for pkg in pj['packages']:
  p=Path(pkg['path']);c.require(p.stat().st_size==pkg['bytes'] and sha(p)==pkg['sha256'],'signed DEB '+pkg['package'])
 root=OUT/'rootfs';root.mkdir()
 lines=[x.split() for x in (base/'initramfs.list').read_text().splitlines() if x.strip()]
 # Create directories and guest-only links/files. No device nodes on host.
 for f in lines:
  if f[0]=='dir':p=target(root,f[1]);p.mkdir(parents=True,exist_ok=True);p.chmod(int(f[2],8))
 for f in lines:
  if f[0]=='slink':
   p=target(root,str(PurePosixPath(f[1]).parent))/PurePosixPath(f[1]).name;p.parent.mkdir(parents=True,exist_ok=True);p.symlink_to(f[2])
 for f in lines:
  if f[0]=='file':
   p=target(root,f[1]);p.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(f[2],p);p.chmod(int(f[3],8))
 baseline=inventory(root);preserved={}
 for f in lines:
  if f[0]=='file':preserved[f[1]]=sha(Path(f[2]))
 # Standard dpkg-deb only extracts signed data payloads; no host install or
 # dpkg configuration. Log each package to retain exact failure provenance.
 for index,pkg in enumerate(pj['packages']):
  c.run('extract-'+pkg['package'],['dpkg-deb','--extract',pkg['path'],root],timeout=60)
 for n,h in preserved.items():c.require(sha(target(root,n))==h,'retained accepted base file '+n)
 cfg='''Section "ServerFlags"
    Option "AutoAddDevices" "false"
EndSection
Section "Files"
    FontPath "/tmp/rv64-fonts"
EndSection
Section "Device"
    Identifier "RV64 modesetting"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
    Option "PageFlip" "false"
EndSection
Section "Screen"
    Identifier "RV64 screen"
    Device "RV64 modesetting"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "800x600"
    EndSubSection
EndSection
'''
 write_guest(root,'/etc/X11/xorg-rv64lab.conf',cfg)
 startup='''#!/bin/busybox sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export XDG_RUNTIME_DIR=/tmp/rv64-runtime
export XDG_CACHE_HOME=/tmp/rv64-cache
export XDG_CONFIG_HOME=/tmp/rv64-config
export XAUTHORITY=/tmp/rv64-Xauthority
/bin/busybox mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" /tmp/rv64-fonts
/bin/busybox chmod 700 "$XDG_RUNTIME_DIR"
for f in /usr/share/fonts/X11/misc/*.pcf.gz; do
    /bin/busybox ln -sf "$f" /tmp/rv64-fonts/
done
if test -f /etc/X11/fonts/misc/xfonts-base.alias; then
    /bin/busybox cp /etc/X11/fonts/misc/xfonts-base.alias /tmp/rv64-fonts/fonts.alias
fi
/usr/bin/mkfontdir /tmp/rv64-fonts
echo RV64_DESKTOP_LAUNCH_ATTEMPT_NOT_ACCEPTANCE
exec /usr/bin/xinit /usr/local/libexec/rv64-openbox-session -- /usr/lib/xorg/Xorg :0 vt1 -config /etc/X11/xorg-rv64lab.conf -nolisten tcp -noreset -logfile /tmp/Xorg.0.log
'''
 session='''#!/bin/busybox sh
set -eu
/usr/bin/xsetroot -solid '#203040'
/usr/bin/xterm -geometry 80x24+8+8 -title 'Self-designed RV64 Debian' &
exec /usr/bin/openbox --sm-disable
'''
 write_guest(root,'/usr/local/sbin/rv64-desktop-session',startup,0o755)
 write_guest(root,'/usr/local/libexec/rv64-openbox-session',session,0o755)
 for name in ['rv64-desktop-session','rv64-openbox-session']:
  p=target(root,'/usr/local/'+('sbin/' if name=='rv64-desktop-session' else 'libexec/')+name)
  c.run('syntax-'+name,['sh','-n',p])
 # No fabricated package database/alternatives, no target font generation.
 # Explicit launch paths avoid alternatives until target configuration.
 critical=['/usr/lib/xorg/Xorg','/usr/lib/xorg/modules/drivers/modesetting_drv.so','/usr/bin/openbox','/usr/bin/xterm','/usr/bin/xinit','/usr/bin/xauth','/usr/bin/xsetroot','/usr/bin/mkfontdir','/usr/bin/mkfontscale','/usr/bin/xkbcomp','/usr/share/X11/xkb/rules/evdev','/etc/X11/fonts/misc/xfonts-base.alias']
 for name in critical:c.require(target(root,name).is_file(),'desktop payload path '+name)
 entries=inventory(root);elfs={};unresolved=[];regular=0
 library_dirs=['/usr/lib/riscv64-linux-gnu','/usr/lib','/lib/riscv64-linux-gnu','/lib']
 for n,a in entries.items():
  if a['type']!='file':continue
  regular+=1;p=target(root,n)
  with p.open('rb') as file:head=file.read(64)
  if not head.startswith(b'\x7fELF'):continue
  c.require(head[4:6]==b'\x02\x01' and int.from_bytes(head[18:20],'little')==243,'ELF RISC-V LP64 '+n)
  text=subprocess.check_output(['readelf','-l','-d',str(p)],text=True,stderr=subprocess.DEVNULL)
  needed=re.findall(r'\(NEEDED\).*?\[([^\]]+)\]',text)
  interpreter=re.findall(r'Requesting program interpreter: ([^\]]+)\]',text)
  for interp in interpreter:c.require(target(root,interp).is_file(),'ELF interpreter '+n)
  resolved={}
  runpaths=re.findall(r'\((?:RUNPATH|RPATH)\).*?\[([^\]]+)\]',text)
  search=[]
  for group in runpaths:
   for d in group.split(':'):
    d=d.replace('${ORIGIN}',str(PurePosixPath(n).parent)).replace('$ORIGIN',str(PurePosixPath(n).parent))
    c.require(d.startswith('/') and '$' not in d,'explicit supported loader path '+n)
    search.append(posixpath.normpath(d))
  for lib in needed:
   found=next((d+'/'+lib for d in search+library_dirs if target(root,d+'/'+lib).is_file()),None)
   if found is None:unresolved.append(dict(file=n,needed=lib))
   else:resolved[lib]=found
  elfs[n]=dict(interpreter=interpreter,needed=resolved,elf_flags=int.from_bytes(head[48:52],'little'))
 # Some private DSOs depend on a sibling already in their executable's
 # direct DT_NEEDED set (systemd core/shared). Do not add private directories
 # to the system search path or treat shared objects as standalone programs.
 contextual=[];remaining=[]
 for item in unresolved:
  parents=[name for name,meta in elfs.items() if meta['interpreter'] and any(posixpath.normpath(v)==item['file'] for v in meta['needed'].values()) and item['needed'] in meta['needed']]
  if parents:contextual.append(dict(item,executable_direct_NEEDs_both=parents))
  else:remaining.append(item)
 unresolved=remaining
 c.emit(OUT/'elf-audit.json',json.dumps(dict(files=elfs,unresolved=unresolved,contextual_direct_parent_dependencies=contextual,static_availability_only=True),indent=2)+'\n')
 c.require(not unresolved,'unresolved ELF runtime dependencies '+str(unresolved[:12]))
 c.emit(OUT/'rootfs-manifest.json',json.dumps(entries,indent=2)+'\n')
 image=HOST/'rv64-debian13-desktop-r111.squashfs'
 c.run('squashfs',['mksquashfs',root,image,'-noappend','-comp','xz','-b','131072','-processors','2','-all-root','-all-time','0','-mkfs-time','0','-no-progress'],timeout=900)
 c.run('squashfs-superblock',['unsquashfs','-s',image])
 # Independent filesystem decoder roundtrip. Device nodes are absent by
 # design: runtime supplies current kernel devtmpfs at mount/chroot time.
 roundtrip=OUT/'roundtrip'
 c.run('squashfs-roundtrip',['unsquashfs','-processors','2','-d',roundtrip,image],timeout=300)
 c.require(inventory(roundtrip)==entries,'every image entry/mode/link/content roundtrip')
 for pkg in pj['packages']:c.require(sha(Path(pkg['path']))==pkg['sha256'],'source DEB unchanged')
 pins={str(p.relative_to(R)):sha(p) for p in [Path(__file__),prep,base/'run-status.json',base/'initramfs.list',R/'scripts/rv64/build_artifact_guard_v2.py']}
 manifest=OUT/'rootfs-manifest.json';elf=OUT/'elf-audit.json'
 result=dict(status='PREPARED_SIGNED_DESKTOP_SQUASHFS_PAYLOAD_NOT_CONFIGURED_OR_TARGET_EXECUTED',source_sha256=pins,package_count=228,packages=pj['packages'],image=dict(path=str(image),bytes=image.stat().st_size,sha256=sha(image)),payload_regular_bytes=sum(x['bytes'] for x in entries.values() if x['type']=='file'),entries=len(entries),ELF_count=len(elfs),elf_runtime_sonames_resolved=True,preserved_R109_files=len(preserved),rootfs_manifest_sha256=sha(manifest),elf_audit_sha256=sha(elf),steps=c.STEPS,rootfs_dir=str(root),roundtrip_dir=str(roundtrip),maintainer_scripts_executed=False,dpkg_configured=False,target_execution=False,desktop_runtime_pass=False,board_modified=False,external_media_writes=False,host_install=False,scope='Signed full 228-package official Debian desktop payload plus unchanged R109 minimal root and probes, read-only demand-paged SquashFS file. Exact filesystem decoder roundtrip; ELF interpreter/SONAME availability is static only. No configured Debian distribution, Xorg font indexes, runtime RSS, keyboard/mouse, mode setting or desktop acceptance. Future root read-only mount plus /dev,/proc,/sys,/tmp runtime mounts required. External exFAT storage is not modified.')
 emit(result);c.emit(HOST/'preparation-status.json',json.dumps(result,indent=2)+'\n')
 shutil.copyfile(manifest,HOST/manifest.name);shutil.copyfile(elf,HOST/elf.name)
 print(result['status'],flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if OUT.exists():emit(dict(status='FAIL_DESKTOP_PAYLOAD_PREPARATION',error=repr(ex),traceback=traceback.format_exc(),steps=c.STEPS))
  raise
