#!/usr/bin/env python3
"""R12 platform bring-up: real RTL + unmodified OpenSBI, then Linux."""
import argparse
import json
import os
import shutil
import time
from pathlib import Path
import integer_core_check as common

ROOT=common.ROOT;OUT=ROOT/'build/rv64/linux-platform';SW=ROOT/'sw/rv64/linux'
SOURCE=ROOT/'build/rv64/linux/src/opensbi-1.6'
LINKER=Path('/mnt/e/tool2/wsl-cpu-tools/binutils-riscv64-linux-gnu-2.45/bin/riscv64-linux-gnu-ld')
emit=common.emit;require=common.require;sha=common.sha
LOG_PREFIX=''
def run(tag,command,**kwargs):return common.run(LOG_PREFIX+tag,command,**kwargs)

def elf_entry(path,address):
    data=path.read_bytes()
    require(data[:6]==b'\x7fELF\x02\x01' and int.from_bytes(data[18:20],'little')==243,'ELF machine/class '+str(path))
    require(int.from_bytes(data[24:32],'little')==address and int.from_bytes(data[48:52],'little')&7==0,'ELF entry/ABI '+str(path))

def firmware():
    lock=json.loads((ROOT/'tools/linux-sources.lock.json').read_text())['opensbi']
    require(json.loads((SOURCE/'.project-source-lock.json').read_text())==lock,'OpenSBI source lock')
    tool=LINKER.parents[1]/'project-source-lock.json'
    require(json.loads(tool.read_text())['archive_sha256']=='c50c0e7f9cb188980e2cc97e4537626b1672441815587f1eab69d2a1bfbef5d2','GNU linker source lock')
    version=run('platform-linker-version',[LINKER,'--version']);require('2.45' in version,'platform linker version')
    prefix=OUT/'linker-prefix-2.45';prefix.mkdir(parents=True,exist_ok=True)
    for name in ['ld','ld.bfd']:
        item=prefix/name
        if not item.exists():item.symlink_to(LINKER)
        require(item.is_symlink() and item.resolve()==LINKER,'linker shim differs')
    directory=OUT/'opensbi-build-v1.6'
    command=['make','-C',SOURCE,'O='+str(directory),'PLATFORM=generic','PLATFORM_RISCV_XLEN=64','OPENSBI_CC_XLEN=64',
      'PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei','PLATFORM_RISCV_ABI=lp64','CROSS_COMPILE='+common.CROSS,
      'CC='+common.CROSS+'gcc -march=rv64ima_zicsr_zifencei -mabi=lp64 -B'+str(prefix)+'/',
      'LD='+str(LINKER),'RELAX_FLAG=-mno-relax','FW_TEXT_START=0x80000000','FW_JUMP_ADDR=0x80200000',
      'FW_JUMP_FDT_ADDR=0x87e00000','FW_DYNAMIC=n','FW_PAYLOAD=n','FW_JUMP=y','OPENSBI_VERSION_GIT=','-j2']
    run('platform-opensbi-build',command,timeout=300)
    elf=directory/'platform/generic/firmware/fw_jump.elf'
    attributes=run('platform-opensbi-attributes',[common.CROSS+'readelf','-A',elf])
    elf_entry(elf,0x80000000)
    import linux_software
    require(not linux_software.re_has_unsupported(attributes),'firmware has unsupported instructions')
    return elf.with_suffix('.bin')

def software(debug_init=False):
    seed=OUT/'boot-seed.bin';seed.write_bytes(os.urandom(64));seed.chmod(0o600)
    run('platform-dtc',['dtc','-i',OUT,'-I','dts','-O','dtb','-o',OUT/'platform.dtb',SW/'platform.dts'])
    if debug_init:
        args=run('platform-bootargs',['fdtget',OUT/'platform.dtb','/chosen','bootargs']).strip()
        run('platform-initcall-debug',['fdtput','-t','s',OUT/'platform.dtb','/chosen','bootargs',args.replace('loglevel=7','loglevel=8')+' initcall_debug'])
    base=['-march=rv64ima_zicsr_zifencei','-mabi=lp64','-mcmodel=medany','-nostdlib','-mno-relax','-msmall-data-limit=0','-Wl,--build-id=none']
    run('platform-rom-build',[common.CROSS+'gcc',*base,'-Ttext=0x1000',SW/'bootrom.S','-o',OUT/'bootrom.elf'])
    run('platform-rom-binary',[common.CROSS+'objcopy','-O','binary',OUT/'bootrom.elf',OUT/'bootrom.bin'])
    link=OUT/'probe.ld';emit(link,'OUTPUT_ARCH(riscv)\nENTRY(_start)\nSECTIONS { . = 0x80200000; .text : { *(.text*) } .rodata : { *(.rodata*) } .data : { *(.data*) *(.sdata*) } .bss : { *(.bss*) *(.sbss*) *(COMMON) } ASSERT(. < 0x8021c000, "probe overlaps stack") }\n')
    run('platform-probe-build',[common.CROSS+'gcc',*base,'-O2','-ffreestanding','-fno-builtin','-fno-stack-protector',
      '-Wall','-Wextra','-Werror','-T',link,SW/'sbi-probe-start.S',SW/'sbi-probe.c','-o',OUT/'sbi-probe.elf'])
    run('platform-probe-binary',[common.CROSS+'objcopy','-O','binary',OUT/'sbi-probe.elf',OUT/'sbi-probe.bin'])
    elf_entry(OUT/'bootrom.elf',0x1000);elf_entry(OUT/'sbi-probe.elf',0x80200000)

def build():
    directory=OUT/'sim/linux';directory.mkdir(parents=True,exist_ok=True)
    run('platform-rtl-build',[common.CAD+'/verilator','--cc','--exe','--build','-j','2','--Wall',
      '--x-initial','unique','--x-assign','unique','--top-module','rv64_integer_core',
      "-GRESET_PC=64'h1000",'-GENABLE_PRIV=1','-GENABLE_SU=1','-GENABLE_A=1','-GHAS_MMU=1',
      '--Mdir',directory,'-CFLAGS','-O3 -std=c++17 -Wall -Wextra -Werror',*common.SOURCES,ROOT/'sim/rv64/linux_platform.cpp'],timeout=180)
    return directory/'Vrv64_integer_core'

def main():
    global LOG_PREFIX
    parser=argparse.ArgumentParser();parser.add_argument('--linux',action='store_true');parser.add_argument('--random',action='store_true');parser.add_argument('--check',action='store_true');parser.add_argument('--debug-init',action='store_true');parser.add_argument('--cycles',type=int);args=parser.parse_args()
    OUT.mkdir(parents=True,exist_ok=True);common.OUT=OUT
    emit(OUT/'run-status.json','{"status":"RUNNING"}\n');start=time.monotonic()
    guard=common.load('platform_guard',ROOT/'scripts/rv64/alu_check.py');frozen=guard.preserve_rv32()
    for tag,command in [('verilator',[common.CAD+'/verilator','--version']),('gcc',[common.CROSS+'gcc','--version']),
                        ('cxx',['g++','--version']),('dtc',['dtc','--version'])]:run('version-'+tag,command)
    fw=firmware();software(args.debug_init);exe=build();cases=[]
    image=ROOT/'build/rv64/linux/kernel-build/arch/riscv/boot/Image'
    modes=['probe','random','linux-reboot','linux-random'] if args.check else ['linux-random' if args.linux and args.random else 'linux' if args.linux else 'random' if args.random else 'probe']
    if args.check:
        evidence=json.loads((ROOT/'reports/RV64_R10_LINUX_SOFTWARE.json').read_text())
        require(all(sha(ROOT/p)==digest for p,digest in evidence['source_sha256'].items()),'stale Linux software source; rebuild userspace and kernel')
        require(all(sha(ROOT/'build/rv64/linux'/p)==digest for p,digest in evidence['payload_sha256'].items()),'Linux payload changed')
    for mode in modes:
        # Each independent host boot gets a fresh real seed. Keep the seed/DTB
        # alongside the exact command and hashes so that run can be replayed.
        LOG_PREFIX=mode+'-';software(args.debug_init)
        directory=OUT/'cases'/mode;directory.mkdir(parents=True,exist_ok=True)
        for name in ['boot-seed.bin','platform.dtb']:
            shutil.copyfile(OUT/name,directory/name)
        (directory/'boot-seed.bin').chmod(0o600)
        payload=image if mode.startswith('linux') else OUT/'sbi-probe.bin'
        budget=args.cycles or (1600000000 if mode=='linux-random' else 900000000 if mode.startswith('linux') else 100000000)
        command=[exe,OUT/'bootrom.bin',fw,payload,directory/'platform.dtb',mode,str(budget),directory/'uart.log',directory/'stats.jsonl']
        emit(directory/'command.json',json.dumps([str(x) for x in command],indent=2)+'\n')
        run('boot',command,timeout=1800)
        boots=[json.loads(x) for x in (directory/'stats.jsonl').read_text().splitlines()]
        require([x['reset'] for x in boots]==([2,1] if mode=='linux-reboot' else [1]),'boot/reset count '+mode)
        require([x['index'] for x in boots]==list(range(len(boots))),'boot index '+mode)
        uart=(directory/'uart.log').read_bytes()
        require(uart.count(b'OpenSBI v1.6\r\n')==len(boots),'firmware runtime identity '+mode)
        if mode.startswith('linux'):
            require(uart.count(b'Linux version 6.6.80-rv64lab ')==len(boots) and
                    uart.count(b'BusyBox v1.36.1 ')==len(boots),'Linux/BusyBox runtime identity '+mode)
        cases.append(dict(mode=mode,boots=boots,command=[str(x) for x in command],
          input_sha256={str(p.relative_to(ROOT)):sha(p) for p in [exe,OUT/'bootrom.bin',fw,payload,directory/'platform.dtb',directory/'boot-seed.bin']},
          uart_sha256=sha(directory/'uart.log'),stats_sha256=sha(directory/'stats.jsonl')))
    # Real RTL timeout is an expected failure, never usable as boot evidence.
    if args.check:
        LOG_PREFIX='check-'
        run('reject-cycle-budget',[exe,OUT/'bootrom.bin',fw,image,OUT/'platform.dtb','linux','1',OUT/'negative-uart.log',OUT/'negative-stats.jsonl'],negative='PLATFORM_FAIL cycle_budget_exhausted')
        seeds={x['mode']:next(v for p,v in x['input_sha256'].items() if p.endswith('boot-seed.bin')) for x in cases}
        require(seeds['linux-reboot']!=seeds['linux-random'],'cold boot entropy reused')
    require(guard.preserve_rv32()==frozen,'RV32 frozen sources changed')
    sources=common.SOURCES+[Path(__file__),ROOT/'sim/rv64/platform.hpp',ROOT/'sim/rv64/linux_platform.cpp',ROOT/'scripts/rv64/integer_core_check.py',ROOT/'tools/linux-sources.lock.json']+sorted(p for p in SW.glob('*') if p.is_file())
    report=dict(status='PASS_R64_12_LINUX_RTL_CLOSURE' if args.check else 'PASS_REQUESTED_PLATFORM_BOOT',
      linux_booted=any(x['mode'].startswith('linux') for x in cases),acceptance=args.check,
      rv32_tests_run=False,rv64_coremark=None,fpga_tested=False,cases=cases,
      limitations=['Physical C++ RAM/CLINT/UART/syscon model; no FPGA/DDR/cache/PLIC/display acceptance',
        'UART uses Linux 8250 timer polling; functional byte transport, no baud/FIFO-overrun timing model',
        'Guest reboot restores loader images and resets RTL/devices while retaining other RAM'],
      source_sha256={str(p.relative_to(ROOT)):sha(p) for p in sources},
      steps=common.STEPS,total_wall_seconds=round(time.monotonic()-start,3),
      log_sha256={s['name']+'.log':sha(OUT/(s['name']+'.log')) for s in common.STEPS})
    emit(OUT/'run-status.json',json.dumps(report,indent=2)+'\n')
    if args.check:emit(ROOT/'reports/RV64_R12_LINUX_PLATFORM.json',json.dumps(report,indent=2)+'\n')
    print(report['status'],flush=True)
if __name__=='__main__':
    try:main()
    except Exception as e:emit(OUT/'run-status.json',json.dumps(dict(status='FAIL',error=str(e)))+'\n');raise
