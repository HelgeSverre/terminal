#ifndef TERMINAL_BRIDGE_H
#define TERMINAL_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct Terminal Terminal;
uint32_t helge_terminal_abi_version(void);
Terminal *helge_terminal_create(uint32_t cols,uint32_t rows);
void helge_terminal_destroy(Terminal *);
size_t helge_terminal_feed(Terminal *,const uint8_t *,size_t,uint64_t);
bool helge_terminal_resize(Terminal *,uint32_t,uint32_t);
char *helge_terminal_snapshot(Terminal *,size_t,uint64_t);
/* Views are borrowed only during the callback; copy them before returning.
 * Colors: 0=default, 0x01_0000_ii=indexed, 0x02_rrggbb=sRGB. */
typedef struct {
  const uint8_t *text; size_t text_len;
  const uint8_t *link; size_t link_len;
  uint32_t foreground, background, underline_color;
  uint16_t style_flags;
  uint8_t kind, cell_flags, underline;
} TerminalCellView;
bool helge_terminal_snapshot_binary(Terminal *,size_t,uint64_t,void *,void (*)(void *,const uint8_t *,size_t,const TerminalCellView *,size_t,const uint8_t *,size_t));
bool helge_terminal_view_snapshot_binary(Terminal *,uint64_t,void *,void (*)(void *,const uint8_t *,size_t,const TerminalCellView *,size_t,const uint8_t *,size_t));
void helge_terminal_view_scroll(Terminal *,int64_t);
void helge_terminal_view_follow_tail(Terminal *);
uint32_t helge_terminal_clear_display(Terminal *);
void helge_terminal_string_free(char *);
void helge_terminal_replies(Terminal *,void *,void (*)(void *,const uint8_t *,size_t));
/* OSC 52 writes are owner-queue work, independent of snapshots. The request
 * ID is one-shot and must be completed after the native policy decision. */
void helge_terminal_take_clipboard_requests(Terminal *,void *,void (*)(void *,uint64_t,const uint8_t *,size_t));
bool helge_terminal_complete_clipboard_request(Terminal *,uint64_t);
bool helge_terminal_input(Terminal *,const char *,uint32_t,uint32_t,uint32_t,void *,void (*)(void *,const uint8_t *,size_t));
/* Extended keyboard adapter for hosts that retain layout and committed-text
 * metadata. Zero shifted/base-layout values mean absent; strings are copied
 * synchronously before the callback returns. */
bool helge_terminal_input_with_metadata(Terminal *,const char *,uint32_t,uint32_t,uint32_t,const char *,const char *,uint32_t,uint32_t,void *,void (*)(void *,const uint8_t *,size_t));
typedef struct SearchTask TerminalSearch;
/* Exclusive task ownership migrates owner -> worker -> owner. No terminal
 * access on worker. Status: 0=work,1=page,2=done,3=changed,4=limit; accept 5=hit. */
TerminalSearch *helge_terminal_search_create(Terminal *,const uint8_t *,size_t);
uint32_t helge_terminal_search_fill(Terminal *,TerminalSearch *);
uint32_t helge_terminal_search_step(TerminalSearch *);
uint32_t helge_terminal_search_accept(Terminal *,TerminalSearch *);
void helge_terminal_search_destroy(TerminalSearch *);
/* The accepted match set stays with the terminal. Position is one-based from
 * the newest match; navigation wraps and returns false once no retained match
 * is still valid. */
bool helge_terminal_search_position(Terminal *,uint32_t *,uint32_t *,bool *);
bool helge_terminal_search_navigate(Terminal *,bool,uint32_t *,uint32_t *,bool *);
void helge_terminal_search_clear(Terminal *);
void helge_terminal_finish(Terminal *);
typedef struct {int master;int status;int pid;int error;} TerminalProcess;
TerminalProcess helge_terminal_spawn_args(const char *,const char *,const char *,uint16_t,uint16_t,char *const []);
/* The same, with "NAME=value" entries that replace the child's variables of
 * those names; the last argument is NULL-terminated or NULL. */
TerminalProcess helge_terminal_spawn_environment(const char *,const char *,const char *,uint16_t,uint16_t,char *const [],char *const []);
void helge_terminal_set_program_version(const char *);
bool helge_terminal_validate(Terminal *);
bool helge_terminal_has_work(Terminal *);
void helge_terminal_set_history_limit(Terminal *,uint32_t);
void helge_terminal_set_history_byte_limit(Terminal *,uint64_t);
bool helge_terminal_image_rgba(Terminal *,uint32_t,uint64_t,void *,void (*)(void *,const uint8_t *,size_t));
bool helge_terminal_resize_pixels(Terminal *,uint32_t,uint32_t,uint32_t,uint32_t);
uint64_t helge_terminal_history_bytes(Terminal *);
#endif
