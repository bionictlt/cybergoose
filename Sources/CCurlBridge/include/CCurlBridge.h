#ifndef CG_CURL_H
#define CG_CURL_H
#include <stdint.h>
#include <stddef.h>
typedef struct cg_curl cg_curl;
typedef int (*cg_curl_progress)(uint64_t bytes, void *context);
cg_curl *cg_curl_create(void);
void cg_curl_cancel(cg_curl *s);
void cg_curl_free(cg_curl *s);
/* One request at a time per handle. Credentials never enter argv or log files. */
int cg_curl_request(cg_curl *s, const char *url, const char *user, const char *secret,
    const char *sigv4, int tls, const char *method, const char *headers,
    const char *commands, const char *input, const char *output,
    cg_curl_progress progress, void *context);
long cg_curl_status(cg_curl *s);
uint64_t cg_curl_bytes(cg_curl *s);
const char *cg_curl_headers(cg_curl *s);
const char *cg_curl_error(cg_curl *s);
#endif
