#include "../Bridge.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <time.h>
static char launcher[4096];
static void reply(void *context,const uint8_t *bytes,size_t count){int fd=*(int *)context;while(count){ssize_t n=write(fd,bytes,count);if(n>0){bytes+=n;count-=n;}else if(errno!=EINTR){assert(errno==EAGAIN);struct pollfd p={fd,POLLOUT,0};assert(poll(&p,1,1000)>0);}}}
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void run(const char *executable,const char *cwd,const char *script,int expected_error,const char *expected_text){
    char *argv[]={(char *)executable,"-c",(char *)script,NULL};
    TerminalProcess p=terminal_spawn_args(launcher,executable,cwd,123,37,argv);assert(p.error==0);
    Terminal *core=terminal_create(123,37);assert(core);
    char output[300000];size_t used=0;unsigned char status[16];size_t status_used=0;int eof=0,status_eof=0,reaped=0,outcome=0;
    double deadline=now()+10;
    while((!eof||!status_eof||!reaped)&&now()<deadline){
        struct pollfd fds[2]={{p.master,POLLIN,0},{p.status,POLLIN,0}};poll(fds,2,20);
        if(!eof){ssize_t n=read(p.master,output+used,sizeof(output)-used-1);if(n>0){size_t parsed=0;while(parsed<(size_t)n||terminal_has_work(core)){parsed+=terminal_feed(core,(const uint8_t *)output+used+parsed,(size_t)n-parsed,0);terminal_replies(core,&p.master,reply);}assert(terminal_validate(core));used+=n;}else if(n==0||(n<0&&errno==EIO))eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!status_eof){ssize_t n=read(p.status,status+status_used,sizeof(status)-status_used);if(n>0)status_used+=n;else if(n==0)status_eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!reaped){int result=waitpid(p.pid,&outcome,WNOHANG);assert(result>=0);if(result==p.pid)reaped=1;}
    }
    assert(eof&&status_eof&&reaped);output[used]=0;close(p.master);close(p.status);
    if(expected_error){assert(status_used==8);int error;memcpy(&error,status+4,4);assert(error==expected_error);}
    else{assert(status_used==0);if(!WIFEXITED(outcome)||WEXITSTATUS(outcome)!=0)fprintf(stderr,"child failed (%d): %s\n",outcome,output);assert(WIFEXITED(outcome)&&WEXITSTATUS(outcome)==0);assert(strstr(output,expected_text));}
    terminal_finish(core);assert(terminal_validate(core));
    if(!expected_error){TerminalSearch *search=terminal_search_create(core,(const uint8_t *)expected_text,strlen(expected_text));assert(search);uint32_t phase;while((phase=terminal_search_fill(core,search))==0||phase==1){terminal_search_step(search);}assert(phase==2);assert(terminal_search_accept(core,search)==5);terminal_search_destroy(search);}
    terminal_destroy(core);
    printf("PASS PTY: %s (%zu bytes, child reaped, final output drained)\n",expected_text,used);
}
int main(int argc,char **argv){assert(argc==2);snprintf(launcher,sizeof launcher,"%s",argv[1]);
    run("/bin/sh","/tmp","printf 'cwd=';pwd; stty size;test -t 0 && test -t 1 && test -t 2; printf 'CONTROLLING=';ps -o tpgid= -p $$;printf 'DONE'",0,"37 123");
    run("/bin/sh","/tmp","i=0;while [ $i -lt 20000 ];do printf 'final-burst-';i=$((i+1));done;printf 'FINAL_SENTINEL'",0,"FINAL_SENTINEL");
    run("/does-not-exist","/tmp","",ENOENT,"exec failure");
    run("/bin/sh","/does-not-exist","",ENOENT,"cwd failure");
    run("/bin/sh","/tmp","test \"$TERM\" = xterm-256color; test -z \"${VK_DRIVER_FILES+x}\";printf 'ENV_OK'",0,"ENV_OK");
    run("/bin/sh","/tmp","/bin/bash --noprofile --norc -i -c 'printf BASH_CORPUS_OK'",0,"BASH_CORPUS_OK");
    run("/bin/sh","/tmp","fish --no-config -c 'printf FISH_CORPUS_OK'",0,"FISH_CORPUS_OK");
    run("/bin/sh","/tmp","nvim --clean -n -u NONE -c 'call setline(1, \"猫 NVIM corpus\")' -c redraw -c 'qa!' && printf NVIM_CORPUS_OK",0,"NVIM_CORPUS_OK");
    run("/bin/sh","/tmp","tmux -L terminal-smoke-$$ -f /dev/null new-session 'printf TMUX_CORPUS; sleep 0.2'; printf TMUX_CORPUS_OK",0,"TMUX_CORPUS_OK");
    run("/bin/sh","/tmp","printf 'one\ntwo\n' | fzf --bind 'load:accept' && printf FZF_CORPUS_OK",0,"FZF_CORPUS_OK");
    return 0;

}
