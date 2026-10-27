.option norvc
.option norelax
.text
.globl _start
_start:
  csrr a0,mhartid
  la t0,boot_arguments
  ld a1,0(t0)
  ld t0,8(t0)
  jr t0
.balign 8
boot_arguments:
  .dword 0x87e00000
  .dword 0x80000000
