#!/usr/bin/env python3
"""R54 software preparation only. No board/device writes, no frozen gate edits."""
import json, os, re, shutil, subprocess, sys
from pathlib import Path
import integer_core_check as common
import linux_software as software
import build_artifact_guard_v2 as guard

ROOT=common.ROOT
OLD=ROOT/'build/rv64/linux'
OUT=ROOT/'build/rv64/r54-linux-board-prep'
SW=ROOT/'sw/rv64/r54-linux-board-prep'
SOURCE=OLD/'src/linux-6.6.80'
CROSS=common.CROSS
BUILD=OUT/'kernel-build'

def emit(path, value):
    common.emit(path, json.dumps(value,indent=2)+'\n' if isinstance(value,dict) else value)

def run(tag, cmd, **kwargs):
    common.require(shutil.disk_usage('/mnt/e').free>10*1024**3,'E below 10 GiB')
    common.require(shutil.disk_usage('/').free>5*1024**3,'WSL below 5 GiB')
    return common.run(tag,cmd,**kwargs)

def check_elf(name, path):
    b=path.read_bytes()
    common.require(b[:6]==b'\x7fELF\x02\x01' and int.from_bytes(b[18:20],'little')==243,'not RV64 ELF: '+name)
    common.require(int.from_bytes(b[48:52],'little')&7==0,'RVC or FP ABI: '+name)
    attrs=run(name+'-attributes',[CROSS+'readelf','-A',path])
    common.require(not software.re_has_unsupported(attrs),'unsupported ISA: '+name)
    headers=run(name+'-headers',[CROSS+'readelf','-l',path])
    common.require('INTERP' not in headers,'dynamic interpreter: '+name)

def main():
    OUT.mkdir(parents=True,exist_ok=True); common.OUT=OUT
    guard.install(common,Path(__file__),'r54-linux-board-prep')
    emit(OUT/'run-status.json',dict(status='RUNNING_SOFTWARE_PREPARATION',board_booted=False))
    lock=json.loads((ROOT/'tools/linux-sources.lock.json').read_text())
    for name in ['linux','busybox','musl','opensbi']:
        common.require(json.loads((OLD/'src'/lock[name]['directory']/'.project-source-lock.json').read_text())==lock[name],name+' source identity')
    dependencies={t:shutil.which(t) for t in ['make','gcc','g++','dtc','fdtget','flex','bison','bc','cpio','gzip','xz','mke2fs','debugfs','e2fsck','mkimage','genimage']}
    common.require(all(dependencies[t] for t in ['make','gcc','dtc','flex','bison','bc','cpio','mke2fs','debugfs','e2fsck']),'required host tool absent')
    emit(OUT/'dependencies.json',dict(tools=dependencies,optional_not_required=['mkimage','genimage'],source_lock_sha256=common.sha(ROOT/'tools/linux-sources.lock.json')))
    sdk=json.loads((OLD/'sdk-status.json').read_text()); prefix=Path(sdk['identity']['prefix'])
    common.require(common.sha(prefix/'lib/libc.a')==sdk['libc_sha256'],'libc changed')
    common.require(common.sha(OLD/'static-musl.specs')==sdk['static_specs_sha256'],'specs changed')
    flags=sdk['identity']['flags']+' -D__linux__=1 -D__unix__=1'
    cc=' '.join(sdk['compiler_command'])+' '+flags
    bb=OUT/'busybox-build';bb.mkdir(exist_ok=True)
    base=['env','SOURCE_DATE_EPOCH=0','KCONFIG_NOTIMESTAMP=1','make','-C',OLD/'src/busybox-1.36.1','O='+str(bb),'ARCH=riscv','CROSS_COMPILE='+CROSS,'CC='+cc,'EXTRA_CFLAGS='+flags+''' -DBB_EXTRA_VERSION='" (rv64lab-r54)"' ''']
    run('busybox-base',base+['allnoconfig'])
    run('busybox-merge',['sh',SOURCE/'scripts/kconfig/merge_config.sh','-m','-O',bb,bb/'.config',ROOT/'sw/rv64/linux/busybox.config',SW/'busybox-extra.config'])
    shutil.copyfile(bb/'.config',bb/'project-merged.config')
    run('busybox-config',base+['KBUILD_DEFCONFIG='+str(bb/'project-merged.config'),'defconfig'])
    required_bb=['STATIC','ASH','INIT','MOUNT','SWITCH_ROOT','MDEV','BLKID','FINDFS','LSUSB','MKNOD','FEATURE_MOUNT_LABEL']
    text=(bb/'.config').read_text()
    for n in required_bb:common.require('CONFIG_'+n+'=y' in text,'BusyBox missing '+n)
    run('busybox-build',base+['-j2'],timeout=600)
    root=OUT/'rootfs'
    run('busybox-install',base+['CONFIG_PREFIX='+str(root),'install'])
    for d in ['dev','etc','proc','sys','tmp','root','newroot','mnt']:(root/d).mkdir(exist_ok=True)
    for name in ['init','rcS','inittab']:
        dest=root/('init' if name=='init' else 'etc/'+name)
        shutil.copyfile(SW/name,dest);dest.chmod(0o644 if name=='inittab' else 0o755)
    shutil.copyfile(OLD/'linux-selftest.elf',root/'bin/linux-selftest')
    (root/'bin/linux-selftest').chmod(0o755)
    (root/'etc/os-release').write_text('NAME="RV64Lab recovery"\nID=rv64lab\nVERSION_ID=54\nPRETTY_NAME="RV64IMA/LP64 recovery (not Ubuntu or Debian)"\n')
    check_elf('busybox',bb/'busybox');check_elf('linux-selftest',root/'bin/linux-selftest')
    run('host-shell-syntax-init',['sh','-n',root/'init']);run('host-shell-syntax-rcS',['sh','-n',root/'etc/rcS'])
    tool=OUT/'gen_init_cpio';run('gen-init-cpio-build',['gcc','-O2','-Wall',SOURCE/'usr/gen_init_cpio.c','-o',tool])
    listing=['dir / 755 0 0']
    for p in sorted(root.rglob('*')):
        name='/'+str(p.relative_to(root))
        if p.is_symlink():listing.append(f'slink {name} {p.readlink()} 777 0 0')
        elif p.is_dir():listing.append(f'dir {name} 755 0 0')
        else:listing.append(f'file {name} {p} {p.stat().st_mode&0o777:o} 0 0')
    listing+=['nod /dev/console 600 0 0 c 5 1','nod /dev/null 666 0 0 c 1 3','nod /dev/ttyS0 600 0 0 c 4 64']
    emit(OUT/'initramfs.list','\n'.join(listing)+'\n')
    with (OUT/'initramfs.cpio').open('wb') as f:subprocess.run([str(tool),'-t','0',str(OUT/'initramfs.list')],stdout=f,check=True)
    BUILD.mkdir(exist_ok=True)
    ld=Path('/mnt/e/path/rv64-linux-ld')
    common.require(ld.is_file() and ld.read_bytes()==(ROOT/'tools/rv64-linux-ld').read_bytes(),'existing linker wrapper identity')
    kb=['make','-C',SOURCE,'O='+str(BUILD),'ARCH=riscv','CROSS_COMPILE='+CROSS,'LD='+str(ld),'KBUILD_BUILD_USER=rv64lab','KBUILD_BUILD_HOST=prep','KBUILD_BUILD_VERSION=1','KBUILD_BUILD_TIMESTAMP=1970-01-01 00:00:00 +0000']
    run('kernel-tiny',kb+['tinyconfig'])
    emit(OUT/'kernel-project.config',(ROOT/'sw/rv64/linux/linux.config').read_text()+'\n'+(SW/'kernel-extra.config').read_text()+f'\nCONFIG_INITRAMFS_SOURCE="{OUT}/initramfs.cpio"\n')
    run('kernel-merge',['sh',SOURCE/'scripts/kconfig/merge_config.sh','-m','-O',BUILD,BUILD/'.config',OUT/'kernel-project.config'])
    run('kernel-config',kb+['olddefconfig'])
    required=['64BIT','MMU','RISCV_SBI','SIFIVE_PLIC','BLOCK','SCSI','BLK_DEV_SD','USB','USB_EHCI_HCD','USB_CHIPIDEA','USB_CHIPIDEA_HOST','USB_CHIPIDEA_GENERIC','USB_STORAGE','USB_HID','INPUT_EVDEV','EXT4_FS','MSDOS_PARTITION','EFI_PARTITION','SERIAL_XILINX_PS_UART_CONSOLE','DRM_SIMPLEDRM','FRAMEBUFFER_CONSOLE']
    cfg=(BUILD/'.config').read_text()
    actual={n:('y' if 'CONFIG_'+n+'=y' in cfg else 'MISSING') for n in required}
    emit(OUT/'kernel-feature-audit.json',dict(required=actual,devices_tested=False))
    common.require('MISSING' not in actual.values(),'kernel required config missing '+str(actual))
    for n in ['FPU','RISCV_ISA_C','RISCV_ISA_V','SMP']:common.require('CONFIG_'+n+'=y' not in cfg,'unexpected ISA/platform '+n)
    run('kernel-build',kb+['-j2','Image'],timeout=1800)
    commands={};arches=set()
    for p in BUILD.rglob('.*.cmd'):
        lines=p.read_text(errors='replace').splitlines()
        if not lines:continue
        t=lines[0]
        if CROSS+'gcc ' not in t or ' -c ' not in t:continue
        a=re.search(r'(?:^|\s)-march=([^\s]+)',t)
        common.require(a is not None and ' -mabi=lp64 ' in t,'kernel compile ABI/ISA absent '+str(p))
        common.require(a[1].startswith('rv64i') and not any(x in a[1].split('_')[0][4:] for x in 'cfd'),'unsupported base kernel ISA')
        common.require(not software.re_has_unsupported('Tag_RISCV_arch: "'+a[1]+'"'),'unsupported kernel extension')
        commands[str(p.relative_to(BUILD))]=common.sha(p);arches.add(a[1])
    common.require(len(commands)>100,'insufficient command audit')
    elf=(BUILD/'vmlinux').read_bytes();image=BUILD/'arch/riscv/boot/Image'
    common.require(int.from_bytes(elf[48:52],'little')&7==0,'kernel ABI flags')
    common.require(image.read_bytes()[48:56]==b'RISCV\0\0\0','Image magic')
    emit(OUT/'kernel-compile-isa.json',dict(commands=commands,architectures=sorted(arches)))
    # This DT is exclusively the existing simulation map, NOT a board DT.
    (OUT/'boot-seed.bin').write_bytes(os.urandom(64))
    emit(OUT/'simulation-only.dts',(ROOT/'sw/rv64/linux/platform.dts').read_text())
    run('simulation-dtb',['dtc','-I','dts','-O','dtb','-o',OUT/'simulation-only.dtb',OUT/'simulation-only.dts'])
    run('dtb-isa-readback',['fdtget',OUT/'simulation-only.dtb','/cpus/cpu@0','riscv,isa'])
    # Ordinary sparse filesystem file; never enumerate or open block devices.
    disk=OUT/'rootfs.ext4'
    common.require(not disk.exists() or disk.is_file() and not disk.is_symlink(),'unsafe image path')
    with disk.open('wb') as f:f.truncate(64*1024**2)
    run('ext4-populate',['mke2fs','-q','-F','-t','ext4','-L','RV64ROOT','-O','^64bit,^metadata_csum','-E','root_owner=0:0','-d',root,disk])
    # Populate char nodes without privilege; commands affect the image file only.
    nodecmd=OUT/'debugfs-devices.txt'
    ownership=[]
    for p in sorted(root.rglob('*')):
        n='/'+str(p.relative_to(root))
        ownership += [f'set_inode_field {n} uid 0',f'set_inode_field {n} gid 0']
    emit(nodecmd,'\n'.join(ownership)+'\ncd /dev\nmknod console c 5 1\nset_inode_field console mode 020600\nmknod null c 1 3\nset_inode_field null mode 020666\nmknod ttyS0 c 4 64\nset_inode_field ttyS0 mode 020600\n')
    run('ext4-device-nodes',['debugfs','-w','-f',nodecmd,disk])
    run('ext4-fsck',['e2fsck','-f','-n',disk])
    run('ext4-inspect',['debugfs','-R','stat /sbin/init',disk])
    firmware=ROOT/'build/rv64/linux-platform/opensbi-build-v1.6/platform/generic/firmware/fw_jump.bin'
    common.require(firmware.is_file(),'existing firmware absent')
    artifacts={}
    for name,p in [('Image',image),('vmlinux',BUILD/'vmlinux'),('initramfs.cpio',OUT/'initramfs.cpio'),('rootfs.ext4',disk),('simulation-only.dtb',OUT/'simulation-only.dtb'),('busybox',bb/'busybox'),('fw_jump.bin',firmware)]:
        artifacts[name]=dict(path=str(p),bytes=p.stat().st_size,allocated_bytes=p.stat().st_blocks*512,sha256=common.sha(p))
    sources=[Path(__file__),ROOT/'tools/linux-sources.lock.json',ROOT/'scripts/rv64/build_artifact_guard_v2.py',*sorted(SW.glob('*'))]
    emit(OUT/'run-status.json',dict(status='PASS_SOFTWARE_BUILD_ISA_AND_FILESYSTEM_CHECKS_NOT_BOOTED',clock_target_mhz=50,board_booted=False,new_kernel_booted=False,usb_tested=False,hdmi_tested=False,rv32_tests_run=False,source_sha256={str(p.relative_to(ROOT)):common.sha(p) for p in sources if p.is_file()},artifacts=artifacts,kernel_required=actual,steps=common.STEPS,logs={s['name']+'.log':common.sha(OUT/(s['name']+'.log')) for s in common.STEPS}))

if __name__=='__main__':
    try:main()
    except Exception as e:
        OUT.mkdir(parents=True,exist_ok=True)
        emit(OUT/'run-status.json',dict(status='FAIL_SOFTWARE_PREPARATION',error=str(e),board_booted=False))
        raise
