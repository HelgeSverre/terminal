#include "Bridge.h"
#include <util.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
extern char **environ;
TerminalProcess terminal_spawn_args(const char *launcher,const char *executable,const char *cwd,uint16_t cols,uint16_t rows,char *const target_argv[]){
    TerminalProcess out={-1,-1,-1,0};int master=-1,slave=-1,p[2]={-1,-1};
    struct winsize size={.ws_row=rows,.ws_col=cols};
    if(openpty(&master,&slave,NULL,NULL,&size)<0){out.error=errno;return out;}
    if(pipe(p)<0){out.error=errno;goto cleanup;}
    // Move inherited sources above fixed destination descriptors before dup actions.
    int high_slave=fcntl(slave,F_DUPFD_CLOEXEC,10);int high_status=fcntl(p[1],F_DUPFD_CLOEXEC,10);
    if(high_slave<0||high_status<0){out.error=errno;if(high_slave>=0)close(high_slave);if(high_status>=0)close(high_status);goto cleanup;}
    posix_spawn_file_actions_t actions;posix_spawnattr_t attr;
    int error=posix_spawn_file_actions_init(&actions);if(error){out.error=error;close(high_slave);close(high_status);goto cleanup;}
    error=posix_spawnattr_init(&attr);if(error){out.error=error;posix_spawn_file_actions_destroy(&actions);close(high_slave);close(high_status);goto cleanup;}
    error=posix_spawn_file_actions_adddup2(&actions,high_slave,3);
    if(!error)error=posix_spawn_file_actions_adddup2(&actions,high_status,4);
    if(!error)error=posix_spawnattr_setflags(&attr,POSIX_SPAWN_CLOEXEC_DEFAULT);
    size_t argc=0;while(argc<4096 && target_argv[argc])argc++;if(argc==4096)error=E2BIG;
    char **argv=calloc(argc+4,sizeof(char *));
    if(!argv){error=ENOMEM;}else{argv[0]=(char *)launcher;argv[1]=(char *)cwd;argv[2]=(char *)executable;for(size_t i=0;i<argc;i++)argv[i+3]=target_argv[i];}
    // Private graphics configuration is not inherited by the shell.
    size_t count=0;while(environ[count])count++;
    char **env=calloc(count+4,sizeof(char *));
    if(!env){error=ENOMEM;}else{
        size_t n=0;for(size_t i=0;i<count;i++){if(strncmp(environ[i],"VK_",3)&&strncmp(environ[i],"TERM=",5)&&strncmp(environ[i],"COLORTERM=",10)&&strncmp(environ[i],"TERM_PROGRAM=",13))env[n++]=environ[i];}
        env[n++]="TERM=xterm-256color";env[n++]="COLORTERM=truecolor";env[n++]="TERM_PROGRAM=HelgeTerminal";
        if(!error)error=posix_spawn(&out.pid,launcher,&actions,&attr,argv,env);free(env);
    }
    posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);close(high_slave);close(high_status);free(argv);
    if(error){out.error=error;out.pid=-1;goto cleanup;}
    fcntl(master,F_SETFD,FD_CLOEXEC);fcntl(master,F_SETFL,fcntl(master,F_GETFL)|O_NONBLOCK);
    fcntl(p[0],F_SETFD,FD_CLOEXEC);fcntl(p[0],F_SETFL,fcntl(p[0],F_GETFL)|O_NONBLOCK);
    out.master=master;master=-1;out.status=p[0];p[0]=-1;
cleanup:
    if(master>=0)close(master);if(slave>=0)close(slave);if(p[0]>=0)close(p[0]);if(p[1]>=0)close(p[1]);return out;
}

TerminalProcess terminal_spawn(const char *launcher,const char *executable,const char *cwd,uint16_t cols,uint16_t rows){char *argv[]={(char *)executable,"-l",NULL};return terminal_spawn_args(launcher,executable,cwd,cols,rows,argv);}
