#!/usr/bin/env python3
"""Separate initramfs candidate: drain rcS output before init replaces its tty."""
import json,os,pty,shutil,subprocess,select
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r69-gc-tty';c.OUT=OUT
guard.install(c,Path(__file__),'r69-gc-tty')
P=R/'build/rv64/r65-gc-linux';SW=R/'sw/rv64/r69-gc-tty'

def main():
 OUT.mkdir(exist_ok=True);c.require(not (OUT/'run-status.json').exists(),'Preserve existing evidence')
 parent=json.loads((P/'run-status.json').read_text())
 for n,j in parent['artifacts'].items():c.require(c.sha(P/n)==j['sha256'],'parent artifact changed '+n)
 for n,h in parent['source_sha256'].items():c.require(c.sha(R/n)==h,'parent source changed '+n)
 sdk=json.loads((R/'build/rv64/linux/sdk-status.json').read_text())
 c.require(c.sha(Path(sdk['identity']['prefix'])/'lib/libc.a')==sdk['libc_sha256'],'musl changed')
 c.run('drain-native-build',['gcc','-O2','-Wall','-Wextra','-Werror',SW/'tty-drain.c','-o',OUT/'tty-drain-host'],timeout=60)
 fail=subprocess.run([OUT/'tty-drain-host'],capture_output=True)
 c.require(fail.returncode!=0 and b'RV64_TTY_DRAIN_PASS' not in fail.stdout,'non-TTY negative not rejected')
 master,slave=pty.openpty()
 try:
  positive=subprocess.run([OUT/'tty-drain-host'],stdout=slave,stderr=subprocess.PIPE,timeout=10)
  c.require(positive.returncode==0,'host PTY drain failed')
  c.require(bool(select.select([master],[],[],2)[0]),'host PTY output absent')
  text=os.read(master,4096)
  c.require(text==b'RV64_TTY_DRAIN_PASS\r\n','wrong PTY marker '+repr(text))
 finally:os.close(master);os.close(slave)
 c.emit(OUT/'drain-host-check.json',json.dumps(dict(status='PASS_REAL_HELPER_PTY_AND_NON_TTY_NEGATIVE',tty_output=text.decode(),negative_exit=fail.returncode))+'\n')
 c.run('drain-target-build',[*sdk['compiler_command'],*sdk['identity']['flags'].split(),'-D__linux__=1','-D__unix__=1','-Wall','-Wextra','-Werror',SW/'tty-drain.c','-o',OUT/'tty-drain.elf'],timeout=60)
 listing=(P/'initramfs.list').read_text().splitlines();lines=[]
 for line in listing:
  fields=line.split()
  if fields[:2]==['file','/etc/rcS']:fields[2]=str(SW/'rcS')
  lines.append(' '.join(fields))
 lines.append(f'file /bin/tty-drain {OUT}/tty-drain.elf 755 0 0')
 c.emit(OUT/'initramfs.list','\n'.join(lines)+'\n')
 c.run('rcS-syntax',['sh','-n',SW/'rcS'],timeout=10)
 with (OUT/'initramfs.cpio').open('wb') as f:
  subprocess.run([R/'build/rv64/r54-linux-board-prep/gen_init_cpio','-t','0',OUT/'initramfs.list'],stdout=f,check=True)
 build=OUT/'kernel-build'
 # Independent byte copies, never hardlinks to the accepted kernel output.
 shutil.copytree(P/'kernel-build',build,symlinks=True)
 kernel=R/'build/rv64/linux/src/linux-6.6.80'
 c.run('kernel-initramfs-option',[kernel/'scripts/config','--file',build/'.config','--set-str','INITRAMFS_SOURCE',OUT/'initramfs.cpio'],timeout=30)
 kb=['make','-C',kernel,'O='+str(build),'ARCH=riscv','CROSS_COMPILE='+c.CROSS,'LD=/mnt/e/path/rv64-linux-ld',
  'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=gc-prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
 c.run('kernel-config',kb+['olddefconfig'],timeout=60)
 old=(P/'kernel-build/.config').read_text().splitlines();new=(build/'.config').read_text().splitlines()
 c.require([x for x in old if not x.startswith('CONFIG_INITRAMFS_SOURCE=')]==[x for x in new if not x.startswith('CONFIG_INITRAMFS_SOURCE=')],'unrelated kernel config changed')
 c.run('kernel-build',kb+['-j2','Image'],timeout=1800)
 for n,j in parent['artifacts'].items():c.require(c.sha(P/n)==j['sha256'],'parent modified by new build '+n)
 files=[Path(__file__),SW/'rcS',SW/'tty-drain.c']
 result=dict(status='PASS_R69_TTY_DRAIN_KERNEL_PREPARED_NOT_BOOTED',parent_status_sha256=c.sha(P/'run-status.json'),
  source_sha256={str(x.relative_to(R)):c.sha(x) for x in files},
  artifacts={str(x.relative_to(OUT)):dict(bytes=x.stat().st_size,sha256=c.sha(x)) for x in [OUT/'tty-drain.elf',OUT/'initramfs.cpio',build/'.config',build/'arch/riscv/boot/Image']},steps=c.STEPS)
 c.emit(OUT/'run-status.json',json.dumps(result,indent=2)+'\n');print(result['status'],flush=True)
if __name__=='__main__':main()
