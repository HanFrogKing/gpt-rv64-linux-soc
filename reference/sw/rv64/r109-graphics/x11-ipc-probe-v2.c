#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static void require(int ok, const char *what)
{
 if (!ok) { fprintf(stderr,"R109_X11_IPC_FAIL %s errno=%d\n",what,errno); exit(1); }
}
static int transfer(int fd, void *buffer, size_t bytes, int writing)
{
 unsigned char *p=buffer;
 while (bytes) {
  ssize_t n=writing ? write(fd,p,bytes) : read(fd,p,bytes);
  if (n<0 && errno==EINTR) continue;
  if (n<=0) return 0;
  p+=n; bytes-=(size_t)n;
 }
 return 1;
}
int main(void)
{
 alarm(20);
 char directory[80],path[108];
 require(snprintf(directory,sizeof(directory),"/tmp/r109-ipc-%ld",(long)getpid())>0,"directory-name");
 require(mkdir(directory,0700)==0,"mkdir-private");
 require(snprintf(path,sizeof(path),"%s/x11.sock",directory)>0,"socket-name");
 int server=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
 require(server>=0,"unix-socket");
 struct sockaddr_un address={.sun_family=AF_UNIX};
 memcpy(address.sun_path,path,strlen(path)+1);
 require(bind(server,(struct sockaddr *)&address,sizeof(address))==0,"unix-path-bind");
 require(listen(server,1)==0,"unix-listen");
 int id=shmget(IPC_PRIVATE,4096,IPC_CREAT|0600);
 require(id>=0,"sysv-shmget");
 volatile uint32_t *shared=shmat(id,NULL,0);
 require(shared!=(void *)-1,"sysv-shmat");
 require(shmctl(id,IPC_RMID,NULL)==0,"sysv-auto-remove");
 shared[0]=0x109a55aa;
 pid_t child=fork(); require(child>=0,"fork");
 if (!child) {
  close(server);
  int fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
  if(fd<0 || connect(fd,(struct sockaddr *)&address,sizeof(address))) _exit(11);
  unsigned char data[256]; for(unsigned i=0;i<sizeof(data);i++)data[i]=(unsigned char)i;
  if(!transfer(fd,data,sizeof(data),1))_exit(12);
  char ack[4];if(!transfer(fd,ack,sizeof(ack),0)||memcmp(ack,"ACK!",4))_exit(13);
  if(shared[0]!=0x109a55aa)_exit(14);
  shared[1]=0x109c33cc;
  if(shmdt((const void *)shared))_exit(15);
  close(fd);_exit(0);
 }
 int fd=accept4(server,NULL,NULL,SOCK_CLOEXEC);require(fd>=0,"unix-accept");
 struct ucred peer={0};socklen_t size=sizeof(peer);
 require(getsockopt(fd,SOL_SOCKET,SO_PEERCRED,&peer,&size)==0 && size==sizeof(peer)
         && peer.pid==child && peer.uid==getuid(),"unix-peercred");
 unsigned char data[256];require(transfer(fd,data,sizeof(data),0),"unix-read");
 for(unsigned i=0;i<sizeof(data);i++)require(data[i]==(unsigned char)i,"unix-payload");
 char ack[4]={'A','C','K','!'};require(transfer(fd,ack,sizeof(ack),1),"unix-reply");
 close(fd);close(server);
 int status=0;require(waitpid(child,&status,0)==child && WIFEXITED(status) && !WEXITSTATUS(status),"child-status");
 require(shared[1]==0x109c33cc,"sysv-shared-visibility");
 require(shmdt((const void *)shared)==0,"sysv-parent-detach");
 require(unlink(path)==0,"socket-unlink");
 require(snprintf(path,sizeof(path),"%s/watch",directory)>0,"watch-name");
 fd=open(path,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);require(fd>=0,"watch-file");
 int notify=inotify_init1(IN_CLOEXEC|IN_NONBLOCK);require(notify>=0,"inotify-init");
 int watch=inotify_add_watch(notify,path,IN_MODIFY);require(watch>=0,"inotify-watch");
 require(write(fd,"X",1)==1,"watched-write");
 struct pollfd pollfd={.fd=notify,.events=POLLIN};
 require(poll(&pollfd,1,2000)==1 && (pollfd.revents&POLLIN),"inotify-poll");
 unsigned char events[512] __attribute__((aligned(8)));
 ssize_t n=read(notify,events,sizeof(events));require(n>=(ssize_t)sizeof(struct inotify_event),"inotify-read");
 struct inotify_event *event=(void *)events;
 require(event->wd==watch && (event->mask&IN_MODIFY),"inotify-event");
 require(inotify_rm_watch(notify,watch)==0,"inotify-remove");close(notify);close(fd);
 require(unlink(path)==0 && rmdir(directory)==0,"cleanup");
 alarm(0);
 puts("R109_X11_IPC_PASS unix_path=1 peercred=1 fork=1 shm=1 inotify=1 bytes=256");
 return 0;
}
