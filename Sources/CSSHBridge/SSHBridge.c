#include "CSSHBridge.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <netdb.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct cg_ssh {
    LIBSSH2_SESSION *session;
    LIBSSH2_SFTP *sftp;
    int fd;
    pthread_mutex_t lock;
    atomic_bool cancelled;
    char error[512];
};
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) { libssh2_init(0); }
static int fail(cg_ssh *s, const char *message) {
    snprintf(s->error, sizeof(s->error), "%s", atomic_load(&s->cancelled) ? "Операция отменена" : message);
    return -1;
}
static int ssh_error(cg_ssh *s, const char *operation) {
    char *message = NULL;
    if(s->session) libssh2_session_last_error(s->session, &message, NULL, 0);
    snprintf(s->error, sizeof(s->error), "%s: %s (SFTP %lu)", operation,
             atomic_load(&s->cancelled) ? "Операция отменена" : (message ? message : "SSH error"),
             s->sftp ? libssh2_sftp_last_error(s->sftp) : 0);
    return -1;
}
cg_ssh *cg_create(void) {
    pthread_once(&initialized, initialize);
    cg_ssh *s = calloc(1, sizeof(*s));
    if(!s) return NULL;
    s->fd = -1;
    pthread_mutex_init(&s->lock, NULL);
    atomic_init(&s->cancelled, 0);
    return s;
}
void cg_cancel(cg_ssh *s) {
    atomic_store(&s->cancelled, 1);
    pthread_mutex_lock(&s->lock);
    if(s->fd >= 0) shutdown(s->fd, SHUT_RDWR);
    pthread_mutex_unlock(&s->lock);
}
void cg_free(cg_ssh *s) {
    if(!s) return;
    cg_cancel(s);
    // Socket is shut down first: cleanup cannot wait for an unresponsive peer.
    if(s->sftp) libssh2_sftp_shutdown(s->sftp);
    if(s->session) libssh2_session_free(s->session);
    if(s->fd >= 0) close(s->fd);
    pthread_mutex_destroy(&s->lock);
    free(s);
}
const char *cg_error(cg_ssh *s) { return s->error; }
int cg_connection_failed(cg_ssh *s) {
    if(atomic_load(&s->cancelled)) return 1;
    int code = s->session ? libssh2_session_last_errno(s->session) : 0;
    return code == LIBSSH2_ERROR_SOCKET_SEND || code == LIBSSH2_ERROR_SOCKET_RECV ||
           code == LIBSSH2_ERROR_SOCKET_DISCONNECT || code == LIBSSH2_ERROR_TIMEOUT ||
           code == LIBSSH2_ERROR_SOCKET_TIMEOUT || code == LIBSSH2_ERROR_CHANNEL_CLOSED;
}
static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1000000000.0;
}
int cg_handshake(cg_ssh *s, const char *host, int port) {
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char service[16]; snprintf(service, sizeof(service), "%d", port);
    int rc = getaddrinfo(host, service, &hints, &addresses);
    if(rc) return fail(s, gai_strerror(rc));
    double deadline = now() + 15;
    int connected = 0;
    for(struct addrinfo *a = addresses; a && !atomic_load(&s->cancelled) && now() < deadline; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if(fd < 0) continue;
        int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        fcntl(fd, F_SETFL, O_NONBLOCK);
        pthread_mutex_lock(&s->lock); s->fd = fd; pthread_mutex_unlock(&s->lock);
        if(atomic_load(&s->cancelled)) break;
        rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if(rc == 0) connected = 1;
        else if(errno == EINPROGRESS) {
            while(!atomic_load(&s->cancelled) && now() < deadline) {
                struct pollfd p = {fd, POLLOUT, 0};
                rc = poll(&p, 1, 100);
                if(rc < 0 && errno == EINTR) continue;
                if(rc < 0) break;
                if(rc > 0) {
                    int error = 0; socklen_t length = sizeof(error);
                    if(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0) connected = 1;
                    break;
                }
            }
        }
        if(connected) break;
        pthread_mutex_lock(&s->lock); s->fd = -1; close(fd); pthread_mutex_unlock(&s->lock);
    }
    freeaddrinfo(addresses);
    if(!connected || atomic_load(&s->cancelled)) return fail(s, "Не удалось подключиться к серверу (таймаут 15 с)");
    fcntl(s->fd, F_SETFL, 0);
    s->session = libssh2_session_init();
    if(!s->session) return fail(s, "Не удалось создать SSH-сессию");
    libssh2_session_set_blocking(s->session, 1);
    libssh2_session_set_timeout(s->session, 15000);
    // Do not negotiate legacy SHA-1 host signatures or obsolete ciphers.
    libssh2_session_method_pref(s->session, LIBSSH2_METHOD_HOSTKEY, "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256");
    libssh2_session_method_pref(s->session, LIBSSH2_METHOD_CRYPT_CS, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes128-ctr");
    libssh2_session_method_pref(s->session, LIBSSH2_METHOD_CRYPT_SC, "aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes128-ctr");
    if(libssh2_session_handshake(s->session, s->fd)) return ssh_error(s, "SSH handshake");
    return 0;
}
const unsigned char *cg_hostkey(cg_ssh *s, size_t *length, int *type) {
    return (const unsigned char *)libssh2_session_hostkey(s->session, length, type);
}
int cg_auth(cg_ssh *s, const char *user, const char *secret, const char *private_key) {
    if(atomic_load(&s->cancelled)) return fail(s, "Отменено");
    int rc = private_key && private_key[0]
        ? libssh2_userauth_publickey_fromfile_ex(s->session, user, (unsigned int)strlen(user), NULL, private_key, secret)
        : libssh2_userauth_password_ex(s->session, user, (unsigned int)strlen(user), secret, (unsigned int)strlen(secret), NULL);
    if(rc) return ssh_error(s, "Авторизация");
    s->sftp = libssh2_sftp_init(s->session);
    if(!s->sftp) return ssh_error(s, "SFTP subsystem");
    return 0;
}
int cg_realpath(cg_ssh *s, const char *path, char *output, size_t capacity) {
    int rc = libssh2_sftp_symlink_ex(s->sftp, path, (unsigned int)strlen(path), output, (unsigned int)capacity - 1, LIBSSH2_SFTP_REALPATH);
    if(rc < 0) return ssh_error(s, "Путь");
    if((size_t)rc >= capacity - 1) return fail(s, "Слишком длинный путь");
    output[rc] = 0; return rc;
}
void *cg_opendir(cg_ssh *s, const char *path) {
    if(atomic_load(&s->cancelled)) { fail(s, "Отменено"); return NULL; }
    void *h = libssh2_sftp_opendir(s->sftp, path);
    if(!h) ssh_error(s, "Чтение каталога");
    return h;
}
int cg_readdir(cg_ssh *s, void *handle, char *name, size_t capacity, cg_attrs *attrs) {
    if(atomic_load(&s->cancelled)) return fail(s, "Отменено");
    LIBSSH2_SFTP_ATTRIBUTES a = {0};
    int rc = libssh2_sftp_readdir_ex(handle, name, capacity - 1, NULL, 0, &a);
    if(rc < 0) return ssh_error(s, "Чтение каталога");
    if((size_t)rc >= capacity - 1) return fail(s, "Слишком длинное имя файла");
    name[rc] = 0;
    attrs->size = a.filesize; attrs->modified = a.mtime; attrs->permissions = a.permissions; attrs->flags = a.flags;
    return rc;
}
void cg_closedir(cg_ssh *s, void *handle) { (void)s; libssh2_sftp_closedir(handle); }
int cg_mkdir(cg_ssh *s, const char *path) {
    return libssh2_sftp_mkdir(s->sftp, path, 0755) ? ssh_error(s, "Создание каталога") : 0;
}
int cg_rename(cg_ssh *s, const char *from, const char *to) {
    return libssh2_sftp_rename_ex(s->sftp, from, (unsigned int)strlen(from), to, (unsigned int)strlen(to), 0) ? ssh_error(s, "Переименование") : 0;
}
int cg_remove(cg_ssh *s, const char *path, int directory) {
    int rc = directory ? libssh2_sftp_rmdir(s->sftp, path) : libssh2_sftp_unlink(s->sftp, path);
    return rc ? ssh_error(s, "Удаление") : 0;
}
int cg_transfer(cg_ssh *s, const char *remote, const char *local, int upload, cg_progress callback, void *context, uint64_t *bytes) {
    // Callers supply a unique temporary remote/local destination. Never overwrite.
    int fd = open(local, upload ? (O_RDONLY | O_NOFOLLOW | O_NONBLOCK) : (O_WRONLY | O_CREAT | O_EXCL), 0600);
    if(fd < 0) return fail(s, strerror(errno));
    struct stat info;
    if(fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); return fail(s, "Можно передавать только обычные файлы"); }
    if(upload) fcntl(fd, F_SETFL, 0);
    LIBSSH2_SFTP_HANDLE *handle = libssh2_sftp_open(s->sftp, remote,
        upload ? (LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL) : LIBSSH2_FXF_READ, 0600);
    if(!handle) { close(fd); return ssh_error(s, "Открытие файла"); }
    char buffer[65536]; uint64_t total = 0; int result = 0;
    while(!atomic_load(&s->cancelled)) {
        ssize_t count = upload ? read(fd, buffer, sizeof(buffer)) : libssh2_sftp_read(handle, buffer, sizeof(buffer));
        if(count == 0) break;
        if(count < 0) { result = upload ? fail(s, strerror(errno)) : ssh_error(s, "Скачивание"); break; }
        ssize_t offset = 0;
        while(offset < count && !atomic_load(&s->cancelled)) {
            ssize_t written = upload ? libssh2_sftp_write(handle, buffer + offset, (size_t)(count - offset)) : write(fd, buffer + offset, (size_t)(count - offset));
            if(written <= 0) { result = upload ? ssh_error(s, "Отправка") : fail(s, strerror(errno)); break; }
            offset += written; total += written;
        }
        if(result) break;
        if(callback && callback(total, context)) { result = fail(s, "Операция отменена"); break; }
    }
    if(atomic_load(&s->cancelled)) result = fail(s, "Отменено");
    if(libssh2_sftp_close(handle) && !result) result = ssh_error(s, "Закрытие файла");
    if(!upload && fsync(fd) && !result) result = fail(s, strerror(errno));
    if(close(fd) && !result) result = fail(s, strerror(errno));
    if(bytes) *bytes = total;
    return result;
}

int cg_stat(cg_ssh *s, const char *path, cg_attrs *attrs) {
    LIBSSH2_SFTP_ATTRIBUTES a = {0};
    int rc = libssh2_sftp_lstat(s->sftp, path, &a);
    if(rc) {
        unsigned long error = libssh2_sftp_last_error(s->sftp);
        if(libssh2_session_last_errno(s->session) == LIBSSH2_ERROR_SFTP_PROTOCOL &&
           (error == LIBSSH2_FX_NO_SUCH_FILE || error == LIBSSH2_FX_NO_SUCH_PATH)) return 1;
        return ssh_error(s, "Метаданные");
    }
    attrs->size = a.filesize; attrs->modified = a.mtime; attrs->permissions = a.permissions; attrs->flags = a.flags;
    return 0;
}
int cg_commit(cg_ssh *s, const char *from, const char *to, int overwrite, long permissions) {
    if(permissions >= 0) {
        LIBSSH2_SFTP_ATTRIBUTES a = {0};
        a.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS; a.permissions = (unsigned long)permissions & 0777;
        if(libssh2_sftp_setstat(s->sftp, from, &a)) return ssh_error(s, "Права файла");
    }
    if(!overwrite) return cg_rename(s, from, to);
    int rc = libssh2_sftp_posix_rename(s->sftp, from, to);
    if(rc && libssh2_sftp_last_error(s->sftp) == LIBSSH2_FX_OP_UNSUPPORTED)
        rc = libssh2_sftp_rename_ex(s->sftp, from, (unsigned int)strlen(from), to, (unsigned int)strlen(to),
            LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE);
    return rc ? ssh_error(s, "Замена файла (без удаления прежнего назначения)") : 0;
}

int cg_scp_transfer(cg_ssh *s, const char *remote, const char *local, int upload, cg_progress callback, void *context, uint64_t *bytes) {
    if(strchr(remote, '\n') || strchr(remote, '\r')) return fail(s, "SCP не поддерживает переводы строк в пути");
    if(atomic_load(&s->cancelled)) return fail(s, "Отменено");
    int fd = open(local, upload ? (O_RDONLY | O_NOFOLLOW | O_NONBLOCK) : (O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW), 0600);
    if(fd < 0) return fail(s, strerror(errno));
    struct stat local_info;
    if(fstat(fd, &local_info) || !S_ISREG(local_info.st_mode)) { close(fd); return fail(s, "Можно передавать только обычные файлы"); }
    (void)fcntl(fd, F_SETFL, 0);
    // SCP has no exclusive-create flag. Reserve a unique staging file via SFTP first.
    if(upload) {
        LIBSSH2_SFTP_HANDLE *reservation = libssh2_sftp_open(s->sftp, remote,
            LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL, 0600);
        if(!reservation) { close(fd); return ssh_error(s, "Резервирование SCP-файла"); }
        if(libssh2_sftp_close(reservation)) { close(fd); return ssh_error(s, "Закрытие SCP-файла"); }
    }
    libssh2_struct_stat remote_info;
    LIBSSH2_CHANNEL *channel = upload
        ? libssh2_scp_send64(s->session, remote, 0600, local_info.st_size, 0, 0)
        : libssh2_scp_recv2(s->session, remote, &remote_info);
    if(!channel) { close(fd); return ssh_error(s, "SCP"); }
    uint64_t expected = upload ? (uint64_t)local_info.st_size : (uint64_t)remote_info.st_size;
    char buffer[65536]; uint64_t total = 0; int result = 0;
    while(total < expected && !result) {
        if(atomic_load(&s->cancelled) || (callback && callback(total, context))) { result = fail(s, "Отменено"); break; }
        size_t amount = expected - total < sizeof(buffer) ? (size_t)(expected - total) : sizeof(buffer);
        ssize_t count = upload ? read(fd, buffer, amount) : libssh2_channel_read(channel, buffer, amount);
        if(count <= 0) { result = fail(s, "SCP: передача оборвалась до конца файла"); break; }
        ssize_t offset = 0;
        while(offset < count) {
            ssize_t n = upload ? libssh2_channel_write(channel, buffer + offset, (size_t)(count - offset)) : write(fd, buffer + offset, (size_t)(count - offset));
            if(n <= 0) { result = ssh_error(s, "SCP: запись"); break; }
            offset += n; total += (uint64_t)n;
        }
    }
    if(!result) {
        char ack = 0;
        // Finish the SCP record and require the peer's acknowledgement.
        if(upload) {
            if(libssh2_channel_write(channel, &ack, 1) != 1 || libssh2_channel_read(channel, &ack, 1) != 1 || ack != 0)
                result = fail(s, "SCP: сервер не подтвердил запись");
        } else {
            if(libssh2_channel_read(channel, &ack, 1) != 1 || ack != 0 || libssh2_channel_write(channel, &ack, 1) != 1)
                result = fail(s, "SCP: сервер не подтвердил чтение");
        }
    }
    if(!result && callback && callback(total, context)) result = fail(s, "Отменено");
    if(!result) {
        if(libssh2_channel_send_eof(channel) || libssh2_channel_wait_eof(channel) || libssh2_channel_wait_closed(channel))
            result = ssh_error(s, "SCP: закрытие канала");
        else if(libssh2_channel_get_exit_status(channel) != 0) result = fail(s, "SCP: сервер завершил передачу с ошибкой");
    }
    libssh2_channel_free(channel);
    if(!upload && fsync(fd) && !result) result = fail(s, strerror(errno));
    if(close(fd) && !result) result = fail(s, strerror(errno));
    if(bytes) *bytes = total;
    return result;
}
