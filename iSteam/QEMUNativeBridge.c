/*
 * UTM QEMU lifecycle integration reference:
 * https://github.com/utmapp/UTM/blob/main/Services/UTMQemuSystem.m
 *
 * Adapted for i-Steam. Copyright (c) 2026 i-Steam contributors.
 * UTM reference implementation is licensed under Apache-2.0.
 * See THIRD_PARTY_NOTICES.md for attribution and license information.
 */
#define _POSIX_C_SOURCE 200809L
#include "QEMUNativeBridge.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>

extern char **environ;
#define ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI 4
#define ISTEAM_QEMU_MAX_ARGUMENTS 4096
#define ISTEAM_QEMU_MAX_ARGUMENT_BYTES (1024u * 1024u)
#define ISTEAM_QEMU_MAX_TOTAL_ARGUMENT_BYTES (8u * 1024u * 1024u)

typedef int (*qemu_init_fn)(int, const char *[], const char *[]);
typedef void (*qemu_main_loop_fn)(void);
typedef void (*qemu_cleanup_fn)(void);
typedef void (*qemu_shutdown_request_fn)(int);

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void *g_library = NULL;
static pthread_t g_thread;
static bool g_thread_created = false;
static bool g_starting = false;
static bool g_running = false;
static bool g_stop_requested = false;
static atomic_bool g_main_loop_active = ATOMIC_VAR_INIT(false);
/* UTM documents that QEMU cannot safely be relaunched in the same iOS process. */
static bool g_has_started = false;
static char g_error[512] = {0};
static int g_argc = 0;
static char **g_argv = NULL;
static qemu_init_fn g_qemu_init = NULL;
static qemu_main_loop_fn g_qemu_main_loop = NULL;
static qemu_cleanup_fn g_qemu_cleanup = NULL;
static qemu_shutdown_request_fn g_qemu_shutdown = NULL;

static void set_error(const char *message) {
    pthread_mutex_lock(&g_lock);
    snprintf(g_error, sizeof(g_error), "%s", message ? message : "Unknown QEMU error");
    pthread_mutex_unlock(&g_lock);
}

static void clear_starting(void) {
    pthread_mutex_lock(&g_lock);
    g_starting = false;
    pthread_mutex_unlock(&g_lock);
}

static void release_arguments(void) {
    if (!g_argv) return;
    for (int i = 0; i < g_argc; ++i) free(g_argv[i]);
    free(g_argv);
    g_argv = NULL;
    g_argc = 0;
}

static void *qemu_thread_main(void *unused) {
    (void)unused;
    int init_result = g_qemu_init(g_argc, (const char **)g_argv,
                                  (const char **)environ);
    if (init_result != 0) {
        char message[128];
        snprintf(message, sizeof(message), "QEMU initialization failed with status %d", init_result);
        set_error(message);
    } else {
        pthread_mutex_lock(&g_lock);
        g_running = true;
        atomic_store(&g_main_loop_active, true);
        bool stop_after_init = g_stop_requested;
        qemu_shutdown_request_fn shutdown_fn = g_qemu_shutdown;
        pthread_mutex_unlock(&g_lock);
        if (stop_after_init && shutdown_fn) shutdown_fn(ISTEAM_QEMU_SHUTDOWN_CAUSE_HOST_UI);
        g_qemu_main_loop();

        // Clear the callable state before waiting on the lifecycle mutex.
        atomic_store(&g_main_loop_active, false);
        pthread_mutex_lock(&g_lock);
        g_running = false;
        pthread_mutex_unlock(&g_lock);
        if (g_qemu_cleanup) g_qemu_cleanup();
    }

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

bool isteam_qemu_validate_library(const char *library_path,
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

    if (error_buffer && error_capacity > 0) error_buffer[0] = '\0';
    return true;
}

bool isteam_qemu_start(int argc, const char * const *argv,
                       const char *library_path, char *error_buffer, int error_capacity) {
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
                     "UTM's iOS QEMU runtime cannot safely restart in the same app process. Force-quit and reopen i-Steam before starting another VM.");
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
    if (!init_fn || !loop_fn || !cleanup_fn || !shutdown_fn) {
        dlclose(library);
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "QEMU library lacks required lifecycle exports (qemu_init, qemu_main_loop, qemu_cleanup, qemu_system_shutdown_request)");
        clear_starting();
        return false;
    }

    char **copied_argv = calloc((size_t)argc + 1, sizeof(char *));
    if (!copied_argv) {
        dlclose(library);
        if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Out of memory preparing QEMU arguments");
        clear_starting();
        return false;
    }
    for (int i = 0; i < argc; ++i) {
        const char *argument = argv[i] ? argv[i] : "";
        size_t argument_length = strlen(argument);
        copied_argv[i] = malloc(argument_length + 1);
        if (!copied_argv[i]) {
            for (int j = 0; j < i; ++j) free(copied_argv[j]);
            free(copied_argv);
            dlclose(library);
            if (error_buffer && error_capacity > 0) snprintf(error_buffer, (size_t)error_capacity, "Out of memory copying QEMU arguments");
            clear_starting();
            return false;
        }
        memcpy(copied_argv[i], argument, argument_length + 1);
    }

    pthread_mutex_lock(&g_lock);
    g_library = library;
    g_qemu_init = init_fn;
    g_qemu_main_loop = loop_fn;
    g_qemu_cleanup = cleanup_fn;
    g_qemu_shutdown = shutdown_fn;
    g_argc = argc;
    g_argv = copied_argv;
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
        pthread_mutex_unlock(&g_lock);
        for (int i = 0; i < argc; ++i) free(copied_argv[i]);
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
