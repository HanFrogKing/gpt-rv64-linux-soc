.option norvc
.option norelax
.text
.globl _start
_start:
  li sp,0x80220000
  call probe_main
1: j 1b
.balign 4
.globl probe_trap
probe_trap:
  addi sp,sp,-32
  sd t0,0(sp)
  sd t1,8(sp)
  csrr t0,scause
  li t1,0x8000000000000005
  bne t0,t1,2f
  li t0,32
  csrc sie,t0
  la t0,probe_timer_seen
  li t1,1
  sd t1,0(t0)
  ld t0,0(sp)
  ld t1,8(sp)
  addi sp,sp,32
  sret
2:
  la t0,probe_timer_seen
  li t1,2
  sd t1,0(t0)
  j 2b
