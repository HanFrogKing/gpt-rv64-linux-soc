#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <termios.h>
#include <unistd.h>

static void check(int ok, const char *name) {
    if (!ok) { printf("LINUX_SELFTEST_FAIL %s errno=%d\n", name, errno); exit(1); }
    printf("LINUX_SELFTEST_OK %s\n", name);
}
static volatile sig_atomic_t alarm_seen;
static void on_alarm(int number) { (void)number; alarm_seen=1; }
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    check(getpid()>1 && getuid()==0, "syscall-getpid-identity");
    check(isatty(0) && tcgetpgrp(0)>0,"controlling-terminal");
    const size_t size=128*1024;
    volatile unsigned char *memory=mmap(NULL,size,PROT_READ|PROT_WRITE,
        MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    check(memory!=MAP_FAILED,"anonymous-mmap");
    for (size_t i=0;i<size;i++) memory[i]=(unsigned char)(i*37u+11u);
    int valid=1;
    for (size_t i=0;i<size;i++) if (memory[i]!=(unsigned char)(i*37u+11u)) valid=0;
    check(valid,"page-backed-memory-read-write");
    volatile uint64_t atom=17;
    uint64_t expected=17;
    check(__atomic_compare_exchange_n(&atom,&expected,29,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)
        && __atomic_fetch_add(&atom,3,__ATOMIC_SEQ_CST)==29 && atom==32,"rv64a-userspace");
    pid_t pid=fork();
    check(pid>=0,"fork");
    if (!pid) { memory[0]=99; _exit(23); }
    int status=0;
    check(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==23,"wait-child");
    check(memory[0]==11,"copy-on-write-isolation");
    pid=fork(); check(pid>=0,"fork-page-fault");
    if (!pid) { volatile unsigned char *bad=mmap(NULL,4096,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
        if (bad==MAP_FAILED) _exit(2);
        *bad=1;
        _exit(3);
    }
    check(waitpid(pid,&status,0)==pid && WIFSIGNALED(status) && WTERMSIG(status)==SIGSEGV,"user-page-fault-isolation");
    pid=fork(); check(pid>=0,"fork-illegal-instruction");
    if (!pid) { __asm__ volatile(".word 0xffffffff"); _exit(4); }
    check(waitpid(pid,&status,0)==pid && WIFSIGNALED(status) && WTERMSIG(status)==SIGILL,"user-illegal-instruction-isolation");
    struct timespec before,after,delay={0,20000000};
    check(clock_gettime(CLOCK_MONOTONIC,&before)==0,"monotonic-clock");
    check(nanosleep(&delay,NULL)==0 && clock_gettime(CLOCK_MONOTONIC,&after)==0 &&
        (after.tv_sec>before.tv_sec || (after.tv_sec==before.tv_sec && after.tv_nsec>before.tv_nsec)),"timer-sleep");
    check(signal(SIGALRM,on_alarm)!=SIG_ERR,"signal-handler");
    alarm(1);
    while (!alarm_seen) pause();
    check(alarm_seen,"timer-signal-delivery");
    volatile unsigned *shared=mmap(NULL,4096,PROT_READ|PROT_WRITE,
        MAP_SHARED|MAP_ANONYMOUS,-1,0);
    check(shared!=MAP_FAILED,"scheduler-shared-mmap");
    pid=fork();check(pid>=0,"fork-preemption");
    if (!pid) {
        struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);time_t limit=now.tv_sec+3;
        shared[0]=1;
        while (!shared[1]) { clock_gettime(CLOCK_MONOTONIC,&now);if(now.tv_sec>=limit)_exit(7); }
        shared[2]=1;_exit(0);
    }
    struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);time_t limit=now.tv_sec+3;
    while (!shared[0]) { clock_gettime(CLOCK_MONOTONIC,&now);if(now.tv_sec>=limit)check(0,"preemption-deadline"); }
    shared[1]=1;
    check(waitpid(pid,&status,0)==pid && WIFEXITED(status) && WEXITSTATUS(status)==0 && shared[2],"timer-preemption-two-processes");
    check(munmap((void *)shared,4096)==0,"scheduler-shared-reclaim");
    int fd=open("/tmp/rv64-test",O_CREAT|O_RDWR|O_TRUNC,0600);
    char buffer[8]={0};
    check(fd>=0 && write(fd,"RAMFS",5)==5 && lseek(fd,0,SEEK_SET)==0 &&
        read(fd,buffer,5)==5 && !memcmp(buffer,"RAMFS",5),"filesystem-io");
    check(close(fd)==0 && unlink("/tmp/rv64-test")==0,"filesystem-cleanup");
    check(munmap((void *)memory,size)==0,"memory-reclaim");
    puts("RV64_LINUX_SELFTEST_PASS");
    /* init can close/reopen ttyS0 immediately after rcS returns. Drain the
       acceptance line before that close can flush queued serial output. */
    if (tcdrain(STDOUT_FILENO)!=0) { perror("LINUX_SELFTEST_FAIL tcdrain");return 1; }
    return 0;
}
