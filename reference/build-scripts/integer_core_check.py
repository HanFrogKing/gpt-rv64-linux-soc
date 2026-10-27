#!/usr/bin/env python3
"""R64-04: real GNU programs + pinned Spike retirement, delayed AXI-Lite host.

This is not a replacement ISA execution emulator. ALU/GPR values come from Spike;
the pinned decode metadata supplies source-register identities and trace checks.
RV32 is read-only/frozen and never built or run.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import re
import signal
import subprocess
import sys
import time

if not __debug__:raise SystemExit('Run without -O/PYTHONOPTIMIZE')
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'build/rv64/r04'
CAD='/opt/rv32-tools/oss-cad-suite-20261019/bin'
CROSS='/opt/rv32-tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-'
SPIKE=Path('/mnt/e/tool2/spike-linux/5a760667/bin/spike')
RTL=ROOT/'rtl/rv64/rv64_integer_core.sv'
SOURCES=[ROOT/'rtl/rv64'/n for n in ['rv64_alu.sv','rv64_decode.sv','rv64_regfile.sv','rv64_lsu.sv','rv64_muldiv.sv','rv64_csr.sv','rv64_atomic.sv','rv64_mmu.sv','rv64_integer_core.sv']]
PROPS=ROOT/'formal/rv64/integer_core_properties.svh';UNIT=ROOT/'sim/rv64/integer_core_test.cpp'
MASK=(1<<64)-1;STEPS=[]

def require(ok,why):
    if not ok:raise RuntimeError(why)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def emit(p,s):
    p.parent.mkdir(parents=True,exist_ok=True)
    if not p.exists() or p.read_text()!=s:p.write_text(s)
def run(tag,cmd,negative=None,timeout=300):
    start=time.monotonic();cmd=[str(v) for v in cmd];env=None
    if Path(cmd[0]).name=='yosys-smtbmc':env=dict(os.environ,PATH=CAD+':'+os.environ.get('PATH',''))
    # Stream diagnostics to disk, including timeouts. Kill only this owned tool
    # process group on timeout, so an SMT solver cannot remain running orphaned.
    logfile=OUT/(tag+'.log')
    with logfile.open('w') as output:
        p=subprocess.Popen(cmd,cwd=ROOT,stdout=output,stderr=subprocess.STDOUT,env=env,start_new_session=True)
        try:p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.wait();raise RuntimeError(tag+': TIMEOUT, see '+str(logfile))
    log=logfile.read_text()
    if negative:require(p.returncode==1 and negative in log,tag+': wrong rejection '+log[-3000:])
    else:require(p.returncode==0,tag+': '+log[-5000:])
    STEPS.append(dict(name=tag,status='EXPECTED_FAILURE' if negative else 'PASS',command=cmd,seconds=round(time.monotonic()-start,3)))
    print(STEPS[-1]['status'],tag,flush=True);return log
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,file);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def positive_source(seed):
    rng=random.Random(seed)
    lines=[f'addi x{i}, x0, 0' for i in range(1,32)]
    lines+=['li x3, -1','li x4, 1','li x5, 0x8000000000000001','li x6, 0x7fffffff']
    rops=['add','sub','sll','slt','sltu','xor','srl','sra','or','and','addw','subw','sllw','srlw','sraw']
    iops=['addi','slti','sltiu','xori','ori','andi','addiw','slli','srli','srai','slliw','srliw','sraiw']
    for op in rops:lines.append(f'{op} x10, x5, x4')
    for op in iops:
        imm=63 if op in ['slli','srli','srai'] else 31 if op in ['slliw','srliw','sraiw'] else -1
        lines.append(f'{op} x11, x5, {imm}')
    lines+=['lui x12, 0x80000','auipc x13, 0x80000','addi x0, x0, 1',
            'li x7, 40','.Lloop:','addi x5, x5, 1','addi x7, x7, -1','bne x7, x0, .Lloop']
    pairs={'beq':[(3,3),(3,4)],'bne':[(3,4),(3,3)],'blt':[(3,4),(4,3)],
           'bge':[(4,3),(3,4)],'bltu':[(4,3),(3,4)],'bgeu':[(3,4),(4,3)]}
    for op,choices in pairs.items():
        for i,(a,b) in enumerate(choices):
            label=f'.L{op}_{i}';lines += [f'{op} x{a}, x{b}, {label}','addi x9, x9, 1',label+':']
    lines+=['beq x0, x4, .+2'] # Misaligned target must NOT trap if branch is not taken.
    for _ in range(300):
        op=rng.choice(rops+iops);rd=rng.randrange(3,28);a=rng.randrange(3,28)
        if op in rops:lines.append(f'{op} x{rd}, x{a}, x{rng.randrange(3,28)}')
        else:
            imm=rng.randrange(64) if op in ['slli','srli','srai'] else rng.randrange(32) if op in ['slliw','srliw','sraiw'] else rng.randrange(-2048,2048)
            lines.append(f'{op} x{rd}, x{a}, {imm}')
    lines += ['jal x1, .Lfunction','jal x0, .Lafter_function','.Lfunction:',
        'addi x8, x8, 7','jalr x0, 0(x1)','.Lafter_function:',
        'la x5, .Lodd_target','ori x5, x5, 1','jalr x5, 0(x5)',
        'addi x9, x9, 123','.Lodd_target:','addi x5, x5, 1']
    return lines

def assemble(tag,lines,base,last='j .'):
    folder=OUT/'programs'/tag
    source=folder/'program.S';elf=folder/'program.elf';binary=folder/'program.bin'
    text='.option norvc\n.option norelax\n.text\n.globl _start\n_start:\n'+'\n'.join(lines)+'\n.globl done\ndone:\n'+last+'\n'
    emit(source,text)
    linker=folder/'link.ld'
    emit(linker,'OUTPUT_ARCH(riscv)\nENTRY(_start)\nPHDRS { text PT_LOAD FLAGS(5); }\n'
         f'SECTIONS {{ . = 0x{base:x}; .text : {{ *(.text*) }} :text }}\n')
    run('assemble-'+tag,[CROSS+'gcc','-march=rv64i_zifencei','-mabi=lp64','-nostdlib','-mno-relax',
        '-T',linker,'-Wl,--build-id=none',source,'-o',elf])
    run('binary-'+tag,[CROSS+'objcopy','-O','binary','--only-section=.text',elf,binary])
    syms=run('symbols-'+tag,[CROSS+'nm','-n',elf])
    symbols={f[2]:int(f[0],16) for line in syms.splitlines() if len(f:=line.split())==3}
    return dict(tag=tag,base=base,done=symbols['done'],source=source,elf=elf,binary=binary)

def parse_spike(text,program,decode):
    image=program['binary'].read_bytes();base=program['base'];registers=[0]*32;records=[];done_count=0;families={};branches={}
    patterns=decode.load_patterns();meta=decode.metadata()
    for line in text.splitlines():
        m=re.fullmatch(r'core\s+0:\s+3\s+0x([0-9a-f]{16})\s+\(0x([0-9a-f]{8})\)(.*)',line)
        require(m is not None,'SPIKE_SYNTAX')
        pc,insn=int(m[1],16),int(m[2],16);payload=m[3].strip()
        require(base<=pc and pc-base+4<=len(image) and pc%4==0,'SPIKE_PC_RANGE')
        require(insn==int.from_bytes(image[pc-base:pc-base+4],'little'),'SPIKE_ELF_MISMATCH')
        values,name=decode.model(insn,patterns,meta);d=dict(zip(decode.FIELDS,values))
        require(not d['illegal'] and d['kind'] in [1,4,5,6],'SPIKE_UNSUPPORTED')
        rd=value=0
        if payload:
            w=re.fullmatch(r'x\s*(\d+)\s+0x([0-9a-f]+)',payload);require(w is not None,'SPIKE_EFFECT')
            require(len(w[2])==16,'SPIKE_GPR_WIDTH');rd=int(w[1]);value=int(w[2],16)
        require(rd==d['rd'] and 0<=rd<32,'SPIKE_DESTINATION')
        if done_count:
            require(pc==program['done'] and insn==0x0000006f and rd==0,'SPIKE_DONE_TAIL')
        elif pc==program['done']:
            require(insn==0x0000006f,'SPIKE_DONE_ENCODING')
        else:require(done_count==0,'SPIKE_AFTER_DONE')
        if records and not done_count:
            previous=records[-1]
            require(pc in previous['allowed_next'],'SPIKE_NEXT_PC')
            previous['row'][4]=pc
            if previous['branch'] is not None:
                key=previous['branch']+('-taken' if pc!=(previous['row'][0]+4)&MASK else '-not-taken')
                branches[key]=branches.get(key,0)+1
        if not done_count:
            a=registers[d['rs1']];b=registers[d['rs2']]
            row=[pc,insn,rd,value if rd else 0,pc,d['rs1'],d['rs2'],a,b]
            nexts=[(pc+4)&MASK]
            if d['kind']==4:nexts.append((pc+d['imm'])&MASK)
            elif d['kind']==5:nexts=[(pc+d['imm'])&MASK]
            elif d['kind']==6:nexts=[((a+d['imm'])&MASK)&~1]
            records.append(dict(row=row,allowed_next=nexts,branch=name if d['kind']==4 else None))
            families[name]=families.get(name,0)+1
        if rd:registers[rd]=value
        if pc==program['done']:done_count+=1
    require(done_count>=2,'SPIKE_NO_DONE')
    records[-1]['row'][4]=program['done']
    return [r['row'] for r in records],families,branches

def reference(program,decode):
    raw=OUT/'programs'/program['tag']/'spike.commit'
    run('spike-'+program['tag'],[SPIKE,'--isa=RV64I_Zifencei','--priv=m',f'--pcs=0:0x{program["base"]:x}',
        f'-m0x{program["base"]:x}:0x200000','--log-commits','--log='+str(raw),'--instructions=8000',program['elf']])
    text=raw.read_text();rows,families,branches=parse_spike(text,program,decode)
    spec=OUT/'programs'/program['tag']/'case.txt'
    emit(spec,f'BASE {program["base"]:x}\n'+''.join('STEP '+' '.join(f'{v:x}' for v in r)+'\n' for r in rows))
    program.update(spec=spec,trace=raw,rows=rows,families=families,branches=branches)
    return text

def parser_controls(text,program,decode):
    first=text.splitlines()[0];m=re.search(r'(x\s*\d+\s+0x)([0-9a-f]{16})',text);require(m is not None,'control GPR absent')
    short=text[:m.start(2)]+text[m.end(2)-8:]
    variants=[('truncated-gpr',short,'SPIKE_GPR_WIDTH'),('duplicate-step',first+'\n'+text,'SPIKE_NEXT_PC'),
              ('missing-done','\n'.join(text.splitlines()[:10])+'\n','SPIKE_NO_DONE')]
    result=[]
    for name,bad,reason in variants:
        try:parse_spike(bad,program,decode)
        except RuntimeError as e:require(str(e)==reason,'wrong parser control '+str(e))
        else:raise RuntimeError('parser accepted '+name)
        result.append(dict(name=name,reason=reason,status='REJECTED'))
    return result

def build(tag,base,rtl=RTL):
    directory=OUT/'sim'/tag;directory.mkdir(parents=True,exist_ok=True)
    sources=[rtl if p==RTL else p for p in SOURCES]
    extra=['-Wno-UNUSEDSIGNAL'] if tag.startswith('negative-') else []
    run('build-'+tag,[CAD+'/verilator','--cc','--exe','--build','-j','2','--Wall',*extra,
        '--x-initial','unique','--x-assign','unique','--top-module','rv64_integer_core',
        f"-GRESET_PC=64'h{base:016x}",'--Mdir',directory,'-CFLAGS','-O2 -std=c++17',*sources,UNIT])
    return directory/'Vrv64_integer_core'

def host(tag,binary,program,mode='random',negative=False):
    log=run(tag,[binary,program['binary'],program['spec'],mode,'6404'],negative='CORE_FAIL' if negative else None)
    if negative:return None
    match=re.search(r'CORE PASS commits=(\d+) cycles=(\d+) ar=(\d+) r=(\d+) ar_stalls=(\d+) response_waits=(\d+) commit_stalls=(\d+) resets=(\d+) fault=(\d+)',log)
    require(match is not None,'missing host counts')
    result=dict(zip(['commits','cycles','ar','r','ar_stalls','response_waits','commit_stalls','resets','fault'],map(int,match.groups())))
    result.update(name=tag,mode=mode);return result

def faults(base,decode):
    prep=[f'addi x{i}, x0, 0' for i in range(1,32)]+['la x5, done','addi x5, x5, 3']
    ref=assemble('fault-reference',prep,base);reference(ref,decode)
    prefix=ref['rows'][:-1];pc=ref['done'];old5=next(r[3] for r in reversed(prefix) if r[2]==5)
    items=[('jal-align','jal x5, .+2',0,pc+2,0,0),
           ('jalr-align','jalr x5, 0(x5)',0,(old5&~1),0,0),
           ('branch-align','beq x0, x0, .+2',0,pc+2,0,0),
           ('illegal','.word 0xffffffff',2,0xffffffff,0,0),
           ('unsupported-amo','.word 0x000032af',2,None,0,0),
           ('unsupported-wfi','.word 0x10500073',2,None,0,0),
           ('unsupported-csr','csrrs x5, 0x300, x0',2,None,0,0),
           ('reserved-m-w1','.word 0x025092bb',2,None,0,0),
           ('reserved-m-w2','.word 0x0250a2bb',2,None,0,0),
           ('reserved-m-w3','.word 0x0250b2bb',2,None,0,0),
           ('unsupported-float','.word 0x005082d3',2,None,0,0),
           ('unsupported-compressed','.word 0x00010001',2,None,0,0),
           ('reserved-fence','.word 0x0000200f',2,None,0,0),
           ('ecall','ecall',11,0,0,0),('ebreak','ebreak',3,pc,0,0),
           ('fetch-slverr','addi x5,x0,999',1,pc,0,2),
           ('fetch-decerr','addi x5,x0,999',1,pc,0,3)]
    patterns=decode.load_patterns();meta=decode.metadata();result=[]
    for name,last,cause,tval,unsupported,resp in items:
        # Zicsr is used only to assemble the intentionally unsupported CSR fixture.
        actual='.word 0x300022f3' if name=='unsupported-csr' else last
        p=assemble('fault-'+name,prep,base,actual);require(p['done']==pc,'fault label drift')
        image=p['binary'].read_bytes();insn=0 if resp else int.from_bytes(image[pc-base:pc-base+4],'little')
        fields,_=decode.model(insn,patterns,meta);d=dict(zip(decode.FIELDS,fields));regs=[0]*32
        for r in prefix:
            if r[2]:regs[r[2]]=r[3]
        fault=[pc,insn,0,0,pc,d['rs1'],d['rs2'],regs[d['rs1']],regs[d['rs2']],unsupported,cause,insn if tval is None else tval]
        spec=p['source'].parent/'case.txt'
        text=f'BASE {base:x}\n'+''.join('STEP '+' '.join(f'{v:x}' for v in r)+'\n' for r in prefix)
        text+='FAULT '+' '.join(f'{v:x}' for v in fault)+'\n'
        if resp:text+=f'ERROR {pc:x} {resp:x}\n'
        emit(spec,text);p['spec']=spec;result.append(p)
    return result,ref

def prove(tag,rtl=RTL,negative=False):
    sources=' '.join(str(rtl if p==RTL else p) for p in SOURCES)
    netlist=OUT/('formal-'+tag+'.json')
    smt=OUT/('formal-'+tag+'.smt2')
    command=(f'read_verilog -formal -sv -D RV64_CORE_FORMAL -I{ROOT} {sources}; '
        'prep -top rv64_integer_core -flatten; async2sync; opt -full; delete -output; opt_clean -purge; '
        f'dffunmap; chformal -lower; write_json {netlist}; write_smt2 -wires {smt}')
    run('formal-prepare-'+tag,[CAD+'/yosys','-Q','-T','-p',command])
    types=[c['type'] for c in json.loads(netlist.read_text())['modules']['rv64_integer_core']['cells'].values()]
    require(types.count('$assert')==43 and types.count('$assume')==1,'formal property/assumption count')
    args=[CAD+'/yosys-smtbmc','-s','bitwuzla','--presat','-t','6']
    extra=['--dump-vcd',str(OUT/('counterexample-'+tag+'.vcd'))] if negative else []
    log=run('formal-bmc-'+tag,[*args,*extra,smt],negative='Status: FAILED' if negative else None,timeout=120)
    if not negative:
        require('Status: PASSED' in log,'no base case success')
        log=run('formal-induct-'+tag,[*args,'-i',smt],timeout=120)
        require('Status: PASSED' in log,'no unbounded safety proof')

def mutations(positive,fault_cases,base):
    text=RTL.read_text();cases=[]
    variants=[('ignore-arready','if(ar_fire) state_q<=S_R;','if(m_axi_arvalid_o) state_q<=S_R;',True),
      ('consume-invalid-response','S_R: if(r_fire) begin','S_R: if(m_axi_rready_o) begin',True),
      ('early-register-write','wire rf_we=commit_fire && !commit_trap_o && gpr_write;',
       'wire rf_we=commit_valid_o && !commit_trap_o && gpr_write;',True),
      ('write-on-trap','wire rf_we=commit_fire && !commit_trap_o && gpr_write;',
       'wire rf_we=commit_fire && gpr_write;',True),
      ('truncate-pc','pc_q<=next_pc;',"pc_q<={32'b0,next_pc[31:0]};",True),
      ('wrong-jump-link','wb_data=pc_q+64\'d4;','wb_data=target;',False),
      ('uncleared-jalr-bit',"target=alu_result & ~64'd1;",'target=alu_result;',False),
      ('unsigned-signed-branch','$signed(rf_r1) < $signed(rf_r2)','rf_r1 < rf_r2',False),
      ('ignore-fetch-error','if_error_q<=(m_axi_rresp_i!=0);',"if_error_q<=1'b0;",True)]
    for name,old,new,formal in variants:
        require(text.count(old)==1,'mutation anchor '+name)
        rtl=OUT/'mutants'/name/'rv64_integer_core.sv';emit(rtl,text.replace(old,new))
        exe=build('negative-'+name,base,rtl)
        case=next(p for p in fault_cases if p['tag']=='fault-jalr-align') if name=='write-on-trap' else next(p for p in fault_cases if p['tag']=='fault-fetch-slverr') if name=='ignore-fetch-error' else positive
        host('reject-'+name,exe,case,'long',True)
        if formal:prove(name,rtl,True)
        cases.append(dict(name=name,native='REJECTED',formal='BOUNDED_COUNTEREXAMPLE' if formal else 'NOT_AN_ISA_FORMAL_PROPERTY',rtl_sha256=sha(rtl)))
    return cases

def main():
    OUT.mkdir(parents=True,exist_ok=True);emit(OUT/'run-status.json',json.dumps(dict(status='RUNNING'))+'\n')
    old=load('alu_check',ROOT/'scripts/rv64/alu_check.py');frozen=old.preserve_rv32()
    decode=load('decode_check',ROOT/'scripts/rv64/decode_check.py')
    sys.path.insert(0,str(ROOT/'scripts'));from spike_regress import doctor
    identity=doctor(SPIKE)
    run('verilator-version',[CAD+'/verilator','--version']);run('yosys-version',[CAD+'/yosys','-V'])
    run('lint',[CAD+'/verilator','--lint-only','--Wall','--top-module','rv64_integer_core',*SOURCES])
    all_programs=[];coverage={};branch_coverage={};tests=[];binaries={}
    for base in [0x80000000,0x180000000]:
        binaries[base]=build('core-'+f'{base:x}',base)
        for seed in [64,6404]:
            p=assemble(f'positive-{base:x}-{seed}',positive_source(seed),base);text=reference(p,decode)
            for name,n in p['families'].items():coverage[name]=coverage.get(name,0)+n
            for name,n in p['branches'].items():branch_coverage[name]=branch_coverage.get(name,0)+n
            all_programs.append(p)
            for mode in ['fast','random','long']:tests.append(host('run-'+p['tag']+'-'+mode,binaries[base],p,mode))
    require(len(coverage)==38 and len(branch_coverage)==12,'missing execution/branch coverage')
    parser=parser_controls(text,p,decode)
    for mode in ['reset_ar','reset_r','reset_response','reset_commit']:
        tests.append(host('run-'+mode,binaries[0x180000000],all_programs[-1],mode))
    fault_cases,fault_reference=faults(0x180000000,decode)
    for p in fault_cases:tests.append(host('run-'+p['tag'],binaries[p['base']],p,'long'))
    bad=OUT/'corrupt-expected.txt';rows=all_programs[-1]['spec'].read_text().splitlines();fields=rows[1].split();fields[4]=f'{int(fields[4],16)^(1<<63):x}';rows[1]=' '.join(fields);emit(bad,'\n'.join(rows)+'\n')
    corrupt=dict(all_programs[-1],spec=bad);host('reject-corrupt-reference',binaries[corrupt['base']],corrupt,'fast',True)
    prove('correct')
    controls=mutations(all_programs[-1],fault_cases,0x180000000)
    require(old.preserve_rv32()==frozen,'RV32 frozen source changed')
    source_files=SOURCES+[PROPS,ROOT/'formal/rv64/memory_core_properties.svh',ROOT/'formal/rv64/muldiv_core_properties.svh',UNIT,Path(__file__),ROOT/'scripts/rv64/decode_check.py',ROOT/'scripts/rv64/alu_check.py',ROOT/'rv64.mk']
    report=dict(status='PASS_R64_04_INTEGER_EXECUTE',scope='R04 integer/control and fault regression on current RV64IM serial core; complete program qualification is R07',
      rv32_tests_run=False,rv32_frozen_sources_sha256=frozen,source_sha256={str(p.relative_to(ROOT)):sha(p) for p in source_files},
      spike=dict(identity=identity,isa='RV64I_Zifencei',termination='finite instruction budget; independently require done+self-loop tail',parser_controls=parser),
      programs=[dict(name=p['tag'],base=p['base'],commits=len(p['rows']),source_sha256=sha(p['source']),
          elf_sha256=sha(p['elf']),binary_sha256=sha(p['binary']),trace_sha256=sha(p['trace']),spec_sha256=sha(p['spec'])) for p in all_programs],
      fault_reference=dict(name=fault_reference['tag'],elf_sha256=sha(fault_reference['elf']),trace_sha256=sha(fault_reference['trace'])),
      fault_cases=[dict(name=p['tag'],base=p['base'],site=p['done'],source_sha256=sha(p['source']),
          elf_sha256=sha(p['elf']),binary_sha256=sha(p['binary']),spec_sha256=sha(p['spec'])) for p in fault_cases],
      execution_families=coverage,branch_outcomes=branch_coverage,tests=tests,
      formal=dict(status='PASS_CONTROL_SAFETY_INDUCTION',engine='Yosys SMTBMC/Bitwuzla, native memory arrays',properties=43,scope='control/handshake/commit, fences and LSU/MD issue/completion/error safety, NOT whole ISA arithmetic proof',
                  assumptions=['first common reset sampled low','defined binary inputs/state','aligned RESET_PC'],async_timing_modeled=False),
      rtl_negative_controls=controls,steps=STEPS,log_sha256={s['name']+'.log':sha(OUT/(s['name']+'.log')) for s in STEPS},
      rv64_coremark=None,fpga_deployed=False,limitations=['this suite does not qualify LSU/M arithmetic; use R05/R06/R07, no cache/AXI bursts/CSR/A/MMU/OS','fault-stop diagnostics only, no trap CSR/vector entry',
        'common core+responder reset only; no master-only warm reset','AXI4-Lite read-only subset, not full AXI4 fabric or complete RVFI',
        'no pipeline throughput/CoreMark/PPA/Fmax claim; RV32 not rerun'])
    emit(ROOT/'reports/RV64_R04_INTEGER_CORE.json',json.dumps(report,indent=2)+'\n')
    emit(OUT/'run-status.json',json.dumps(dict(status=report['status']))+'\n');print('R64_04_PASS',len(tests),'runs; RV32 execution disabled',flush=True)

if __name__=='__main__':
    try:main()
    except Exception as e:
        emit(OUT/'run-status.json',json.dumps(dict(status='FAIL',error=str(e)),indent=2)+'\n');raise
