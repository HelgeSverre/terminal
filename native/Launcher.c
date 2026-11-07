#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <stdint.h>
struct Failure {int32_t stage;int32_t error;};
static void fail(int fd,int stage){struct Failure f={stage,errno};const char *p=(const char *)&f;size_t n=sizeof f;while(n){ssize_t w=write(fd,p,n);if(w>0){p+=w;n-=w;}else if(errno!=EINTR){break;}}_exit(127);}
int main(int argc,char **argv){
    if(argc<4)return 126;
    const int status=4;
    if(fcntl(status,F_SETFD,FD_CLOEXEC)<0)fail(status,1);
    if(login_tty(3)<0)fail(status,2);
    if(chdir(argv[1])<0)fail(status,3);
    sigset_t mask;sigemptyset(&mask);if(sigprocmask(SIG_SETMASK,&mask,NULL)<0)fail(status,4);
    for(int s=1;s<NSIG;s++){if(s!=SIGKILL && s!=SIGSTOP)signal(s,SIG_DFL);}
    execv(argv[2],&argv[3]);fail(status,5);
}
