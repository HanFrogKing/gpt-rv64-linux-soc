#!/usr/bin/env python3
"""Private signed Debian graphics dependency plan and official modetest overlay.

No apt configuration/install, target execution, board, or storage-media actions.
Uses the already accepted pinned Debian index rather than mixing package epochs.
"""
from pathlib import Path
import datetime,hashlib,importlib.util,json,lzma,re,shutil,subprocess,sys
import integer_core_check as c
import build_artifact_guard_v2 as guard
import r60_debian_package_prepare as signed
import r71_debian_rootfs_prepare_v3 as unpack
R=c.ROOT;OUT=R/'build/rv64/r108-graphics-package-prep-r2'
P=R/'build/rv64/r60-debian-package-prep'
c.OUT=OUT;guard.install(c,Path(__file__),'r108-graphics-package-prep-r2')
PINS={'InRelease':'0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675',
 'Release':'ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a',
 'Packages.xz':'1b0d89902b0bde1d8cacb392e3c9b73511abc12b291511c3a9dcd28ad0fa3582'}
GRAPHICS=['xserver-xorg-core','xserver-xorg-input-libinput','openbox','xterm','xinit','xauth','xfonts-base','x11-xserver-utils']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 assert not OUT.exists(),'Preserve previous attempt'
 assert shutil.disk_usage('/mnt/e').free>=10*1024**3 and shutil.disk_usage('/').free>=5*1024**3
 OUT.mkdir(parents=True);c.emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING_HOST_PREPARATION_NOT_TARGET'))+'\n')
 for name,h in PINS.items():assert sha(P/name)==h,name
 home=OUT/'gnupg';home.mkdir(mode=0o700);rings=[]
 for name,fpr in signed.KEYS.items():
  key=P/'keys'/name
  log=c.run('key-'+name,['gpg','--no-options','--homedir',home,'--batch','--with-colons','--show-keys',key])
  assert re.search(r'^fpr:::::::::([A-F0-9]+):',log,re.M)[1]==fpr
  ring=OUT/(name+'.gpg')
  c.run('dearmor-'+name,['gpg','--no-options','--homedir',home,'--batch','--dearmor','--output',ring,key])
  rings.extend(['--keyring',ring])
 log=c.run('verify-pinned-release',['gpgv','--homedir',home,*rings,'--status-fd','1','--output',OUT/'Release.verified',P/'InRelease'])
 assert 'VALIDSIG' in log and sha(OUT/'Release.verified')==PINS['Release']
 release=signed.parse_paragraph((P/'Release').read_text());name='main/binary-riscv64/Packages.xz'
 match=re.search(r'^ ([a-f0-9]{64})\s+(\d+) '+re.escape(name)+r'$',release['SHA256'],re.M)
 assert match and match[1]==PINS['Packages.xz'] and int(match[2])==(P/'Packages.xz').stat().st_size
 index=lzma.decompress((P/'Packages.xz').read_bytes());entries={}
 for paragraph in index.decode().split('\n\n'):
  d=signed.parse_paragraph(paragraph)
  if d.get('Architecture') in ['riscv64','all'] and 'Package' in d:entries[d['Package']]=d
 # Native apt dependency solver, isolated lists/state/cache and empty installed
 # status. This is a simulation; no apt update, dpkg invocation or host changes.
 apt=OUT/'private-apt'
 for directory in ['etc/apt/apt.conf.d','etc/apt/sources.list.d','etc/apt/preferences.d','etc/apt/trusted.gpg.d',
  'var/lib/apt/lists/partial','var/lib/dpkg','var/cache/apt/archives/partial','var/log/apt']:
  (apt/directory).mkdir(parents=True,exist_ok=True)
 (apt/'var/lib/dpkg/status').write_text('')
 (apt/'etc/apt/sources.list').write_text('deb [arch=riscv64] https://deb.debian.org/debian trixie main\n')
 lists=apt/'var/lib/apt/lists'
 (lists/'deb.debian.org_debian_dists_trixie_main_binary-riscv64_Packages').write_bytes(index)
 shutil.copyfile(P/'InRelease',lists/'deb.debian.org_debian_dists_trixie_InRelease')
 options=['apt-get','-s','--no-install-recommends','-o','Dir='+str(apt),'-o','APT::Architecture=riscv64',
  '-o','APT::Architectures::=riscv64','-o','Dir::State::status='+str(apt/'var/lib/dpkg/status'),
  '-o','Debug::NoLocking=true','-o','APT::Get::List-Cleanup=false','-o','Dir::Etc::main=/dev/null']
 plans={}
 for label,wanted in [('official-modetest',['libdrm-tests']),('light-desktop',GRAPHICS)]:
  text=c.run('apt-simulate-'+label,options+['install',*wanted])
  names=re.findall(r'^Inst ([a-z0-9+.-]+)(?::riscv64)? ',text,re.M)
  assert set(wanted)<=set(names) and len(names)==len(set(names))
  pkgs=[entries[n] for n in names]
  plans[label]=dict(requested=wanted,packages=[{k:d.get(k,'') for k in ['Package','Version','Architecture','Filename','Size','SHA256','Installed-Size','Depends','Pre-Depends','Provides']} for d in pkgs],
   compressed_bytes=sum(int(d['Size']) for d in pkgs),declared_installed_bytes=sum(int(d.get('Installed-Size','0'))*1024 for d in pkgs),
   recommends_included=False,host_install_performed=False)
  print('PRIVATE_APT_PLAN',label,len(pkgs),plans[label]['compressed_bytes'],flush=True)
 # Only fetch/unpack the small diagnostic closure in this phase. Desktop deps
 # remain a real apt-solved plan until DRM/fbcon and input/memory gates pass.
 root=OUT/'official-modetest-root';root.mkdir();downloaded=[]
 for d in plans['official-modetest']['packages']:
  dest=OUT/'packages'/Path(d['Filename']).name
  candidates=[R/'build/rv64/r108-graphics-package-prep-r1/packages'/dest.name,P/'packages'/dest.name,R/'build/rv64/r71-debian-minimal-r3/packages'/dest.name]
  prior=next((p for p in candidates if p.exists()),None)
  if prior:
   assert prior.stat().st_size==int(d['Size']) and sha(prior)==d['SHA256']
   dest.parent.mkdir(exist_ok=True);shutil.copyfile(prior,dest)
  else:signed.fetch(signed.MIRROR+d['Filename'],dest,d['SHA256'],int(d['Size']))
  assert sha(dest)==d['SHA256'];unpack.extract(dest,root)
  downloaded.append(dict(package=d['Package'],path=str(dest.relative_to(R)),sha256=sha(dest)))
 libdir=root/'usr/lib/riscv64-linux-gnu';modetest=root/'usr/bin/modetest'
 assert modetest.is_file() and (libdir/'ld-linux-riscv64-lp64d.so.1').is_file()
 elfs=[]
 for p in sorted(root.rglob('*')):
  if p.is_symlink() or not p.is_file() or p.open('rb').read(4)!=b'\x7fELF':continue
  rel=p.relative_to(root).as_posix()
  text=c.run('elf-'+rel.replace('/','_'),[c.CROSS+'readelf','-h','-A','-l','-d',p])
  assert 'RISC-V' in text and 'double-float ABI' in text,rel
  needed=re.findall(r'\(NEEDED\).*?\[([^\]]+)\]',text)
  search=[libdir,root/'usr/lib']
  for value in re.findall(r'\((?:RUNPATH|RPATH)\).*?\[([^\]]+)\]',text):
   for component in value.split(':'):
    expanded=component.replace('${ORIGIN}',str(p.parent)).replace('$ORIGIN',str(p.parent))
    assert '$' not in expanded,'Unhandled dynamic path token'
    directory=Path(expanded)
    if component.startswith('/') and '$ORIGIN' not in component:directory=root/component.lstrip('/')
    assert directory.resolve().is_relative_to(root),'Dynamic path escapes guest root'
    search.append(directory)
  for n in needed:assert any((directory/n).is_file() for directory in search),(rel,n)
  elfs.append(dict(path=rel,sha256=sha(p),needed=needed))
 # A relocatable /opt tree, called with its own official loader, avoids changing
 # current musl/Debian /lib files. Not installed into any current initramfs.
 payload={}
 for p in root.rglob('*'):
  if p.is_file() and not p.is_symlink() and (p.name=='modetest' or p.parent==libdir):
   payload['opt/debian-graphics/'+p.relative_to(root).as_posix()]=p
 assert any(n.endswith('/modetest') for n in payload)
 dirs=set()
 for name in payload:dirs.update(str(p) for p in Path(name).parents if str(p)!='.')
 listing=[f'dir /{n} 0755 0 0' for n in sorted(dirs,key=lambda n:(n.count('/'),n))]
 listing += [f'file /{n} {p} 0755 0 0' for n,p in sorted(payload.items())]
 # SONAME symlinks in official .deb remain necessary (not duplicated files).
 for p in sorted(libdir.iterdir()):
  if p.is_symlink():
   target=p.readlink();assert not target.is_absolute() and (p.parent/target).is_file()
   listing.append(f'slink /opt/debian-graphics/{p.relative_to(root)} {target} 0777 0 0')
 c.emit(OUT/'overlay.list','\n'.join(listing)+'\n')
 gen=R/'build/rv64/r54-linux-board-prep/gen_init_cpio';overlay=OUT/'official-modetest-overlay.cpio'
 with overlay.open('wb') as f:subprocess.run([str(gen),'-t','0',str(OUT/'overlay.list')],stdout=f,check=True)
 members=subprocess.run(['cpio','-it','--quiet'],input=overlay.read_bytes(),capture_output=True,check=True).stdout.decode().splitlines()
 assert set(payload)<=set(members) and all(n=='opt' or n.startswith('opt/debian-graphics') for n in members)
 config='''Section "Device"
    Identifier "rv64lab"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card0"
    Option "AccelMethod" "none"
    Option "SWcursor" "true"
    Option "ShadowFB" "true"
    Option "PageFlip" "false"
EndSection
'''
 c.emit(OUT/'xorg-software-rendering-candidate.conf',config)
 note='''Prepared diagnostic only. No target execution, desktop installation or current boot-image changes.
Future read-only DRM inventory (after separate tested software image):
/opt/debian-graphics/usr/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1 --library-path /opt/debian-graphics/usr/lib/riscv64-linux-gnu /opt/debian-graphics/usr/bin/modetest -M rv64lab -c -e -p
The above must use bounded/chunked serial input; it exceeds the current 60-byte RX limit. Do not send it as one current board command.
Do not use modetest -s/-v/-a/-P during readonly console capture; those change modes/planes.
The Xorg config is an untested candidate, not an assertion that this core has hardware VBlank/page flips, GPU, working VT/session/input or enough RAM for a full desktop.
'''
 c.emit(OUT/'README-NOT-EXECUTED.txt',note)
 report=dict(status='PREPARED_SIGNED_OFFICIAL_MODETEST_OVERLAY_AND_NATIVE_APT_DESKTOP_PLAN_NOT_EXECUTED',
  release={k:release.get(k) for k in ['Origin','Suite','Version','Codename','Date']},pinned_metadata=PINS,
  plans=plans,downloaded_diagnostic_packages=downloaded,elfs=elfs,
  overlay=dict(path=str(overlay.relative_to(R)),bytes=overlay.stat().st_size,sha256=sha(overlay),members=len(members)),
  desktop_packages_downloaded=False,host_install_performed=False,target_execution=False,current_initramfs_modified=False,
  board_actions=False,media_writes=False,source_sha256={str(p.relative_to(R)):sha(p) for p in [Path(__file__),Path(signed.__file__),Path(unpack.__file__),R/'scripts/rv64/build_artifact_guard_v2.py']},
  logs_sha256={p.name:sha(p) for p in OUT.glob('*.log')},recorded_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
 c.emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n');print(report['status'],flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as exc:
  if OUT.exists():
   failure=dict(status='FAIL_PREPARATION_NOT_TARGET',error=repr(exc));c.emit(OUT/'failure.json',json.dumps(failure)+'\n');c.emit(OUT/'run-status.json',json.dumps(failure)+'\n')
  raise
