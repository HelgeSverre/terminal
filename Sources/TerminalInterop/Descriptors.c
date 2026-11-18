#include "Bridge.h"
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <sys/socket.h>
#include <sys/uio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

// One descriptor travels with one byte, so a receiver always knows how many
// arrived and a short read cannot split a control message.
bool helge_descriptor_send(int socket,int descriptor){
    char byte='d';struct iovec io={&byte,1};
    union{char space[CMSG_SPACE(sizeof(int))];struct cmsghdr align;}control;
    memset(&control,0,sizeof control);
    struct msghdr message={0};
    message.msg_iov=&io;message.msg_iovlen=1;message.msg_control=control.space;message.msg_controllen=sizeof control.space;
    struct cmsghdr *header=CMSG_FIRSTHDR(&message);
    header->cmsg_level=SOL_SOCKET;header->cmsg_type=SCM_RIGHTS;header->cmsg_len=CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header),&descriptor,sizeof(int));
    ssize_t sent;do sent=sendmsg(socket,&message,0);while(sent<0&&errno==EINTR);
    return sent==1;
}
int helge_descriptor_receive(int socket){
    char byte=0;struct iovec io={&byte,1};
    union{char space[CMSG_SPACE(sizeof(int))];struct cmsghdr align;}control;
    struct msghdr message={0};
    message.msg_iov=&io;message.msg_iovlen=1;message.msg_control=control.space;message.msg_controllen=sizeof control.space;
    ssize_t received;do received=recvmsg(socket,&message,0);while(received<0&&errno==EINTR);
    if(received!=1||(message.msg_flags&MSG_CTRUNC))return -1;
    for(struct cmsghdr *header=CMSG_FIRSTHDR(&message);header;header=CMSG_NXTHDR(&message,header)){
        if(header->cmsg_level==SOL_SOCKET&&header->cmsg_type==SCM_RIGHTS&&header->cmsg_len==CMSG_LEN(sizeof(int))){
            int descriptor;memcpy(&descriptor,CMSG_DATA(header),sizeof(int));return descriptor;
        }
    }
    return -1;
}
#else
bool helge_descriptor_send(int socket,int descriptor){(void)socket;(void)descriptor;return false;}
int helge_descriptor_receive(int socket){(void)socket;return -1;}
#endif
