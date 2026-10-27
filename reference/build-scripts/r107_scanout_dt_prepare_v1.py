#!/usr/bin/env python3
"""Compile separate physical and explicitly simulator-only DT candidates."""
import json,os
from pathlib import Path
import integer_core_check as c
R=c.ROOT;OUT=R/'build/rv64/r107-scanout-dt-r1';c.OUT=OUT

def main():
 c.require(not OUT.exists(),'preserve DT attempt');OUT.mkdir()
 bases={'physical':R/'build/rv64/r93-usb-dt-candidate-r1/board-usb.dts',
        'simulation-only':R/'build/rv64/r105-video-linux-r1/normal/simulation-only-dma.dts'}
 pins={str(Path(__file__).relative_to(R)):c.sha(__file__)};artifacts={}
 for mode,base in bases.items():
  out=OUT/mode;out.mkdir();dts=base.read_text()
  anchor='  clint@2000000 {';c.require(dts.count(anchor)==1,'DT anchor '+mode)
  dts=dts.replace(anchor,'  scanout@4000000 {compatible="rv64lab,scanout-probe-v1";reg=<0 0x04000000 0 0x60>;status="okay";};\n'+anchor)
  if mode=='physical':
   c.require('simulation-only' not in dts and 'e0002ffc' not in dts and '877ff000' not in dts,'no model devices on physical')
  else:
   c.require('simulation-only-dma-selftest' in dts and 'simulation-only-plic-selftest' in dts,'model selftests retained')
  c.emit(out/'scanout.dts',dts);(out/'boot-seed.bin').write_bytes(os.urandom(64))
  c.run(mode+'-dtc',['dtc','-I','dts','-O','dtb','-i',out,'-o',out/'scanout.dtb',out/'scanout.dts'])
  c.run(mode+'-roundtrip',['dtc','-I','dtb','-O','dts','-o',out/'roundtrip.dts',out/'scanout.dtb'])
  for i,(node,prop,value) in enumerate([('/soc/scanout@4000000','reg','0 4000000 0 60'),('/soc','dma-ranges','0 200000 0 80200000 0 7e00000'),('/reserved-memory/dma-pool@87000000','reg','0 87000000 0 '+('800000' if mode=='physical' else '7ff000'))]):
   log=c.run(mode+'-cells'+str(i),['fdtget','-t','x',out/'scanout.dtb',node,prop]);c.require(log.strip()==value,'DT cell mismatch')
  log=c.run(mode+'-compatible',['fdtget','-t','s',out/'scanout.dtb','/soc/scanout@4000000','compatible']);c.require(log.strip()=='rv64lab,scanout-probe-v1','driver binding')
  if mode=='physical':
   log=c.run('physical-usb',['fdtget','-t','x',out/'scanout.dtb','/soc/usb@e0002000','interrupts']);c.require(log.strip()=='1','USB IRQ retained')
  pins[str(base.relative_to(R))]=c.sha(base)
  for p in [out/'scanout.dts',out/'scanout.dtb',out/'boot-seed.bin']:
   artifacts[str(p.relative_to(OUT))]=dict(bytes=p.stat().st_size,sha256=c.sha(p))
 c.emit(OUT/'run-status.json',json.dumps(dict(status='PREPARED_R107_SEPARATE_PHYSICAL_AND_SIMULATION_DT_NOT_BOOTED',source_sha256=pins,artifacts=artifacts,steps=c.STEPS,scope='DTC/semantic cells only, no dt-schema validation. Physical USB node retained, no simulator mailbox. DMA pool shared, no fixed framebuffer reservation. Preparation entropy only: regenerate fresh per actual boot. No physical deployment or Linux binding acceptance.'),indent=2)+'\n');print('PREPARED_R107_SEPARATE_PHYSICAL_AND_SIMULATION_DT_NOT_BOOTED',flush=True)
if __name__=='__main__':main()
