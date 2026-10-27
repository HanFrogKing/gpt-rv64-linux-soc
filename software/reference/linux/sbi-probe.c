#include <stdint.h>
volatile uint64_t probe_timer_seen;
extern void probe_trap(void);
struct result {long error,value;};
static struct result sbi(long extension,long function,unsigned long arg0,unsigned long arg1) {
    register unsigned long a0 __asm__("a0")=arg0,a1 __asm__("a1")=arg1;
    register unsigned long a6 __asm__("a6")=(unsigned long)function,a7 __asm__("a7")=(unsigned long)extension;
    __asm__ volatile("ecall":"+r"(a0),"+r"(a1):"r"(a6),"r"(a7):"memory");
    return (struct result){(long)a0,(long)a1};
}
static void puts_uart(const char *s) {
    volatile unsigned char *uart=(volatile unsigned char *)0x10000000;
    while(*s){while(!(uart[5]&32)){}uart[0]=(unsigned char)*s++;}
}
static void finish(int pass) {
    puts_uart(pass?"SBI_PROBE_PASS\n":"SBI_PROBE_FAIL\n");
    sbi(0x53525354,0,0,pass?0:1);
    for(;;)__asm__ volatile("wfi");
}
void probe_main(unsigned long hart,unsigned long dtb) {
    if(hart || dtb!=0x87e00000 || *(const uint32_t *)dtb!=0xedfe0dd0)finish(0);
    puts_uart("SBI_PROBE_ENTRY_PASS\n");
    struct result r=sbi(0x10,0,0,0);
    if(r.error || !r.value)finish(0);
    r=sbi(0x10,3,0x54494d45,0);if(r.error || !r.value)finish(0);
    puts_uart("SBI_PROBE_BASE_TIME_PASS\n");
    __asm__ volatile("csrw stvec,%0"::"r"(probe_trap):"memory");
    unsigned long ticks;
    __asm__ volatile("rdtime %0":"=r"(ticks));
    __asm__ volatile("csrs sie,%0\ncsrs sstatus,%1"::"r"(32UL),"r"(2UL):"memory");
    r=sbi(0x54494d45,0,ticks+1000,0);if(r.error)finish(0);
    for(unsigned long n=0;n<1000000 && !probe_timer_seen;n++)__asm__ volatile("nop");
    if(probe_timer_seen!=1)finish(0);
    r=sbi(0x54494d45,0,~0UL,0);if(r.error)finish(0);
    puts_uart("SBI_PROBE_TIMER_INTERRUPT_PASS\n");
    finish(1);
}
