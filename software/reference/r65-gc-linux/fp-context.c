#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <time.h>
#include <errno.h>
extern void fp_fill(uint64_t,unsigned);
extern unsigned fp_check(uint64_t,unsigned);
static volatile sig_atomic_t signals,timers;
static void handler(int signo){
 fp_fill(UINT64_C(0x7ff8000055aa0000),0x9f);
 signals++;if(signo==SIGALRM)timers++;
}
static int test(uint64_t seed,unsigned fcsr){
 struct itimerval it={{0,20000},{0,20000}};
 if(setitimer(ITIMER_REAL,&it,0))return 10;
 fp_fill(seed,fcsr);
 for(int n=0;n<16;n++){
  if(fp_check(seed,fcsr))return 11;
  if(kill(getpid(),SIGUSR1))return 12;
  if(fp_check(seed,fcsr))return 13;
  if(nanosleep(&(struct timespec){0,1000000},0)&&errno!=EINTR)return 14;
  if(fp_check(seed,fcsr))return 15;
 }
 struct timespec left={0,70000000};
 while(nanosleep(&left,&left)&&errno==EINTR)if(fp_check(seed,fcsr))return 16;
 if(fp_check(seed,fcsr)||timers==0)return 17;
 memset(&it,0,sizeof it);if(setitimer(ITIMER_REAL,&it,0))return 18;
 if(fp_check(seed,fcsr))return 19;
 return 0;
}
int main(void){
 struct sigaction sa;memset(&sa,0,sizeof sa);sa.sa_handler=handler;sigemptyset(&sa.sa_mask);
 if(sigaction(SIGUSR1,&sa,0)||sigaction(SIGALRM,&sa,0))return 1;
 const uint64_t inherited=UINT64_C(0x1234000000000100);
 fp_fill(inherited,0x55);
 pid_t p=fork();if(p<0)return 2;
 if(fp_check(inherited,0x55))return 3;
 if(p==0){int r=test(UINT64_C(0xa5a5000000000200),0x7b);_exit(r);}
 int r=test(UINT64_C(0x5a5a000000000300),0x96),status=0;
 if(r){printf("FP_CONTEXT_FAIL parent=%d\n",r);return r;}
 if(waitpid(p,&status,0)!=p||!WIFEXITED(status)||WEXITSTATUS(status)){
  printf("FP_CONTEXT_FAIL child_status=%x\n",status);return 20;
 }
 if(fp_check(UINT64_C(0x5a5a000000000300),0x96))return 21;
 printf("LINUX_FP_CONTEXT_PASS fork=1 all_fpr=32 fcsr=1 signal_restore=%d timer_signals=%d\n",signals,timers);
 return 0;
}
