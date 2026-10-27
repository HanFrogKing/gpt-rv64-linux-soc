/*
 * SPDX-License-Identifier: BSD-2-Clause
 * Copyright (c) 2022 StarFive Technology Co., Ltd.
 * Author: Jun Liang Tan <junliang.tan@linux.starfivetech.com>
 *
 * Project derivative of pinned OpenSBI 1.6 cadence-uart.c. R75 selects both
 * Zynq CD and BDIV within documented limits; original source stays untouched.
 */
#include <sbi/sbi_domain.h>
#include <sbi/sbi_error.h>
#include <sbi/riscv_asm.h>
#include <sbi/riscv_io.h>
#include <sbi/sbi_console.h>
#include <sbi_utils/serial/cadence-uart.h>

#define UART_REG_CTRL 0x00
#define UART_REG_MODE 0x04
#define UART_REG_IDR 0x0C
#define UART_REG_BRGR 0x18
#define UART_REG_CSR 0x2C
#define UART_REG_RFIFO_TFIFO 0x30
#define UART_REG_BDIVR 0x34
#define UART_CTRL_RXRES 0x00000001
#define UART_CTRL_TXRES 0x00000002
#define UART_CTRL_RXEN 0x00000004
#define UART_CTRL_RXDIS 0x00000008
#define UART_CTRL_TXEN 0x00000010
#define UART_CTRL_TXDIS 0x00000020
#define UART_MODE_PAR_NONE 0x00000020
#define UART_CSR_REMPTY 0x00000002
#define UART_CSR_TFUL 0x00000010

static volatile void *uart_base;
static u32 uart_in_freq;
static u32 uart_baudrate;

// Integer-only search, no FPU requirement in M-mode. Rounded actual baud error
// is minimized, ties favor more samples. Reject >3% error before touching MMIO.
// Bounds: CD 1..65535, BDIV 4..255 (UG585 Baud Rate Generator).
static int uart_baud_divisors(u32 freq, u32 baud, u32 *cd_out, u32 *bdiv_out)
{
 u32 cd_best=0,bdiv_best=0,best_error=~(u32)0;
 for(u32 bdiv=4;bdiv<=255;++bdiv){
  uint64_t target=(uint64_t)baud*(bdiv+1);
  uint64_t floor_cd=(uint64_t)freq/target;
  for(u32 side=0;side<2;++side){
   uint64_t cd=floor_cd+side;
   if(cd<1)cd=1;
   if(cd>65535)cd=65535;
   uint64_t denominator=cd*(bdiv+1);
   u32 actual=((uint64_t)freq+denominator/2)/denominator;
   u32 error=actual>baud?actual-baud:baud-actual;
   if(error<=best_error){cd_best=cd;bdiv_best=bdiv;best_error=error;}
  }
 }
 if((uint64_t)best_error*100>(uint64_t)baud*3)return SBI_EINVAL;
 *cd_out=cd_best;*bdiv_out=bdiv_best;return 0;
}
static u32 get_reg(u32 offset){return readl(uart_base+offset);}
static void set_reg(u32 offset,u32 value){writel(value,uart_base+offset);}
static void cadence_uart_putc(char ch)
{
 while(get_reg(UART_REG_CSR)&UART_CSR_TFUL);
 set_reg(UART_REG_RFIFO_TFIFO,ch);
}
static int cadence_uart_getc(void)
{
 if(!(get_reg(UART_REG_CSR)&UART_CSR_REMPTY))return get_reg(UART_REG_RFIFO_TFIFO);
 return -1;
}
static struct sbi_console_device cadence_console={
 .name="cadence_uart",.console_putc=cadence_uart_putc,.console_getc=cadence_uart_getc
};
int cadence_uart_init(unsigned long base,u32 in_freq,u32 baudrate)
{
 u32 cd=0,bdiv=0;
 if(in_freq&&baudrate){
  int rc=uart_baud_divisors(in_freq,baudrate,&cd,&bdiv);
  if(rc)return rc;
 }
 uart_base=(volatile void *)base;uart_in_freq=in_freq;uart_baudrate=baudrate;
 set_reg(UART_REG_IDR,0xffffffff);
 set_reg(UART_REG_CTRL,UART_CTRL_TXDIS|UART_CTRL_RXDIS);
 if(uart_in_freq&&uart_baudrate){set_reg(UART_REG_BRGR,cd);set_reg(UART_REG_BDIVR,bdiv);}
 set_reg(UART_REG_CTRL,UART_CTRL_TXRES|UART_CTRL_RXRES|UART_CTRL_TXEN|UART_CTRL_RXEN);
 set_reg(UART_REG_MODE,UART_MODE_PAR_NONE);
 sbi_console_set_device(&cadence_console);
 return sbi_domain_root_add_memrange(base,PAGE_SIZE,PAGE_SIZE,
  SBI_DOMAIN_MEMREGION_MMIO|SBI_DOMAIN_MEMREGION_SHARED_SURW_MRW);
}
