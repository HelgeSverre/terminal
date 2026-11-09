#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <mach/mach_time.h>
static int ack;
static uint64_t now(void) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); return mach_absolute_time()*tb.numer/tb.denom; }
static void acknowledge(unsigned long long id) {
 struct winsize size={0}; ioctl(STDIN_FILENO,TIOCGWINSZ,&size);
 dprintf(ack,"%llu %llu %u %u\n",id,(unsigned long long)now(),size.ws_col,size.ws_row);
}
static void *reader(void *unused) {
 (void)unused; char c, line[64]; size_t n=0;
 while(read(STDIN_FILENO,&c,1)>0) {
  if(c=='\r'||c=='\n') { if(n) {line[n]=0;acknowledge(strtoull(line,NULL,10));n=0;} }
  else if(n<sizeof(line)-1) line[n++]=c;
 }
 return NULL;
}
int main(int argc,char **argv) {
 if(argc!=3) return 2;
 ack=open(argv[1],O_WRONLY|O_CREAT|O_TRUNC,0600); if(ack<0)return 3;
 struct termios tty; tcgetattr(0,&tty);tty.c_lflag&=~(ICANON|ECHO);tty.c_cc[VMIN]=1;tty.c_cc[VTIME]=0;tcsetattr(0,TCSANOW,&tty);
 pthread_t t; pthread_create(&t,NULL,reader,NULL); acknowledge(0);
 const char *unicode="中文日本語한국어 Ελληνικά العربية हिन्दी 😀👩‍💻 é terminal\n";
 const char *sql="\033[36m| 004239 |\033[0m SELECT account_id, display_name, created_at FROM customers WHERE active = true; | 中文 😀 |\n";
 const char *row=strcmp(argv[2],"unicode")==0?unicode:sql;size_t len=strlen(row);char block[16384];size_t size=0;
 while(size+len<=sizeof(block)){memcpy(block+size,row,len);size+=len;}
 for(;;){size_t off=0;while(off<size){ssize_t n=write(1,block+off,size-off);if(n<=0)return 0;off+=(size_t)n;}}
}
