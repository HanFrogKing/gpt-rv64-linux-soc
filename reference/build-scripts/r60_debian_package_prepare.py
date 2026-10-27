#!/usr/bin/env python3
"""Signed Debian packages for FUTURE own-RTL execution. No target execution.
No apt configuration, host package install, board or boot-media changes.
"""
import hashlib,io,json,lzma,re,subprocess,tarfile,urllib.request
from pathlib import Path
import integer_core_check as common
import build_artifact_guard_v2
ROOT=common.ROOT;OUT=ROOT/'build/rv64/r60-debian-package-prep'
common.OUT=OUT
build_artifact_guard_v2.install(common,Path(__file__),'r60-debian-package-prep')
MIRROR='https://deb.debian.org/debian/'
KEYS={
 'archive-key-12.asc':'B8B80B5B623EAB6AD8775C45B7C5D7D6350947F8',
 'archive-key-13.asc':'04B54C3CDCA79751B16BC6B5225629DF75B188BD',
 'release-13.asc':'41587F7DB8C774BCCF131416762F67A0B2C39DE4',
}
def sha(b):return hashlib.sha256(b).hexdigest()
def fetch(url,path,expected=None,size=None):
 if path.exists(): b=path.read_bytes()
 else:
  error=None
  for attempt in range(3):
   try:
    candidate=url.replace(MIRROR,'https://ftp.debian.org/debian/') if attempt==2 and url.startswith(MIRROR) else url
    with urllib.request.urlopen(candidate,timeout=30) as response:b=response.read()
    error=None;break
   except (OSError,urllib.error.URLError) as exc:
    error=exc;print('DOWNLOAD_RETRY',path.name,attempt+1,type(exc).__name__,flush=True)
  if error is not None:raise error
  path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(b)
 if expected:common.require(sha(b)==expected,'download SHA256 mismatch '+url)
 if size is not None:common.require(len(b)==size,'download size mismatch '+url)
 print('VERIFIED_DOWNLOAD',path.name,len(b),flush=True)
 return b
def parse_paragraph(text):
 d={};key=None
 for line in text.splitlines():
  if line.startswith(' ') and key:d[key]+='\n'+line
  elif ':' in line:key,value=line.split(':',1);d[key]=value.lstrip(' ')
 return d
def main():
 OUT.mkdir(parents=True,exist_ok=True);home=OUT/'gnupg';home.mkdir(mode=0o700,exist_ok=True)
 common.emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING'))+'\n')
 keyrings=[]
 for name,fingerprint in KEYS.items():
  asc=OUT/'keys'/name;fetch('https://ftp-master.debian.org/keys/'+name,asc)
  log=common.run('fingerprint-'+name,['gpg','--no-options','--homedir',home,'--batch','--with-colons','--show-keys',asc])
  primary=re.search(r'^fpr:::::::::([A-F0-9]+):',log,re.M)
  common.require(primary is not None and primary[1]==fingerprint,'official key fingerprint mismatch '+name)
  ring=asc.with_suffix('.gpg')
  common.run('dearmor-'+name,['gpg','--no-options','--homedir',home,'--batch','--yes','--dearmor','--output',ring,asc])
  keyrings+=['--keyring',ring]
 signed=OUT/'InRelease';fetch(MIRROR+'dists/trixie/InRelease',signed)
 release=OUT/'Release';release_tmp=OUT/'Release.verified'
 # gpgv never runs a keyserver or trusts the host's keyring. Key fingerprints
 # are pinned above from Debian FTP team's published active/release keys.
 if release_tmp.exists(): release_tmp.unlink() # one owned output file, not source/evidence
 log=common.run('verify-inrelease',['gpgv','--homedir',home,*keyrings,'--status-fd','1','--output',release_tmp,signed])
 common.require('[GNUPG:] VALIDSIG ' in log and any(k in log for k in KEYS.values()),'missing valid pinned Debian signature')
 text=release_tmp.read_text();common.emit(release,text)
 fields=parse_paragraph(text);common.require(fields.get('Codename')=='trixie','wrong Debian release')
 index_name='main/binary-riscv64/Packages.xz'
 match=re.search(r'^ ([a-f0-9]{64})\s+(\d+) '+re.escape(index_name)+r'$',fields['SHA256'],re.M)
 common.require(match is not None,'signed index absent')
 index_hash,index_size=match[1],int(match[2])
 index=fetch(MIRROR+'dists/trixie/main/binary-riscv64/by-hash/SHA256/'+index_hash,
             OUT/'Packages.xz',index_hash,index_size)
 wanted={'hello','mawk','libc6','libgcc-s1','gcc-14-base'};entries={}
 for paragraph in lzma.decompress(index).decode().split('\n\n'):
  if paragraph.startswith('Package: '):
   name=paragraph.split('\n',1)[0][9:]
   if name in wanted:
    d=parse_paragraph(paragraph)
    if d['Architecture']=='riscv64':entries[name]=d
 common.require(set(entries)==wanted,'package set missing '+str(wanted-set(entries)))
 image=OUT/'package-test-root';image.mkdir(exist_ok=True)
 selected={
  'usr/bin/hello','usr/bin/mawk','usr/lib/riscv64-linux-gnu/libc.so.6',
  'usr/lib/riscv64-linux-gnu/libm.so.6','usr/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1',
  'usr/lib/riscv64-linux-gnu/libgcc_s.so.1',
 }
 packages=[];extracted={}
 for name in sorted(wanted):
  d=entries[name];filename=d['Filename'];deb=OUT/'packages'/Path(filename).name
  data=fetch(MIRROR+filename,deb,d['SHA256'],int(d['Size']))
  members=subprocess.check_output(['ar','t',str(deb)],text=True).splitlines()
  payloads=[m for m in members if m.startswith('data.tar')];common.require(len(payloads)==1,'deb data member')
  payload=subprocess.check_output(['ar','p',str(deb),payloads[0]])
  with tarfile.open(fileobj=io.BytesIO(payload),mode='r:*') as tar:
   for member in tar:
    member_name=member.name.removeprefix('./')
    if member_name not in selected and member_name!=f'usr/share/doc/{name}/copyright':continue
    common.require(member.isfile(),'selected package payload is not regular '+member_name)
    rel=Path(member_name);common.require(not rel.is_absolute() and '..' not in rel.parts,'unsafe package path')
    p=image/rel;p.parent.mkdir(parents=True,exist_ok=True);b=tar.extractfile(member).read();p.write_bytes(b);p.chmod(member.mode&0o777)
    extracted[member_name]=sha(b)
  packages.append({k:d.get(k,'') for k in ['Package','Version','Architecture','Depends','Pre-Depends','Filename','Size','SHA256']})
 common.require(selected<=set(extracted),'missing ELF files '+str(selected-set(extracted)))
 for path,target in [(image/'lib','usr/lib'),(image/'usr/lib/ld-linux-riscv64-lp64d.so.1','riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1')]:
  if not path.is_symlink():common.require(not path.exists(),'refuse path overwrite');path.symlink_to(target)
  common.require(path.resolve().is_relative_to(image.resolve()),'symlink escapes test root')
 elfs=[]
 for rel in sorted(selected):
  p=image/rel
  log=common.run('elf-audit-'+p.name,[common.CROSS+'readelf','-h','-A','-l','-d',p])
  common.require('RISC-V' in log and 'double-float ABI' in log,'not riscv64 LP64D '+rel)
  needed=re.findall(r'\(NEEDED\).*?\[([^\]]+)\]',log)
  for library in needed:common.require((image/'usr/lib/riscv64-linux-gnu'/library).is_file(),'unresolved runtime dependency '+library)
  interpreter=re.search(r'Requesting program interpreter: ([^\]]+)',log)
  if interpreter:common.require((image/interpreter[1].lstrip('/')).is_file(),'interpreter absent')
  elfs.append(dict(path=rel,sha256=extracted[rel],needed=needed,interpreter=interpreter[1] if interpreter else None))
 common.emit(image/'README-NOT-A-BOOTABLE-ROOTFS.txt',
  'Selected unmodified official Debian 13 riscv64 ELF files and required libraries only.\n'
  'Not a Debian installation or bootable rootfs. Not executed on own RTL yet.\n'
  'Future: /usr/bin/hello; /usr/bin/mawk BEGIN{print sqrt(2)} on verified RV64GC/LP64D Linux.\n')
 # Reuse R54's accepted Linux gen_init_cpio executable, read-only. The overlay
 # lives wholly under /opt/debian and uses the unmodified glibc loader explicitly;
 # it cannot replace the recovery musl runtime's /lib or /bin/sh.
 smoke=ROOT/'sw/rv64/r60-debian-smoke.sh'
 common.run('smoke-shell-syntax',['sh','-n',smoke])
 overlay_files={f'opt/debian/{name}':image/name for name in extracted}
 overlay_files['opt/debian/run-smoke.sh']=smoke
 directories=set()
 for name in overlay_files:
  directories.update(str(p) for p in Path(name).parents if str(p)!='.')
 listing=[f'dir /{d} 0755 0 0' for d in sorted(directories,key=lambda x:(x.count('/'),x))]
 for name,source in sorted(overlay_files.items()):
  mode='0755' if name.endswith('run-smoke.sh') or name in ['opt/debian/usr/bin/hello','opt/debian/usr/bin/mawk'] or '/usr/lib/' in name else '0644'
  listing.append(f'file /{name} {source} {mode} 0 0')
 common.emit(OUT/'overlay.list','\n'.join(listing)+'\n')
 cpio_tool=ROOT/'build/rv64/r54-linux-board-prep/gen_init_cpio'
 overlay=OUT/'debian-test-overlay.cpio'
 with overlay.open('wb') as f:subprocess.run([str(cpio_tool),'-t','0',str(OUT/'overlay.list')],stdout=f,check=True)
 audited=subprocess.run(['cpio','-it','--quiet'],input=overlay.read_bytes(),capture_output=True,check=True).stdout.decode().splitlines()
 common.require(set(overlay_files)<=set(audited),'cpio overlay missing files')
 common.require(all(n=='opt' or n.startswith('opt/debian') for n in audited),'overlay would overwrite recovery runtime')
 report=dict(status='PREPARED_SIGNED_OFFICIAL_DEBIAN_PACKAGES_NOT_EXECUTED',release={k:fields.get(k) for k in ['Origin','Label','Suite','Version','Codename','Date']},
  signed_inrelease_sha256=sha(signed.read_bytes()),verified_release_sha256=sha(release.read_bytes()),
  index_sha256=index_hash,key_fingerprints=KEYS,packages=packages,elfs=elfs,
  self_developed_cpu_execution=False,host_emulation_execution=False,board_programming=False,bootable_rootfs=False,
  overlay=dict(sha256=sha(overlay.read_bytes()),bytes=overlay.stat().st_size,tool_sha256=common.sha(cpio_tool),members=audited,
               command='/bin/sh /opt/debian/run-smoke.sh',executed=False),
  source_sha256={str(p.relative_to(ROOT)):common.sha(p) for p in [Path(__file__),smoke,ROOT/'scripts/rv64/build_artifact_guard_v2.py']},
  steps=common.STEPS,log_sha256={s['name']+'.log':common.sha(OUT/(s['name']+'.log')) for s in common.STEPS})
 common.emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n');print(report['status'],flush=True)
if __name__=='__main__':main()
