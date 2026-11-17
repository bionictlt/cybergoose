#ifndef CG_SSH_H
#define CG_SSH_H
#include <stdint.h>
#include <stddef.h>
typedef struct cg_ssh cg_ssh;
typedef struct { uint64_t size; uint64_t modified; unsigned long permissions; unsigned long flags; } cg_attrs;
typedef int (*cg_progress)(uint64_t bytes, void *context);
cg_ssh *cg_create(void);
void cg_cancel(cg_ssh *s);
void cg_free(cg_ssh *s);
const char *cg_error(cg_ssh *s);
int cg_connection_failed(cg_ssh *s);
int cg_handshake(cg_ssh *s, const char *host, int port);
const unsigned char *cg_hostkey(cg_ssh *s, size_t *length, int *type);
int cg_auth(cg_ssh *s, const char *user, const char *secret, const char *private_key);
int cg_realpath(cg_ssh *s, const char *path, char *output, size_t capacity);
void *cg_opendir(cg_ssh *s, const char *path);
int cg_readdir(cg_ssh *s, void *handle, char *name, size_t capacity, cg_attrs *attrs);
void cg_closedir(cg_ssh *s, void *handle);
int cg_mkdir(cg_ssh *s, const char *path);
int cg_rename(cg_ssh *s, const char *from, const char *to);
int cg_remove(cg_ssh *s, const char *path, int directory);
int cg_stat(cg_ssh *s, const char *path, cg_attrs *attrs);
int cg_commit(cg_ssh *s, const char *from, const char *to, int overwrite, long permissions);
int cg_transfer(cg_ssh *s, const char *remote, const char *local, int upload, cg_progress callback, void *context, uint64_t *bytes);
int cg_scp_transfer(cg_ssh *s, const char *remote, const char *local, int upload, cg_progress callback, void *context, uint64_t *bytes);
#endif
