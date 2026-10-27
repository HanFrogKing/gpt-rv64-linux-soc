#!/usr/bin/env python3
"""Tiny ordinary-file SquashFS and gated target-only runtime test preparation."""
from pathlib import Path
import base64,json,shutil,subprocess,traceback
import integer_core_check as c
import build_artifact_guard_v2 as guard
R=c.ROOT;OUT=R/'build/rv64/r111-storage-fixture-r1';c.OUT=OUT
HOST=Path('${HOST_OUTPUTS}/rv64-r111-storage-fixture-r1')
guard.install(c,Path(__file__),'r111-storage-fixture-r1')
MARKER='R111_LOOP_SQUASHFS_READONLY_FIXTURE_V1\n'
def main():
 c.require(not OUT.exists() and not HOST.exists(),'preserve attempts')
 OUT.mkdir();HOST.mkdir();root=OUT/'source';root.mkdir();(root/'marker').write_text(MARKER)
 (root/'marker').chmod(0o644);image=HOST/'r111-small.squashfs'
 c.run('make-small-squashfs',['mksquashfs',root,image,'-noappend','-comp','xz','-b','131072','-processors','2','-all-root','-all-time','0','-mkfs-time','0','-no-progress'])
 c.run('decode-small-squashfs',['unsquashfs','-processors','2','-no-progress','-d',OUT/'decode',image])
 c.require((OUT/'decode/marker').read_text()==MARKER,'decoded marker exact')
 data=base64.b64encode(image.read_bytes()).decode()
 upload="/bin/busybox base64 -d >/tmp/r111-small.squashfs <<'R111_B64_END'\n"+'\n'.join(data[i:i+64] for i in range(0,len(data),64))+"\nR111_B64_END\n"
 c.emit(HOST/'target-upload.txt',upload)
 script='''#!/bin/sh
# TARGET ONLY. Ordinary /tmp fixture; never opens an external storage device.
set -eu
test "$(/bin/busybox uname -r)" = 6.6.80-rv64lab-r111-storage-r2
test -f /tmp/r111-small.squashfs
test ! -e /tmp/r111-loop-runtime
/bin/busybox mkdir /tmp/r111-loop-runtime
loop=$(/bin/busybox losetup -f)
case "$loop" in /dev/loop[0-7]) ;; *) echo BAD_LOOP; exit 1;; esac
/bin/busybox losetup -r "$loop" /tmp/r111-small.squashfs
/bin/busybox mount -t squashfs -o ro,nodev,nosuid "$loop" /tmp/r111-loop-runtime
test "$(/bin/busybox cat /tmp/r111-loop-runtime/marker)" = R111_LOOP_SQUASHFS_READONLY_FIXTURE_V1
/bin/busybox cat /proc/mounts
if (printf X >/tmp/r111-loop-runtime/write-must-fail); then
    echo R111_READONLY_VIOLATION; exit 1
fi
test ! -e /tmp/r111-loop-runtime/write-must-fail
/bin/busybox umount /tmp/r111-loop-runtime
/bin/busybox losetup -d "$loop"
echo R111_TARGET_LOOP_SQUASHFS_READONLY_PASS
'''
 c.emit(HOST/'target-loop-squashfs-test.sh',script)
 c.run('shell-syntax',['sh','-n',HOST/'target-loop-squashfs-test.sh'])
 # This is transport preparation only, not an invented target UART transcript.
 c.require(base64.b64decode(''.join(upload.splitlines()[1:-1]),validate=True)==image.read_bytes(),'upload bytes roundtrip')
 result=dict(status='PREPARED_SMALL_SQUASHFS_AND_TARGET_TEST_NOT_TARGET_EXECUTED',
  image=dict(path=str(image),bytes=image.stat().st_size,sha256=c.sha(image)),
  source_sha256={str(Path(__file__).relative_to(R)):c.sha(__file__),
   'scripts/rv64/build_artifact_guard_v2.py':c.sha(R/'scripts/rv64/build_artifact_guard_v2.py')},
  prepared_files={p.name:dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in HOST.iterdir() if p.is_file()},
  required_kernel='6.6.80-rv64lab-r111-storage-r2',runtime_gate='Wait BOTH complete real RTL Linux modes PASS plus new physical boot input lock and new independent baseline/boot before execution.',
  host_decoder_pass=True,target_loop_mount_pass=False,target_write_rejection_pass=False,
  external_disk_touched=False,board_modified=False,steps=c.STEPS)
 c.emit(OUT/'run-status.json',json.dumps(result,indent=2)+'\n');c.emit(HOST/'preparation-status.json',json.dumps(result,indent=2)+'\n')
 print(result['status'],flush=True)
if __name__=='__main__':
 try:main()
 except BaseException as ex:
  if OUT.exists():c.emit(OUT/'failure.json',json.dumps(dict(error=repr(ex),traceback=traceback.format_exc()),indent=2)+'\n')
  raise
