#!/usr/bin/env python3
"""Separate opt-in DRM DT inputs. Never deploy simulation selftest devices."""
import json,os
from pathlib import Path
import integer_core_check as c
R=c.ROOT;OUT=R/'build/rv64/r108-drm-dt-r1';c.OUT=OUT
def main():
 c.require(not OUT.exists(),'preserve DT candidate');OUT.mkdir()
 base=R/'build/rv64/r107-scanout-dt-r1';bj=json.loads((base/'run-status.json').read_text())
 for n,a in bj['artifacts'].items():c.require(c.sha(base/n)==a['sha256'],'parent DT changed '+n)
 pins={str(Path(__file__).relative_to(R)):c.sha(__file__),str((base/'run-status.json').relative_to(R)):c.sha(base/'run-status.json')};arts={}
 for mode in ['physical','simulation-only']:
  p=base/mode/'scanout.dts';text=p.read_text();c.require(text.count('rv64lab,scanout-probe-v1')==1,'binding anchor')
  out=OUT/mode;out.mkdir();c.emit(out/'scanout.dts',text.replace('rv64lab,scanout-probe-v1','rv64lab,scanout-drm-shadow-v1'));(out/'boot-seed.bin').write_bytes(os.urandom(64))
  c.run(mode+'-dtc',['dtc','-I','dts','-O','dtb','-i',out,'-o',out/'scanout.dtb',out/'scanout.dts'],timeout=30)
  for i,(node,prop,value) in enumerate([('/soc/scanout@4000000','compatible','rv64lab,scanout-drm-shadow-v1'),('/soc','dma-ranges','0 200000 0 80200000 0 7e00000')]):
   got=c.run(mode+'-semantic-'+str(i),['fdtget','-t','s' if prop=='compatible' else 'x',out/'scanout.dtb',node,prop]);c.require(got.strip()==value,'DT semantics')
  if mode=='physical':
   c.require(all(s not in text for s in ['simulation-only','e0002ffc','dma-agent@877ff000']),'no model mailbox on physical DT')
  else:c.require('simulation-only-dma-selftest' in text and 'simulation-only-plic-selftest' in text,'retain actual Linux model DMA/IRQ checks')
  pins[str(p.relative_to(R))]=c.sha(p)
  for p in [out/'scanout.dts',out/'scanout.dtb',out/'boot-seed.bin']:arts[str(p.relative_to(OUT))]=dict(bytes=p.stat().st_size,sha256=c.sha(p))
 c.emit(OUT/'run-status.json',json.dumps(dict(status='PREPARED_R108_OPTIN_DRM_DT_NOT_BOOTED',source_sha256=pins,artifacts=arts,steps=c.STEPS,board_deployed=False,scope='DTC/semantic checks only; no DT schema/runtime binding acceptance. Current DMA ranges/USB retained; fresh entropy still required for each actual boot.'),indent=2)+'\n')
 print('PREPARED_R108_OPTIN_DRM_DT_NOT_BOOTED',flush=True)
if __name__=='__main__':main()
