#include "CCurlBridge.h"
#include <curl/curl.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>
struct cg_curl {
    CURL *easy;
    atomic_bool cancelled;
    long status;
    uint64_t bytes;
    char error[CURL_ERROR_SIZE];
    char headers[65536];
    size_t header_length;
    cg_curl_progress progress;
    void *context;
};
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
cg_curl *cg_curl_create(void) {
    pthread_once(&initialized, initialize);
    cg_curl *s = calloc(1, sizeof(*s));
    if(s) {
        atomic_init(&s->cancelled, 0);
        s->easy = curl_easy_init();
        if(!s->easy) { free(s); return NULL; }
    }
    return s;
}
void cg_curl_cancel(cg_curl *s) { atomic_store(&s->cancelled, 1); }
void cg_curl_free(cg_curl *s) { if(s) { curl_easy_cleanup(s->easy); free(s); } }
long cg_curl_status(cg_curl *s) { return s->status; }
uint64_t cg_curl_bytes(cg_curl *s) { return s->bytes; }
const char *cg_curl_headers(cg_curl *s) { return s->headers; }
const char *cg_curl_error(cg_curl *s) { return s->error; }
static int progress_callback(void *p, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    (void)dt; (void)ut;
    cg_curl *s = p;
    s->bytes = (uint64_t)(dn > un ? dn : un);
    return atomic_load(&s->cancelled) || (s->progress && s->progress(s->bytes, s->context));
}
static size_t header_callback(char *data, size_t size, size_t count, void *p) {
    cg_curl *s = p; size_t n = size * count;
    /* Reset on a new response (e.g. 100 Continue). */
    if(n >= 5 && !memcmp(data, "HTTP/", 5)) s->header_length = 0;
    if(n >= sizeof(s->headers) - s->header_length) return 0;
    memcpy(s->headers + s->header_length, data, n); s->header_length += n;
    s->headers[s->header_length] = 0;
    return n;
}
static struct curl_slist *lines(const char *text) {
    struct curl_slist *list = NULL;
    if(!text || !*text) return NULL;
    char *copy = strdup(text), *save = NULL;
    if(!copy) return NULL;
    for(char *line = strtok_r(copy, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
        list = curl_slist_append(list, line);
    free(copy); return list;
}
int cg_curl_request(cg_curl *s, const char *url, const char *user, const char *secret,
    const char *sigv4, int tls, const char *method, const char *headers,
    const char *commands, const char *input, const char *output,
    cg_curl_progress progress, void *context) {
    s->status = 0; s->bytes = 0; s->header_length = 0; s->headers[0] = 0; s->error[0] = 0;
    s->progress = progress; s->context = context;
    if(atomic_load(&s->cancelled)) { snprintf(s->error, sizeof(s->error), "Соединение закрыто"); return -1; }
    CURL *curl = s->easy;
    curl_easy_reset(curl); // Retain connection/TLS caches between requests.
    FILE *in = NULL, *out = NULL;
    struct curl_slist *h = lines(headers), *q = lines(commands);
    CURLcode result = CURLE_OK;
#define SET(option, value) do { result = curl_easy_setopt(curl, option, value); if(result != CURLE_OK) goto cleanup; } while(0)
    SET(CURLOPT_URL, url);
    SET(CURLOPT_PROTOCOLS_STR, "ftp,ftps,https");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_PATH_AS_IS, 1L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT, 15L);
    SET(CURLOPT_LOW_SPEED_LIMIT, 1L);
    SET(CURLOPT_LOW_SPEED_TIME, 30L);
    SET(CURLOPT_FTP_RESPONSE_TIMEOUT, 30L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    SET(CURLOPT_FTP_USE_EPSV, 1L);
    SET(CURLOPT_FTP_SKIP_PASV_IP, 1L);
    SET(CURLOPT_ERRORBUFFER, s->error);
    SET(CURLOPT_XFERINFOFUNCTION, progress_callback);
    SET(CURLOPT_XFERINFODATA, s);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_HEADERFUNCTION, header_callback);
    SET(CURLOPT_HEADERDATA, s);
    SET(CURLOPT_USERNAME, user);
    SET(CURLOPT_PASSWORD, secret);
    if(tls) SET(CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    if(sigv4 && *sigv4) SET(CURLOPT_AWS_SIGV4, sigv4);
    if(h) SET(CURLOPT_HTTPHEADER, h);
    if(q) SET(CURLOPT_QUOTE, q);
    if(input && *input) {
        int fd = open(input, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        struct stat info;
        if(fd < 0) { result = CURLE_READ_ERROR; goto cleanup; }
        if(fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); result = CURLE_READ_ERROR; goto cleanup; }
        (void)fcntl(fd, F_SETFL, 0);
        in = fdopen(fd, "rb");
        if(!in) { close(fd); result = CURLE_READ_ERROR; goto cleanup; }
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_READDATA, in);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)info.st_size);
    }
    if(output && *output) {
        int fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if(fd < 0) { result = CURLE_WRITE_ERROR; goto cleanup; }
        out = fdopen(fd, "wb");
        if(!out) { close(fd); result = CURLE_WRITE_ERROR; goto cleanup; }
        SET(CURLOPT_WRITEDATA, out);
    } else { result = CURLE_WRITE_ERROR; goto cleanup; }
    if(!strcmp(method, "HEAD") || !strcmp(method, "COMMAND")) SET(CURLOPT_NOBODY, 1L);
    else if(strcmp(method, "GET") && strcmp(method, "PUT")) SET(CURLOPT_CUSTOMREQUEST, method);
    result = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &s->status);
cleanup:
    if(out) {
        if((fflush(out) || fsync(fileno(out))) && result == CURLE_OK) result = CURLE_WRITE_ERROR;
        if(fclose(out) && result == CURLE_OK) result = CURLE_WRITE_ERROR;
    }
    if(in) fclose(in);
    if(result != CURLE_OK && !s->error[0]) snprintf(s->error, sizeof(s->error), "%s", curl_easy_strerror(result));
    curl_easy_reset(curl);
    s->progress = NULL; s->context = NULL;
    curl_slist_free_all(h); curl_slist_free_all(q);
    return result == CURLE_OK ? 0 : -(int)result;
#undef SET
}
