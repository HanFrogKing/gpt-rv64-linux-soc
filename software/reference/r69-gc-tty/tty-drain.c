#include <unistd.h>
#include <termios.h>
#include <errno.h>
static int drain(void){int r;do{r=tcdrain(STDOUT_FILENO);}while(r<0&&errno==EINTR);return r;}
int main(void){
 alarm(30);
 if(!isatty(STDOUT_FILENO)||drain())return 1;
 const char text[]="RV64_TTY_DRAIN_PASS\n";unsigned done=0;
 while(done<sizeof text-1){ssize_t n=write(STDOUT_FILENO,text+done,sizeof text-1-done);
  if(n<0&&errno==EINTR)continue;
  if(n<=0)return 2;
  done+=(unsigned)n;
 }
 return drain()?3:0;
}
