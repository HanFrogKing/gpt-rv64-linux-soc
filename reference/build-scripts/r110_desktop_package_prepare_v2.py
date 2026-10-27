#!/usr/bin/env python3
"""Fetch frozen signed official desktop closure into ordinary host files only."""
from pathlib import Path
import concurrent.futures,datetime,hashlib,json,lzma,re,shutil,subprocess,traceback,urllib.error,urllib.request
import integer_core_check as c
import build_artifact_guard_v2 as guard
import r60_debian_package_prepare as signed
R=c.ROOT;OUT=R/'build/rv64/r110-desktop-package-prep-r2'
HOST=Path('${HOST_OUTPUTS}/rv64-r110-desktop-package-prep-r2')
P=R/'build/rv64/r60-debian-package-prep';PLAN=R/'build/rv64/r108-graphics-package-prep-r2/run-status.json'
c.OUT=OUT;guard.install(c,Path(__file__),'r110-desktop-package-prep-r2')
PIN={'InRelease':'0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675','Release':'ed56aac47e7911e65ee63aae8d67e29f20e023f840e49f8ed037043a33de138a','Packages.xz':'1b0d89902b0bde1d8cacb392e3c9b73511abc12b291511c3a9dcd28ad0fa3582'}
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
 return h.hexdigest()
def emit(p,j):p.write_text(json.dumps(j,ensure_ascii=False,indent=2)+'\n')
def download(d):
 dest=HOST/'packages'/Path(d['Filename']).name
 candidates=[R/'build/rv64'/directory/'packages'/dest.name for directory in ['r60-debian-package-prep','r71-debian-minimal-r3','r108-graphics-package-prep-r1','r108-graphics-package-prep-r2']]
 prior=next((p for p in candidates if p.is_file() and p.stat().st_size==int(d['Size']) and sha(p)==d['SHA256']),None)
 if prior:
  shutil.copyfile(prior,dest);origin='verified-local:'+str(prior.relative_to(R))
 else:
  errors=[]
  for mirror in ['https://deb.debian.org/debian/','https://ftp.debian.org/debian/']:
   try:
    with urllib.request.urlopen(mirror+d['Filename'],timeout=30) as response:data=response.read()
    assert len(data)==int(d['Size']) and hashlib.sha256(data).hexdigest()==d['SHA256'],'Package bytes/hash mismatch'
    dest.write_bytes(data);origin=mirror+d['Filename'];break
   except (OSError,urllib.error.URLError) as exc:errors.append(repr(exc))
  else:raise RuntimeError(d['Package']+': '+repr(errors))
 assert dest.stat().st_size==int(d['Size']) and sha(dest)==d['SHA256']
 # Read architecture/control metadata using native dpkg-deb. No maintainer
 # scripts, host install, package configuration or target ELF execution.
 fields=subprocess.check_output(['dpkg-deb','--field',str(dest),'Package','Version','Architecture'],text=True)
 parsed=dict(line.split(': ',1) for line in fields.splitlines())
 assert all(parsed[k]==d[k] for k in ['Package','Version','Architecture']),parsed
 print('VERIFIED_DESKTOP_DEB',d['Package'],d['Version'],dest.stat().st_size,flush=True)
 return dict(package=d['Package'],version=d['Version'],architecture=d['Architecture'],path=str(dest),bytes=dest.stat().st_size,sha256=sha(dest),origin=origin)
def main():
 assert not OUT.exists() and not HOST.exists(),'Preserve previous attempt'
 assert shutil.disk_usage('/mnt/e').free>=10*1024**3 and shutil.disk_usage('/mnt/c').free>=3*1024**3
 OUT.mkdir(parents=True);HOST.mkdir();(HOST/'packages').mkdir()
 emit(OUT/'run-status.json',dict(status='RUNNING_HOST_DESKTOP_PACKAGE_PREPARATION_NO_INSTALL'))
 plan=json.loads(PLAN.read_text());assert plan['status']=='PREPARED_SIGNED_OFFICIAL_MODETEST_OVERLAY_AND_NATIVE_APT_DESKTOP_PLAN_NOT_EXECUTED'
 for n,h in PIN.items():assert sha(P/n)==h,n
 home=OUT/'gnupg';home.mkdir(mode=0o700);rings=[]
 for name,fpr in signed.KEYS.items():
  key=P/'keys'/name
  log=c.run('key-'+name,['gpg','--no-options','--homedir',home,'--batch','--with-colons','--show-keys',key])
  assert re.search(r'^fpr:::::::::([A-F0-9]+):',log,re.M)[1]==fpr
  ring=OUT/(name+'.gpg');c.run('dearmor-'+name,['gpg','--no-options','--homedir',home,'--batch','--dearmor','--output',ring,key]);rings+=['--keyring',ring]
 log=c.run('verify-pinned-release',['gpgv','--homedir',home,*rings,'--status-fd','1','--output',OUT/'Release.verified',P/'InRelease'])
 assert 'VALIDSIG' in log and sha(OUT/'Release.verified')==PIN['Release']
 rel=signed.parse_paragraph((P/'Release').read_text());indexname='main/binary-riscv64/Packages.xz'
 match=re.search(r'^ ([a-f0-9]{64})\s+(\d+) '+re.escape(indexname)+r'$',rel['SHA256'],re.M)
 assert match and match[1]==PIN['Packages.xz'] and int(match[2])==(P/'Packages.xz').stat().st_size
 entries={}
 for text in lzma.decompress((P/'Packages.xz').read_bytes()).decode().split('\n\n'):
  d=signed.parse_paragraph(text)
  if d.get('Architecture') in ['all','riscv64'] and 'Package' in d:entries[d['Package']]=d
 desktop=plan['plans']['light-desktop'];pkgs=desktop['packages']
 assert len(pkgs)==228 and desktop['compressed_bytes']==141752460 and desktop['declared_installed_bytes']==478248960
 for d in pkgs:
  e=entries[d['Package']]
  for k,v in d.items():assert e.get(k,'')==v,(d['Package'],k)
 wanted=sorted(pkgs,key=lambda d:d['Package']);emit(HOST/'signed-package-plan.json',desktop)
 done=[];failures=[]
 with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
  jobs={pool.submit(download,d):d for d in wanted}
  for job in concurrent.futures.as_completed(jobs):
   d=jobs[job]
   try:done.append(job.result())
   except BaseException as exc:
    failures.append(dict(package=d['Package'],error=repr(exc)));print('DESKTOP_PACKAGE_FAILED',d['Package'],repr(exc),flush=True)
 emit(HOST/'download-results.json',dict(verified=sorted(done,key=lambda d:d['package']),failures=failures))
 assert not failures,failures
 config=R/'build/rv64/r109-graphics-kernel-r1/kernel-build/.config';text=config.read_text()
 keys=['INPUT','INPUT_EVDEV','HID','HID_GENERIC','USB_HID','VT','VT_CONSOLE','UNIX','SYSVIPC','INOTIFY_USER','EPOLL','FUTEX','FHANDLE','TMPFS','TMPFS_POSIX_ACL','DEVTMPFS','EXT4_FS','BLK_DEV_LOOP','NTFS3_FS']
 features={k:next((x.split('=',1)[1] for x in text.splitlines() if x.startswith('CONFIG_'+k+'=')),'n') for k in keys}
 for k in keys:
  if k not in ['BLK_DEV_LOOP','NTFS3_FS']:assert features[k]=='y',k
 result=dict(status='PREPARED_SIGNED_OFFICIAL_DESKTOP_DEBS_NOT_UNPACKED_INSTALLED_OR_EXECUTED',recorded_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),requested=desktop['requested'],packages=sorted(done,key=lambda d:d['package']),package_count=len(done),compressed_bytes=sum(x['bytes'] for x in done),declared_installed_bytes=desktop['declared_installed_bytes'],kernel_features=features,
  current_target_RAM_MiB=126,declared_installed_size_is_not_RSS=True,memory_runtime_acceptance=False,host_install=False,target_execution=False,external_media_writes=False,board_actions=False,
  source_sha256={str(p.relative_to(R)):sha(p) for p in [Path(__file__),Path(signed.__file__),R/'scripts/rv64/build_artifact_guard_v2.py',PLAN,config]},metadata_sha256=PIN,steps=c.STEPS,
  scope='Frozen apt-resolved 228-package official Debian 13 riscv64 desktop closure, signed Release/index/package hashes plus dpkg-deb control identity verified. Plain host files only. No rootfs configuration, target execution, Xorg memory/input/display proof or physical media writes. Do not place 478MB wholesale in126MiB initramfs. Future storage/mount/readonly-image design and actual Xorg/Openbox validation remain required.')
 emit(OUT/'run-status.json',result);emit(HOST/'preparation-status.json',result);print(result['status'],flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as exc:
  if OUT.exists():emit(OUT/'failure.json',dict(status='FAIL_DESKTOP_HOST_PACKAGE_PREPARATION_NOT_RUNTIME',error=repr(exc),traceback=traceback.format_exc()))
  raise
