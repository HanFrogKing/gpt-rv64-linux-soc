#!/usr/bin/env python3
"""Build isolated OpenSBI derivative and physical candidate DT; no deployment."""
import json,os,shutil
from pathlib import Path
import integer_core_check as c
import build_artifact_guard_v2 as guard
import linux_platform as plat
R=c.ROOT;OUT=R/'build/rv64/r75-board-firmware-r2';c.OUT=OUT
guard.install(c,Path(__file__),'r75-board-firmware-r2');CREATED=False
UP=R/'build/rv64/linux/src/opensbi-1.6';SW=R/'sw/rv64/r75-cadence'
def tree(base):return {str(p.relative_to(base)):c.sha(p) for p in base.rglob('*') if p.is_file()}
def main():
 global CREATED
 c.require(not OUT.exists(),'preserve old firmware evidence')
 c.require(shutil.disk_usage('/mnt/e').free>10*1024**3 and shutil.disk_usage('/').free>5*1024**3,'firmware disk gate')
 OUT.mkdir();CREATED=True
 c.emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING_R75_BOARD_FIRMWARE_PREPARATION'))+'\n')
 unit=R/'build/rv64/r75-cadence-r1/run-status.json';uj=json.loads(unit.read_text())
 c.require(uj['status']=='PASS_R75_CADENCE_LOCAL_DRIVER_NOT_FIRMWARE_OR_BOARD','unit not accepted')
 for n,h in uj['source_sha256'].items():c.require(c.sha(R/n)==h,'unit source changed '+n)
 c.require(json.loads((UP/'.project-source-lock.json').read_text())==json.loads((R/'tools/linux-sources.lock.json').read_text())['opensbi'],'upstream source lock')
 before=tree(UP);source=OUT/'opensbi-derivative';shutil.copytree(UP,source)
 changed='lib/utils/serial/cadence-uart.c';shutil.copyfile(SW/'cadence-uart.c',source/changed)
 after=tree(source);c.require(set(after)==set(before),'unexpected source set')
 c.require([n for n in after if after[n]!=before[n]]==[changed],'not a single-driver overlay')
 c.emit(OUT/'source-lock.json',json.dumps(dict(upstream_source_sha256=before,derivative_source_sha256=after,
  changed_files=[changed],upstream_archive_sha256='d11702103f177a2914e94eec57ce5ed820296d874f6b6525c4482e55d71a3667',
  upstream_unmodified=True,derivative_is_not_pristine=True),indent=2)+'\n')
 prefix=OUT/'linker-prefix';prefix.mkdir()
 for n in ['ld','ld.bfd']:(prefix/n).symlink_to(plat.LINKER)
 build=OUT/'opensbi-build';build.mkdir()
 cmd=['make','-C',source,'O='+str(build),'PLATFORM=generic','PLATFORM_RISCV_XLEN=64','OPENSBI_CC_XLEN=64',
  'PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei','PLATFORM_RISCV_ABI=lp64','CROSS_COMPILE='+c.CROSS,
  'CC='+c.CROSS+'gcc -march=rv64ima_zicsr_zifencei -mabi=lp64 -B'+str(prefix)+'/',
  'LD='+str(plat.LINKER),'RELAX_FLAG=-mno-relax','FW_TEXT_START=0x80000000','FW_JUMP_ADDR=0x80200000',
  'FW_JUMP_FDT_ADDR=0x87e00000','FW_DYNAMIC=n','FW_PAYLOAD=n','FW_JUMP=y','OPENSBI_VERSION_GIT=','-j1']
 c.run('firmware-build',cmd,timeout=600)
 fw=build/'platform/generic/firmware/fw_jump.elf';plat.elf_entry(fw,0x80000000)
 attrs=c.run('firmware-attributes',[c.CROSS+'readelf','-h','-A',fw],timeout=30)
 c.require(int.from_bytes(fw.read_bytes()[48:52],'little')==0 and 'Tag_RISCV_arch: "rv64i' in attrs,'firmware ABI audit')
 for part in ['_f2','_d2','_c2','_v1']:c.require(part not in attrs,'unexpected firmware extension '+part)
 config=(build/'platform/generic/kconfig/.config').read_text()
 for name in ['FDT_SERIAL_CADENCE','SERIAL_CADENCE','FDT_TIMER_MTIMER','FDT_IPI_MSWI','SBI_ECALL_LEGACY']:
  c.require('CONFIG_'+name+'=y\n' in config,'firmware feature absent '+name)
 nm=c.run('firmware-symbols',[c.CROSS+'nm',fw],timeout=30)
 for name in ['cadence_uart_init','fdt_serial_cadence','aclint_mtimer_cold_init','aclint_mswi_cold_init']:c.require(name in nm,'missing linked backend '+name)
 for n in ['fw_jump.elf','fw_jump.bin']:shutil.copyfile(fw.with_name(n),OUT/n)
 shutil.copyfile(SW/'board-hvc.dts',OUT/'board-hvc.dts');(OUT/'boot-seed.bin').write_bytes(os.urandom(64));(OUT/'boot-seed.bin').chmod(0o600)
 c.run('compile-board-dt',['dtc','-I','dts','-O','dtb','-o',OUT/'board-hvc.dtb',OUT/'board-hvc.dts'],timeout=30)
 checks=[('/chosen','stdout-path','s','/soc/serial@e0000000:115200n8'),('/soc/serial@e0000000','clock-frequency','u','100000000'),
  ('/cpus','timebase-frequency','u','1000000'),('/memory@80000000','reg','x','0 80000000 0 8000000')]
 for i,(node,prop,kind,value) in enumerate(checks):
  got=c.run('dt-check-'+str(i),['fdtget','-t',kind,OUT/'board-hvc.dtb',node,prop],timeout=10).strip();c.require(got==value,'DT property mismatch '+node+'/'+prop)
 dts=(OUT/'board-hvc.dts').read_text();c.require(all(n not in dts for n in ['ns16550a','syscon-reboot','syscon-poweroff','serial@10000000']),'simulated device remains')
 c.require(tree(UP)==before and tree(source)==after,'source changed during build')
 artifacts=[OUT/'fw_jump.elf',OUT/'fw_jump.bin',OUT/'board-hvc.dts',OUT/'board-hvc.dtb',OUT/'boot-seed.bin',OUT/'source-lock.json',build/'platform/generic/kconfig/.config']
 report=dict(status='PREPARED_R75_PHYSICAL_CADENCE_FIRMWARE_AND_DT_NOT_BOOTED',source_sha256={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),SW/'cadence-uart.c',SW/'board-hvc.dts',R/'scripts/rv64/build_artifact_guard_v2.py']},
  local_driver_status_sha256=c.sha(unit),artifacts={str(p.relative_to(OUT)):dict(bytes=p.stat().st_size,sha256=c.sha(p)) for p in artifacts},
  load_plan=[dict(name='fw_jump.bin',cpu_address='0x80000000',ps_ddr_address='0x00000000'),dict(name='R72 r2 Linux Image',cpu_address='0x80200000',ps_ddr_address='0x00200000'),dict(name='board-hvc.dtb',cpu_address='0x87e00000',ps_ddr_address='0x07e00000')],
  physical_board_booted=False,firmware_on_own_rtl_booted=False,
  limitations=['GP0 and 64-to-32-bit path not yet implemented/accepted','ROM and SoC decode not yet implemented','CLINT only locally accepted','No PLIC/native UART interrupt/USB/display/board shutdown backend','New host entropy and DT must be generated for each board boot','Image/DT/firmware must be rechecked in a final source-locked load bundle'],steps=c.STEPS)
 c.emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n');print(report['status'],flush=True)
if __name__=='__main__':
 try:main()
 except Exception as ex:
  if CREATED:c.emit(OUT/'run-status.json',json.dumps(dict(status='FAIL_R75_BOARD_FIRMWARE_PREPARATION',error=str(ex),steps=c.STEPS),indent=2)+'\n')
  raise
