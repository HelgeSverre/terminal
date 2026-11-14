#include "Bridge.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <time.h>
static char launcher[4096];
static void reply(void *context,const uint8_t *bytes,size_t count){int fd=*(int *)context;while(count){ssize_t n=write(fd,bytes,count);if(n>0){bytes+=n;count-=n;}else if(errno!=EINTR){assert(errno==EAGAIN);struct pollfd p={fd,POLLOUT,0};assert(poll(&p,1,1000)>0);}}}
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static void terminate_child(pid_t pid){
    // The launcher creates this child's own session/process group. An unreaped
    // child still owns its PID, so cleanup cannot target a later process.
    kill(-pid,SIGKILL);kill(pid,SIGKILL);
    while(waitpid(pid,NULL,0)<0&&errno==EINTR){}
}
static char *saved_locale(const char *name){const char *value=getenv(name);return value?strdup(value):NULL;}
static void restore_locale(const char *name,char *value){if(value){assert(setenv(name,value,1)==0);free(value);}else assert(unsetenv(name)==0);}
static void expect_locale_unchanged(const char *name,const char *before){const char *after=getenv(name);assert((before==NULL&&after==NULL)||(before&&after&&!strcmp(before,after)));}
static void run_locale(const char *lang,const char *all,const char *ctype,const char *expected_lang,const char *expected_codeset){
    char *old_lang=saved_locale("LANG"),*old_all=saved_locale("LC_ALL"),*old_ctype=saved_locale("LC_CTYPE");
    if(lang)assert(setenv("LANG",lang,1)==0);else assert(unsetenv("LANG")==0);
    if(all)assert(setenv("LC_ALL",all,1)==0);else assert(unsetenv("LC_ALL")==0);
    if(ctype)assert(setenv("LC_CTYPE",ctype,1)==0);else assert(unsetenv("LC_CTYPE")==0);
    char *before_lang=saved_locale("LANG"),*before_all=saved_locale("LC_ALL"),*before_ctype=saved_locale("LC_CTYPE");
    const char *script="lang_count=$(env | awk -F= '$1==\"LANG\"{n++} END{print n+0}'); codeset=$(/usr/bin/locale charmap); printf 'LOCALE LANG=<%s> LC_ALL=<%s> LC_CTYPE=<%s> LC_ALL_SET=%s LC_CTYPE_SET=%s LANG_COUNT=%s CODESET=%s' \"${LANG-}\" \"${LC_ALL-}\" \"${LC_CTYPE-}\" \"${LC_ALL+x}\" \"${LC_CTYPE+x}\" \"$lang_count\" \"$codeset\"";
    char *argv[]={"/bin/sh","-c",(char *)script,NULL};TerminalProcess p=helge_terminal_spawn_args(launcher,"/bin/sh","/tmp",80,24,argv);assert(p.error==0);
    char output[4096];size_t used=0;int eof=0,status_eof=0,reaped=0,outcome=0;unsigned char status[16];size_t status_used=0;double deadline=now()+10;
    while((!eof||!status_eof||!reaped)&&now()<deadline){
        struct pollfd fds[2]={{p.master,POLLIN,0},{p.status,POLLIN,0}};poll(fds,2,20);
        if(!eof){ssize_t n=read(p.master,output+used,sizeof(output)-used-1);if(n>0)used+=(size_t)n;else if(n==0||(n<0&&errno==EIO))eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!status_eof){ssize_t n=read(p.status,status+status_used,sizeof(status)-status_used);if(n>0)status_used+=(size_t)n;else if(n==0)status_eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!reaped){int result=waitpid(p.pid,&outcome,WNOHANG);assert(result>=0);if(result==p.pid)reaped=1;}
    }
    if(!reaped)terminate_child(p.pid);
    close(p.master);close(p.status);
    assert(eof&&status_eof&&reaped&&status_used==0&&WIFEXITED(outcome)&&WEXITSTATUS(outcome)==0);output[used]=0;
    if(expected_lang){
        char expected[256];int length=snprintf(expected,sizeof(expected),"LOCALE LANG=<%s> LC_ALL=<%s> LC_CTYPE=<%s> LC_ALL_SET=%s LC_CTYPE_SET=%s LANG_COUNT=1 CODESET=%s",expected_lang,all?all:"",ctype?ctype:"",all?"x":"",ctype?"x":"",expected_codeset);assert(length>0&&(size_t)length<sizeof(expected));
        if(!strstr(output,expected))fprintf(stderr,"locale PTY mismatch: %s\n",output);assert(strstr(output,expected));
    }else{
        assert(strstr(output,"LOCALE LANG=<")&&!strstr(output,"LOCALE LANG=<>"));
        char expected[256];int length=snprintf(expected,sizeof(expected),"LC_ALL=<%s> LC_CTYPE=<%s> LC_ALL_SET=%s LC_CTYPE_SET=%s LANG_COUNT=1 CODESET=%s",all?all:"",ctype?ctype:"",all?"x":"",ctype?"x":"",expected_codeset);assert(length>0&&(size_t)length<sizeof(expected));
        if(!strstr(output,expected))fprintf(stderr,"default locale PTY mismatch: %s\n",output);assert(strstr(output,expected));
    }
    expect_locale_unchanged("LANG",before_lang);expect_locale_unchanged("LC_ALL",before_all);expect_locale_unchanged("LC_CTYPE",before_ctype);free(before_lang);free(before_all);free(before_ctype);
    restore_locale("LANG",old_lang);restore_locale("LC_ALL",old_all);restore_locale("LC_CTYPE",old_ctype);
    printf("PASS PTY locale: LANG=%s LC_ALL=%s LC_CTYPE=%s CODESET=%s\n",expected_lang?expected_lang:"<default>",all?all:"",ctype?ctype:"",expected_codeset);
}
static void run(const char *executable,const char *cwd,const char *script,int expected_error,const char *expected_text){
    char *argv[]={(char *)executable,"-c",(char *)script,NULL};
    TerminalProcess p=helge_terminal_spawn_args(launcher,executable,cwd,123,37,argv);assert(p.error==0);
    Terminal *core=helge_terminal_create(123,37);assert(core);
    char output[300000];size_t used=0;unsigned char status[16];size_t status_used=0;int eof=0,status_eof=0,reaped=0,outcome=0;
    double deadline=now()+10;
    while((!eof||!status_eof||!reaped)&&now()<deadline){
        struct pollfd fds[2]={{p.master,POLLIN,0},{p.status,POLLIN,0}};poll(fds,2,20);
        if(!eof){ssize_t n=read(p.master,output+used,sizeof(output)-used-1);if(n>0){size_t parsed=0;while(parsed<(size_t)n||helge_terminal_has_work(core)){parsed+=helge_terminal_feed(core,(const uint8_t *)output+used+parsed,(size_t)n-parsed,0);helge_terminal_replies(core,&p.master,reply);}assert(helge_terminal_validate(core));used+=n;}else if(n==0||(n<0&&errno==EIO))eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!status_eof){ssize_t n=read(p.status,status+status_used,sizeof(status)-status_used);if(n>0)status_used+=n;else if(n==0)status_eof=1;else assert(errno==EAGAIN||errno==EINTR);}
        if(!reaped){int result=waitpid(p.pid,&outcome,WNOHANG);assert(result>=0);if(result==p.pid)reaped=1;}
    }
    if(!reaped)terminate_child(p.pid);
    close(p.master);close(p.status);
    assert(eof&&status_eof&&reaped);output[used]=0;
    if(expected_error){assert(status_used==8);int error;memcpy(&error,status+4,4);assert(error==expected_error);}
    else{assert(status_used==0);if(!WIFEXITED(outcome)||WEXITSTATUS(outcome)!=0)fprintf(stderr,"child failed (%d): %s\n",outcome,output);assert(WIFEXITED(outcome)&&WEXITSTATUS(outcome)==0);assert(strstr(output,expected_text));}
    helge_terminal_finish(core);assert(helge_terminal_validate(core));
    if(!expected_error){TerminalSearch *search=helge_terminal_search_create(core,(const uint8_t *)expected_text,strlen(expected_text));assert(search);uint32_t phase;while((phase=helge_terminal_search_fill(core,search))==0||phase==1){helge_terminal_search_step(search);}assert(phase==2);assert(helge_terminal_search_accept(core,search)==5);helge_terminal_search_destroy(search);}
    helge_terminal_destroy(core);
    printf("PASS PTY: %s (%zu bytes, child reaped, final output drained)\n",expected_text,used);
}
int main(int argc,char **argv){assert(argc==2);snprintf(launcher,sizeof launcher,"%s",argv[1]);
    run_locale(NULL,NULL,NULL,NULL,"UTF-8");
    run_locale("",NULL,NULL,NULL,"UTF-8");
    run_locale("en_US.UTF-8",NULL,NULL,"en_US.UTF-8","UTF-8");
    run_locale("C",NULL,NULL,"C","US-ASCII");
    run_locale("en_US.UTF-8","C",NULL,"en_US.UTF-8","US-ASCII");
    run_locale("en_US.UTF-8",NULL,"C","en_US.UTF-8","US-ASCII");
    // LC_ALL wins even over a conflicting LC_CTYPE, while empty overrides
    // remain present and fall through to the next locale category.
    run_locale("C","en_US.UTF-8","C","C","UTF-8");
    run_locale("C","","en_US.UTF-8","C","UTF-8");
    run_locale("en_US.UTF-8","","","en_US.UTF-8","UTF-8");
    run_locale("","C","en_US.UTF-8",NULL,"US-ASCII");
    run("/bin/sh","/tmp","printf 'cwd=';pwd; stty size;test -t 0 && test -t 1 && test -t 2; printf 'CONTROLLING=';ps -o tpgid= -p $$;printf 'DONE'",0,"37 123");
    run("/bin/sh","/tmp","i=0;while [ $i -lt 20000 ];do printf 'final-burst-';i=$((i+1));done;printf 'FINAL_SENTINEL'",0,"FINAL_SENTINEL");
    run("/does-not-exist","/tmp","",ENOENT,"exec failure");
    run("/bin/sh","/does-not-exist","",ENOENT,"cwd failure");
    run("/bin/sh","/tmp","test \"$TERM\" = xterm-256color; test -z \"${VK_DRIVER_FILES+x}\";printf 'ENV_OK'",0,"ENV_OK");
    // What another terminal said about itself, had this one been started
    // from it, does not reach the child; this terminal's own version does.
    setenv("TERM_PROGRAM_VERSION","9.9.9",1);setenv("GHOSTTY_RESOURCES_DIR","/elsewhere",1);
    setenv("KITTY_WINDOW_ID","7",1);setenv("ITERM_SESSION_ID","w0t0p0",1);setenv("TMUX","/tmp/tmux-0/default,1,0",1);
    setenv("TERMINFO","/elsewhere/terminfo",1);
    setenv("UNRELATED_VARIABLE","kept",1);
    run("/bin/sh","/tmp","test -z \"${TERM_PROGRAM_VERSION+x}${GHOSTTY_RESOURCES_DIR+x}${KITTY_WINDOW_ID+x}${ITERM_SESSION_ID+x}${TMUX+x}${TERMINFO+x}\""
        " && test \"$TERM_PROGRAM\" = HelgeTerminal && test \"$UNRELATED_VARIABLE\" = kept && printf 'FOREIGN_GONE'",0,"FOREIGN_GONE");
    helge_terminal_set_program_version("1.2.3");
    run("/bin/sh","/tmp","test \"$TERM_PROGRAM_VERSION\" = 1.2.3 && printf 'VERSION_OK'",0,"VERSION_OK");
    helge_terminal_set_program_version(NULL);
    run("/bin/sh","/tmp","/bin/bash --noprofile --norc -i -c 'printf BASH_CORPUS_OK'",0,"BASH_CORPUS_OK");
    run("/bin/sh","/tmp","fish --no-config -c 'printf FISH_CORPUS_OK'",0,"FISH_CORPUS_OK");
    run("/bin/sh","/tmp","nvim --clean -n -u NONE -c 'call setline(1, \"猫 NVIM corpus\")' -c redraw -c 'qa!' && printf NVIM_CORPUS_OK",0,"NVIM_CORPUS_OK");
    run("/bin/sh","/tmp","tmux -L terminal-smoke-$$ -f /dev/null new-session 'printf TMUX_CORPUS; sleep 0.2'; printf TMUX_CORPUS_OK",0,"TMUX_CORPUS_OK");
    run("/bin/sh","/tmp","printf 'one\ntwo\n' | fzf --bind 'load:accept' && printf FZF_CORPUS_OK",0,"FZF_CORPUS_OK");
    return 0;
}
