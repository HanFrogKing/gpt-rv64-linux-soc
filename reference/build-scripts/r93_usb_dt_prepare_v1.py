#!/usr/bin/env python3
"""Compile candidate DT only: actual board USB/PLIC mapping, never deploy it."""
from pathlib import Path
import json,os
import integer_core_check as c
R=c.ROOT;OUT=R/'build/rv64/r93-usb-dt-candidate-r1';c.OUT=OUT
def main():
 c.require(not OUT.exists(),'preserve previous DT');OUT.mkdir()
 base=R/'sw/rv64/r82-board-boot/board-hvc.dts';dts=base.read_text()
 dts=dts.replace('// No simulated 16550, syscon finisher, PLIC, USB, display or ARM CPU nodes.',
  '// R93 board candidate only: requires new PS USB0 IRQ/CDC hardware and PHY-enabled Image.\n// No simulator doorbells/selftest devices; not deployed or accepted as USB support.')
 anchor=' memory@80200000 {device_type="memory";reg=<0 0x80200000 0 0x07e00000>;};'
 c.require(dts.count(anchor)==1,'memory anchor')
 dts=dts.replace(anchor,anchor+'''
 reserved-memory {
  #address-cells=<2>;#size-cells=<2>;ranges;
  dma_pool: dma-pool@87000000 {compatible="shared-dma-pool";
   reg=<0 0x87000000 0 0x00800000>;no-map;linux,dma-default;};
 };
 // PHY refclock/reset currently supplied by pinned PS init and board hardware.
 // Physical ULPI ID responds; recovery after a cold reset is still to validate.
 usb_phy0: usb-phy {compatible="usb-nop-xceiv";#phy-cells=<0>;};''')
 anchor='  ranges;\n  clint@2000000 {';c.require(dts.count(anchor)==1,'soc anchor')
 dts=dts.replace(anchor,'''  ranges;
  dma-noncoherent;
  dma-ranges=<0 0x00200000 0 0x80200000 0 0x07e00000>;
  dma-cache@3000000 {compatible="rv64lab,dma-cache-control-v1";reg=<0 0x03000000 0 0x1000>;};
  plic: interrupt-controller@c000000 {
   compatible="sifive,plic-1.0.0";reg=<0 0x0c000000 0 0x00400000>;
   #interrupt-cells=<1>;#address-cells=<0>;interrupt-controller;riscv,ndev=<31>;
   interrupts-extended=<&cpu_intc 11 &cpu_intc 9>;
  };
  usb@e0002000 {
   compatible="xlnx,zynq-usb-2.20a";reg=<0 0xe0002000 0 0x1000>;
   interrupt-parent=<&plic>;interrupts=<1>;
   dr_mode="host";phy_type="ulpi";phys=<&usb_phy0>;status="okay";
  };
  clint@2000000 {''')
 c.require('simulation-only' not in dts and 'e0002ffc' not in dts,'simulation device in board DT')
 c.emit(OUT/'board-usb.dts',dts);(OUT/'boot-seed.bin').write_bytes(os.urandom(64))
 c.run('dtc',['dtc','-I','dts','-O','dtb','-i',OUT,'-o',OUT/'board-usb.dtb',OUT/'board-usb.dts'],timeout=30)
 c.run('decompile',['dtc','-I','dtb','-O','dts','-o',OUT/'board-usb-roundtrip.dts',OUT/'board-usb.dtb'],timeout=30)
 expected=[('/soc/usb@e0002000','interrupts','1'),('/soc/usb@e0002000','reg','0 e0002000 0 1000'),
  ('/soc','dma-ranges','0 200000 0 80200000 0 7e00000'),
  ('/soc/interrupt-controller@c000000','riscv,ndev','1f'),
  ('/reserved-memory/dma-pool@87000000','reg','0 87000000 0 800000')]
 for i,(node,prop,value) in enumerate(expected):
  log=c.run('check-cell-'+str(i),['fdtget','-t','x',OUT/'board-usb.dtb',node,prop],timeout=30)
  c.require(log.strip()==value,'bad DT cell '+prop)
 for prop,value in [('compatible','xlnx,zynq-usb-2.20a'),('dr_mode','host'),('phy_type','ulpi')]:
  log=c.run('check-'+prop,['fdtget','-t','s',OUT/'board-usb.dtb','/soc/usb@e0002000',prop],timeout=30);c.require(log.strip()==value,'bad DT '+prop)
 pins={str(p.relative_to(R)):c.sha(p) for p in [Path(__file__),base,OUT/'board-usb.dts',OUT/'board-usb.dtb',OUT/'boot-seed.bin']}
 c.emit(OUT/'run-status.json',json.dumps(dict(status='PREPARED_BOARD_USB_DT_CANDIDATE_NOT_DEPLOYED',source_input_sha256=pins,
  steps=c.STEPS,dt_schema_validated=False,matching_board_hardware=False,matching_full_kernel_image=False,usb_enumerated=False,disk_accessed=False,
  scope='DTC and semantic cell checks only. Requires PS IRQ/CDC/new portable system/PHY-enabled full kernel and actual binding. Seed is preparation-only; regenerate for actual boots. Not USB/board functional acceptance.'),indent=2)+'\n')
 print('PREPARED_BOARD_USB_DT_CANDIDATE_NOT_DEPLOYED',flush=True)
if __name__=='__main__':main()
