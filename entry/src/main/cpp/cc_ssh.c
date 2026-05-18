#include "cc_ssh.h"

#include <arpa/inet.h>
#include <errno.h>
#include <libssh2.h>
#include <netdb.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define CC_BUF_CAP 65536

static LIBSSH2_SESSION *g_session = NULL;
static int g_sock = -1;
static char g_last_error[512];
static char g_stdout[CC_BUF_CAP];
static char g_stderr[CC_BUF_CAP];
static size_t g_stdout_len = 0;
static size_t g_stderr_len = 0;
static pthread_mutex_t g_ssh_mutex = PTHREAD_MUTEX_INITIALIZER;

static int cc_ssh_connect_unlocked(const char *host, int port, const char *user, const char *password, int timeout_ms);
static int cc_ssh_exec_unlocked(const char *command, int timeout_ms);
static int cc_ssh_disconnect_unlocked(void);

static void set_error(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, args);
    va_end(args);
}

static void reset_output(void) {
    g_stdout_len = 0;
    g_stderr_len = 0;
    g_stdout[0] = '\0';
    g_stderr[0] = '\0';
}

static void append_buf(char *buf, size_t *len, const char *data, ssize_t n) {
    if (n <= 0 || *len >= CC_BUF_CAP - 1) {
        return;
    }
    size_t room = CC_BUF_CAP - 1 - *len;
    size_t count = (size_t)n < room ? (size_t)n : room;
    memcpy(buf + *len, data, count);
    *len += count;
    buf[*len] = '\0';
}

static int wait_socket(int timeout_ms) {
    if (g_sock < 0 || g_session == NULL) {
        return -1;
    }

    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    fd_set readfds;
    fd_set writefds;
    fd_set *writefd = NULL;
    fd_set *readfd = NULL;
    int dir = libssh2_session_block_directions(g_session);

    FD_ZERO(&readfds);
    FD_ZERO(&writefds);
    if (dir & LIBSSH2_SESSION_BLOCK_INBOUND) {
        FD_SET(g_sock, &readfds);
        readfd = &readfds;
    }
    if (dir & LIBSSH2_SESSION_BLOCK_OUTBOUND) {
        FD_SET(g_sock, &writefds);
        writefd = &writefds;
    }

    return select(g_sock + 1, readfd, writefd, NULL, &tv);
}

static int connect_tcp(const char *host, int port, int timeout_ms) {
    char port_buf[16];
    struct addrinfo hints;
    struct addrinfo *result = NULL;
    snprintf(port_buf, sizeof(port_buf), "%d", port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int rc = getaddrinfo(host, port_buf, &hints, &result);
    if (rc != 0) {
        set_error("resolve failed: %s", gai_strerror(rc));
        return -1;
    }

    int sock = -1;
    for (struct addrinfo *rp = result; rp != NULL; rp = rp->ai_next) {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock < 0) {
            continue;
        }
        struct timeval tv;
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(sock, rp->ai_addr, rp->ai_addrlen) == 0) {
            break;
        }
        close(sock);
        sock = -1;
    }
    freeaddrinfo(result);

    if (sock < 0) {
        set_error("tcp connect failed: %s", strerror(errno));
    }
    return sock;
}

int cc_ssh_connect(const char *host, int port, const char *user, const char *password, int timeout_ms) {
    pthread_mutex_lock(&g_ssh_mutex);
    int rc = cc_ssh_connect_unlocked(host, port, user, password, timeout_ms);
    pthread_mutex_unlock(&g_ssh_mutex);
    return rc;
}

static int cc_ssh_connect_unlocked(const char *host, int port, const char *user, const char *password, int timeout_ms) {
    cc_ssh_disconnect_unlocked();
    reset_output();
    g_last_error[0] = '\0';

    if (host == NULL || user == NULL || password == NULL || port <= 0) {
        set_error("invalid ssh config");
        return -1;
    }

    int rc = libssh2_init(0);
    if (rc != 0) {
        set_error("libssh2_init failed: %d", rc);
        return -1;
    }

    g_sock = connect_tcp(host, port, timeout_ms);
    if (g_sock < 0) {
        libssh2_exit();
        return -1;
    }

    g_session = libssh2_session_init();
    if (g_session == NULL) {
        set_error("libssh2_session_init failed");
        cc_ssh_disconnect_unlocked();
        return -1;
    }
    libssh2_session_set_blocking(g_session, 1);

    rc = libssh2_session_handshake(g_session, g_sock);
    if (rc != 0) {
        set_error("ssh handshake failed: %d", rc);
        cc_ssh_disconnect_unlocked();
        return -1;
    }

    rc = libssh2_userauth_password(g_session, user, password);
    if (rc != 0) {
        set_error("ssh password auth failed: %d", rc);
        cc_ssh_disconnect_unlocked();
        return -1;
    }

    libssh2_session_set_blocking(g_session, 0);
    return 0;
}

int cc_ssh_exec(const char *command, int timeout_ms) {
    pthread_mutex_lock(&g_ssh_mutex);
    int rc = cc_ssh_exec_unlocked(command, timeout_ms);
    pthread_mutex_unlock(&g_ssh_mutex);
    return rc;
}

int cc_ssh_exec_once(const char *host, int port, const char *user, const char *password, const char *command,
                     int connect_timeout_ms, int exec_timeout_ms) {
    pthread_mutex_lock(&g_ssh_mutex);

    int rc = cc_ssh_connect_unlocked(host, port, user, password, connect_timeout_ms);
    if (rc == 0) {
        rc = cc_ssh_exec_unlocked(command, exec_timeout_ms);
    }
    cc_ssh_disconnect_unlocked();

    return rc;
}

int cc_ssh_release_result(void) {
    pthread_mutex_unlock(&g_ssh_mutex);
    return 0;
}

static int cc_ssh_exec_unlocked(const char *command, int timeout_ms) {
    reset_output();
    if (g_session == NULL || command == NULL) {
        set_error("ssh is not connected");
        return -1;
    }

    LIBSSH2_CHANNEL *channel = NULL;
    while ((channel = libssh2_channel_open_session(g_session)) == NULL) {
        if (libssh2_session_last_errno(g_session) != LIBSSH2_ERROR_EAGAIN) {
            set_error("open ssh channel failed");
            return -1;
        }
        if (wait_socket(timeout_ms) <= 0) {
            set_error("open ssh channel timeout");
            return -1;
        }
    }

    int rc;
    while ((rc = libssh2_channel_exec(channel, command)) == LIBSSH2_ERROR_EAGAIN) {
        if (wait_socket(timeout_ms) <= 0) {
            set_error("ssh exec timeout");
            libssh2_channel_free(channel);
            return -1;
        }
    }
    if (rc != 0) {
        set_error("ssh exec failed: %d", rc);
        libssh2_channel_free(channel);
        return -1;
    }

    char buf[4096];
    for (;;) {
        ssize_t n = libssh2_channel_read_ex(channel, 0, buf, sizeof(buf));
        if (n > 0) {
            append_buf(g_stdout, &g_stdout_len, buf, n);
        }

        ssize_t e = libssh2_channel_read_ex(channel, SSH_EXTENDED_DATA_STDERR, buf, sizeof(buf));
        if (e > 0) {
            append_buf(g_stderr, &g_stderr_len, buf, e);
        }

        if (n == LIBSSH2_ERROR_EAGAIN || e == LIBSSH2_ERROR_EAGAIN) {
            if (wait_socket(timeout_ms) <= 0) {
                set_error("ssh read timeout");
                libssh2_channel_free(channel);
                return -1;
            }
            continue;
        }
        if (n < 0 || e < 0) {
            set_error("ssh read failed");
            libssh2_channel_free(channel);
            return -1;
        }
        if (libssh2_channel_eof(channel)) {
            break;
        }
        if (n == 0 && e == 0 && wait_socket(timeout_ms) <= 0) {
            set_error("ssh read timeout");
            libssh2_channel_free(channel);
            return -1;
        }
    }

    while ((rc = libssh2_channel_close(channel)) == LIBSSH2_ERROR_EAGAIN) {
        wait_socket(timeout_ms);
    }
    int exit_code = libssh2_channel_get_exit_status(channel);
    libssh2_channel_free(channel);
    return exit_code;
}

int cc_ssh_disconnect(void) {
    pthread_mutex_lock(&g_ssh_mutex);
    int rc = cc_ssh_disconnect_unlocked();
    pthread_mutex_unlock(&g_ssh_mutex);
    return rc;
}

static int cc_ssh_disconnect_unlocked(void) {
    if (g_session != NULL) {
        libssh2_session_disconnect(g_session, "normal shutdown");
        libssh2_session_free(g_session);
        g_session = NULL;
    }
    if (g_sock >= 0) {
        close(g_sock);
        g_sock = -1;
    }
    libssh2_exit();
    return 0;
}

const char *cc_ssh_stdout(void) {
    return g_stdout;
}

const char *cc_ssh_stderr(void) {
    return g_stderr;
}

const char *cc_ssh_last_error(void) {
    return g_last_error;
}
