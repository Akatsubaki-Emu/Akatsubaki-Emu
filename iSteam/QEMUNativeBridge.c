/*
 * UTM QEMU lifecycle integration reference:
 * https://github.com/utmapp/UTM/blob/main/Services/UTMQemuSystem.m
 *
 * Adapted for Akatsubaki Emu. Copyright (c) 2026 Akatsubaki Emu contributors.
 * UTM reference implementation is licensed under Apache-2.0.
 * See THIRD_PARTY_NOTICES.md for attribution and license information.
 */
#define _POSIX_C_SOURCE 200809L
#include "QEMUNativeBridge.h"
#include "JIT26Protocol.h"
#include <dlfcn.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

#define ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI 5
#define ISTEAM_QEMU_MAX_ARGUMENTS 4096
#define ISTEAM_QEMU_MAX_ARGUMENT_BYTES (1024u * 1024u)
#define ISTEAM_QEMU_MAX_TOTAL_ARGUMENT_BYTES (8u * 1024u * 1024u)

/* QEMU 10.0.12 declares qemu_init(int, char **) as void. */
typedef void (*qemu_init_fn)(int, char **);
typedef int (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(int);
typedef void (*qemu_shutdown_request_fn)(int);
typedef void (*qemu_set_jit_callbacks_fn)(bool (*)(void), void *(*)(void *, size_t), void (*)(void));

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void *g_library = NULL;
static pthread_t g_thread;
static bool g_thread_created = false;
static bool g_starting = false;
static bool g_running = false;
static bool g_stop_requested = false;
static atomic_bool g_main_loop_active = ATOMIC_VAR_INIT(false);
/* QEMU is initialized once per app process and controlled/rebooted through QMP. */
static bool g_has_started = false;
static char g_error[512] = {0};
static int g_argc = 0;
static char **g_argv = NULL;
static char *g_argument_storage = NULL;
static qemu_init_fn g_qemu_init = NULL;
static qemu_main_loop_fn g_qemu_main_loop = NULL;
static qemu_cleanup_fn g_qemu_cleanup = NULL;
static qemu_shutdown_request_fn g_qemu_shutdown = NULL;

static void clear_starting(void) {
    pthread_mutex_lock(&g_lock);
    g_starting = false;
    pthread_mutex_unlock(&g_lock);
}

static void release_arguments(void) {
    free(g_argument_storage);
    free(g_argv);
    g_argument_storage = NULL;
    g_argv = NULL;
    g_argc = 0;
}

static void *qemu_thread_main(void *unused) {
    (void)unused;
    g_qemu_init(g_argc, g_argv);

    pthread_mutex_lock(&g_lock);
    g_running = true;
    atomic_store(&g_main_loop_active, true);
    bool stop_after_init = g_stop_requested;
    qemu_shutdown_request_fn shutdown_fn = g_qemu_shutdown;
    pthread_mutex_unlock(&g_lock);
    if (stop_after_init && shutdown_fn) shutdown_fn(ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI);
    int qemu_exit_status = g_qemu_main_loop();

    // Clear the callable state before waiting on the lifecycle mutex.
    atomic_store(&g_main_loop_active, false);
    pthread_mutex_lock(&g_lock);
    g_running = false;
    pthread_mutex_unlock(&g_lock);
    if (g_qemu_cleanup) g_qemu_cleanup(qemu_exit_status);

    pthread_mutex_lock(&g_lock);
    g_running = false;
    g_thread_created = false;
    g_stop_requested = false;
    release_arguments();
    void *finished_library = g_library;
    g_library = NULL;
    g_qemu_init = NULL;
    g_qemu_main_loop = NULL;
    g_qemu_cleanup = NULL;
    g_qemu_shutdown = NULL;
    pthread_mutex_unlock(&g_lock);

    if (finished_library) dlclose(finished_library);
    return NULL;
}

bool isteam_qemu_validate_library(const char *library_path, bool requires_jit,
                                  char *error_buffer, int error_capacity) {
    if (!library_path || !library_path[0]) {
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity, "QEMU library path is empty");
        return false;
    }

    /* RTLD_NOW validates transitive load dependencies as well as the image. */
    void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char *reason = dlerror();
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity,
                     "Could not load bundled QEMU or one of its dependencies: %s",
                     reason ? reason : "unknown loader error");
        return false;
    }

    bool has_init = dlsym(library, "qemu_init") != NULL;
    bool has_main_loop = dlsym(library, "qemu_main_loop") != NULL;
    bool has_cleanup = dlsym(library, "qemu_cleanup") != NULL;
    bool has_shutdown = dlsym(library, "qemu_system_shutdown_request") != NULL;
    bool has_jit_callbacks = dlsym(library, "isteam_qemu_set_jit_callbacks") != NULL;
    dlclose(library);

    if (!has_init || !has_main_loop || !has_cleanup || !has_shutdown) {
        if (error_buffer && error_capacity > 0) {
            snprintf(error_buffer, (size_t)error_capacity,
                     "QEMU library is missing required lifecycle exports: %s%s%s%s",
                     has_init ? "" : "qemu_init ",
                     has_main_loop ? "" : "qemu_main_loop ",
                     has_cleanup ? "" : "qemu_cleanup ",
                     has_shutdown ? "" : "qemu_system_shutdown_request");
        }
        return false;
    }
    bool jit_mode_matches = requires_jit == has_jit_callbacks;
    if (!jit_mode_matches) {
        if (error_buffer && error_capacity > 0) {
            snprintf(error_buffer, (size_t)error_capacity,
                     "QEMU runtime mode mismatch: %s runtime %s export isteam_qemu_set_jit_callbacks",
                     requires_jit ? "JIT" : "TCI",
                     requires_jit ? "must" : "must not");
        }
        return false;
    }

    if (error_buffer && error_capacity > 0) error_buffer[0] = '\0';
    return true;
}

bool isteam_qemu_start(int argc, const char * const *argv,
                       const char *library_path, bool requires_jit,
                       char *error_buffer, int error_capacity) {
    if (argc < 1 || argc > ISTEAM_QEMU_MAX_ARGUMENTS || !argv || !library_path || !library_path[0]) {
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Invalid QEMU launch arguments or too many arguments");
        return false;
    }

    size_t total_argument_bytes = 0;
    for (int i = 0; i < argc; ++i) {
        if (!argv[i]) {
            if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "QEMU argument %d is null", i);
            return false;
        }
        const size_t argument_length = strnlen(argv[i], ISTEAM_QEMU_MAX_ARGUMENT_BYTES + 1u);
        if (argument_length > ISTEAM_QEMU_MAX_ARGUMENT_BYTES
            || total_argument_bytes > ISTEAM_QEMU_MAX_TOTAL_ARGUMENT_BYTES - (argument_length + 1u)) {
            if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "QEMU arguments exceed the configured size limits");
            return false;
        }
        total_argument_bytes += argument_length + 1u;
    }

    pthread_mutex_lock(&g_lock);
    if (g_has_started) {
        pthread_mutex_unlock(&g_lock);
        if (error_buffer && error_capacity > 0) {
            snprintf(error_buffer, (size_t)error_capacity,
                     "A QEMU runtime is already initialized and cannot safely restart in this app process; reuse it through the local QMP control socket.");
        }
        return false;
    }
    if (g_starting || g_thread_created || g_running) {
        pthread_mutex_unlock(&g_lock);
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "A QEMU session is already active or starting");
        return false;
    }
    // Reserve the one-shot lifecycle before dlopen/argv allocation. Without
    // this reservation two simultaneous callers can both pass the checks and
    // overwrite process-global QEMU state before either worker is created.
    g_starting = true;
    g_error[0] = '\0';
    g_stop_requested = false;
    pthread_mutex_unlock(&g_lock);

    void *library = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        const char *reason = dlerror();
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Could not load bundled QEMU: %s", reason ? reason : "unknown loader error");
        clear_starting();
        return false;
    }

    qemu_init_fn init_fn = (qemu_init_fn)dlsym(library, "qemu_init");
    qemu_main_loop_fn loop_fn = (qemu_main_loop_fn)dlsym(library, "qemu_main_loop");
    qemu_cleanup_fn cleanup_fn = (qemu_cleanup_fn)dlsym(library, "qemu_cleanup");
    qemu_shutdown_request_fn shutdown_fn = (qemu_shutdown_request_fn)dlsym(library, "qemu_system_shutdown_request");
    qemu_set_jit_callbacks_fn set_jit_callbacks = (qemu_set_jit_callbacks_fn)dlsym(library, "isteam_qemu_set_jit_callbacks");
    bool has_jit_callbacks = set_jit_callbacks != NULL;
    if (!init_fn || !loop_fn || !cleanup_fn || !shutdown_fn) {
        dlclose(library);
        if (error_buffer && error_capacity > 0) {
            snprintf(error_buffer, (size_t)error_capacity,
                     "QEMU library lacks required lifecycle exports (qemu_init, qemu_main_loop, qemu_cleanup, qemu_system_shutdown_request)");
        }
        clear_starting();
        return false;
    }
    bool jit_mode_matches = requires_jit == has_jit_callbacks;
    if (!jit_mode_matches) {
        dlclose(library);
        if (error_buffer && error_capacity > 0) {
            snprintf(error_buffer, (size_t)error_capacity,
                     "QEMU runtime mode mismatch: %s runtime %s export isteam_qemu_set_jit_callbacks",
                     requires_jit ? "JIT" : "TCI",
                     requires_jit ? "must" : "must not");
        }
        clear_starting();
        return false;
    }
    if (requires_jit) {
        set_jit_callbacks(iSteamJITIsReady, iSteamJITPrepareRegion, iSteamJITDetach);
    }

    char **copied_argv = calloc((size_t)argc + 1, sizeof(char *));
    char *argument_storage = malloc(total_argument_bytes);
    if (!copied_argv || !argument_storage) {
        free(copied_argv);
        free(argument_storage);
        dlclose(library);
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Out of memory preparing QEMU arguments");
        clear_starting();
        return false;
    }
    size_t argument_offset = 0;
    for (int i = 0; i < argc; ++i) {
        const size_t argument_length = strnlen(argv[i], ISTEAM_QEMU_MAX_ARGUMENT_BYTES + 1u);
        if (argument_length > ISTEAM_QEMU_MAX_ARGUMENT_BYTES
            || argument_offset > total_argument_bytes
            || argument_length + 1u > total_argument_bytes - argument_offset) {
            free(argument_storage);
            free(copied_argv);
            dlclose(library);
            if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "QEMU arguments changed while preparing the launch");
            clear_starting();
            return false;
        }
        copied_argv[i] = argument_storage + argument_offset;
        memcpy(copied_argv[i], argv[i], argument_length + 1u);
        argument_offset += argument_length + 1u;
    }

    pthread_mutex_lock(&g_lock);
    g_library = library;
    g_qemu_init = init_fn;
    g_qemu_main_loop = loop_fn;
    g_qemu_cleanup = cleanup_fn;
    g_qemu_shutdown = shutdown_fn;
    g_argc = argc;
    g_argv = copied_argv;
    g_argument_storage = argument_storage;
    g_thread_created = true;
    int result = pthread_create(&g_thread, NULL, qemu_thread_main, NULL);
    if (result != 0) {
        g_thread_created = false;
        g_starting = false;
        g_library = NULL;
        g_qemu_init = NULL;
        g_qemu_main_loop = NULL;
        g_qemu_cleanup = NULL;
        g_qemu_shutdown = NULL;
        g_argc = 0;
        g_argv = NULL;
        g_argument_storage = NULL;
        pthread_mutex_unlock(&g_lock);
        free(argument_storage);
        free(copied_argv);
        dlclose(library);
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Could not create QEMU worker thread");
        return false;
    }
    g_starting = false;
    g_has_started = true;
    pthread_detach(g_thread);
    pthread_mutex_unlock(&g_lock);
    return true;
}

static bool qmp_write_all(int fd, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
#ifdef MSG_NOSIGNAL
        const int send_flags = MSG_NOSIGNAL;
#else
        const int send_flags = 0;
#endif
        ssize_t written = send(fd, bytes + offset, length - offset, send_flags);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        offset += (size_t)written;
    }
    return true;
}

static bool qmp_read_line(int fd, char *buffer, size_t capacity) {
    if (!buffer || capacity < 2) return false;
    size_t length = 0;
    while (length + 1 < capacity) {
        char byte = 0;
        ssize_t received = recv(fd, &byte, 1, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return false;
        if (byte == '\n') break;
        if (byte != '\r') buffer[length++] = byte;
    }
    buffer[length] = '\0';
    return length > 0;
}

static bool qmp_read_return(int fd, char *buffer, size_t capacity) {
    for (int attempt = 0; attempt < 16; ++attempt) {
        if (!qmp_read_line(fd, buffer, capacity)) return false;
        if (strstr(buffer, "\"error\"")) return false;
        if (strstr(buffer, "\"return\"")) return true;
        // QMP events may be interleaved with command replies.
    }
    return false;
}

static bool qmp_send_command(int fd, const char *command, char *response, size_t response_capacity) {
    char line[128];
    const int length = snprintf(line, sizeof(line), "{\"execute\":\"%s\"}\r\n", command);
    if (length <= 0 || (size_t)length >= sizeof(line)) return false;
    return qmp_write_all(fd, line, (size_t)length)
        && qmp_read_return(fd, response, response_capacity);
}

bool isteam_qemu_qmp_command(const char *socket_path, const char *command,
                             char *error_buffer, int error_capacity) {
    if (!socket_path || !socket_path[0] || !command
        || (strcmp(command, "stop") != 0
            && strcmp(command, "cont") != 0
            && strcmp(command, "system_reset") != 0
            && strcmp(command, "query-status") != 0)) {
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity, "Invalid QMP socket path or unsupported command");
        return false;
    }

    pthread_mutex_lock(&g_lock);
    const bool active = g_thread_created || g_running;
    pthread_mutex_unlock(&g_lock);
    if (!active) {
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity, "QEMU runtime is not active");
        return false;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    const size_t path_length = strnlen(socket_path, sizeof(address.sun_path));
    if (path_length == 0 || path_length >= sizeof(address.sun_path)) {
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity, "QMP socket path is too long");
        return false;
    }
    memcpy(address.sun_path, socket_path, path_length + 1);
#if defined(__APPLE__)
    address.sun_len = (uint8_t)sizeof(address);
#endif

    int fd = -1;
    for (int attempt = 0; attempt < 20; ++attempt) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) break;
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) break;
        close(fd);
        fd = -1;
        struct timespec delay = {0, 100 * 1000 * 1000};
        nanosleep(&delay, NULL);
    }
    if (fd < 0) {
        if (error_buffer && error_capacity > 0)
            snprintf(error_buffer, (size_t)error_capacity, "Could not connect to the local QEMU control socket");
        return false;
    }

    struct timeval timeout = {2, 0};
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
#if defined(SO_NOSIGPIPE)
    int no_sigpipe = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
#endif
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    char response[4096] = {0};
    bool success = qmp_read_line(fd, response, sizeof(response)); // QMP greeting.
    if (success) success = qmp_send_command(fd, "qmp_capabilities", response, sizeof(response));
    if (success) success = qmp_send_command(fd, command, response, sizeof(response));
    close(fd);

    if (!success && error_buffer && error_capacity > 0) {
        snprintf(error_buffer, (size_t)error_capacity, "QEMU QMP command '%s' failed: %.360s",
                 command, response[0] ? response : "no response from QMP");
    } else if (error_buffer && error_capacity > 0) {
        error_buffer[0] = '\0';
    }
    return success;
}

void isteam_qemu_request_stop(void) {
    pthread_mutex_lock(&g_lock);
    const bool active = g_thread_created || g_running;
    const bool main_loop_active = atomic_load(&g_main_loop_active);
    if (active && !main_loop_active) {
        g_stop_requested = true;
    } else if (active && g_qemu_shutdown) {
        // Keep the library loaded while calling its function pointer. The
        // worker must acquire this mutex before clearing the pointer/dlclose.
        g_qemu_shutdown(ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI);
    } else if (active) {
        snprintf(g_error, sizeof(g_error),
                 "This QEMU build does not export qemu_system_shutdown_request; graceful stop is unavailable.");
    }
    pthread_mutex_unlock(&g_lock);
}

bool isteam_qemu_is_running(void) {
    pthread_mutex_lock(&g_lock);
    bool value = g_running;
    pthread_mutex_unlock(&g_lock);
    return value;
}

bool isteam_qemu_is_active(void) {
    pthread_mutex_lock(&g_lock);
    bool value = g_thread_created || g_running;
    pthread_mutex_unlock(&g_lock);
    return value;
}

const char *isteam_qemu_last_error(void) {
    static _Thread_local char error_copy[sizeof(g_error)];
    pthread_mutex_lock(&g_lock);
    memcpy(error_copy, g_error, sizeof(error_copy));
    pthread_mutex_unlock(&g_lock);
    error_copy[sizeof(error_copy) - 1] = '\0';
    return error_copy;
}
