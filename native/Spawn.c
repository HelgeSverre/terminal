#include "Bridge.h"
#include <util.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <stdio.h>
#include <limits.h>
extern char **environ;
typedef struct { char **values; char *directory; char *original; } SpawnEnvironment;
static void destroy_environment(SpawnEnvironment *env){free(env->values);free(env->directory);free(env->original);}
// Only normal interactive zsh launches are wrapped. Explicit commands keep
// their original startup semantics. The signed bundle owns the integration.
static int make_environment(const char *launcher,const char *executable,char *const argv[],size_t argc,SpawnEnvironment *out){
    size_t count=0;while(environ[count])count++;
    out->values=calloc(count+8,sizeof(char *));if(!out->values)return ENOMEM;
    const char *name=strrchr(executable,'/');name=name?name+1:executable;
    const char *parent=strrchr(launcher,'/');
    int wrap=!strcmp(name,"zsh")&&(argc==1||(argc==2&&!strcmp(argv[1],"-l")))&&parent;
    char shim[PATH_MAX],entry[PATH_MAX];
    if(wrap){
        int len=snprintf(shim,sizeof(shim),"%.*s/../Resources/ShellIntegration/zsh",(int)(parent-launcher),launcher);
        int length=snprintf(entry,sizeof(entry),"%s/.zshenv",shim);
        wrap=len>0&&(size_t)len<sizeof(shim)&&length>0&&(size_t)length<sizeof(entry)&&access(entry,R_OK)==0;
    }
    size_t n=0;
    for(size_t i=0;i<count;i++){
        const char *value=environ[i];
        if(!strncmp(value,"VK_",3)||!strncmp(value,"TERM=",5)||!strncmp(value,"COLORTERM=",10)||!strncmp(value,"TERM_PROGRAM=",13))continue;
        if(wrap&&(!strncmp(value,"ZDOTDIR=",8)||!strncmp(value,"HELGE_TERMINAL_",15)))continue;
        out->values[n++]=environ[i];
    }
    out->values[n++]="TERM=xterm-256color";out->values[n++]="COLORTERM=truecolor";out->values[n++]="TERM_PROGRAM=HelgeTerminal";
    if(wrap){
        const char *original=getenv("ZDOTDIR");
        if(asprintf(&out->directory,"ZDOTDIR=%s",shim)<0||asprintf(&out->original,"HELGE_TERMINAL_ORIGINAL_ZDOTDIR=%s",original?original:"")<0)return ENOMEM;
        out->values[n++]=out->directory;out->values[n++]=out->original;
        out->values[n++]=original?"HELGE_TERMINAL_ZDOTDIR_SET=1":"HELGE_TERMINAL_ZDOTDIR_SET=0";
    }
    return 0;
}
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
    SpawnEnvironment env={0};
    if(!error)error=make_environment(launcher,executable,target_argv,argc,&env);
    if(!error)error=posix_spawn(&out.pid,launcher,&actions,&attr,argv,env.values);
    destroy_environment(&env);
    posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);close(high_slave);close(high_status);free(argv);
    if(error){out.error=error;out.pid=-1;goto cleanup;}
    fcntl(master,F_SETFD,FD_CLOEXEC);fcntl(master,F_SETFL,fcntl(master,F_GETFL)|O_NONBLOCK);
    fcntl(p[0],F_SETFD,FD_CLOEXEC);fcntl(p[0],F_SETFL,fcntl(p[0],F_GETFL)|O_NONBLOCK);
    out.master=master;master=-1;out.status=p[0];p[0]=-1;
cleanup:
    if(master>=0)close(master);if(slave>=0)close(slave);if(p[0]>=0)close(p[0]);if(p[1]>=0)close(p[1]);return out;
}
