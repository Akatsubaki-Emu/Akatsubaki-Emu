#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "QEMUNativeBridge.h"
#include "JIT26Protocol.h"

#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

bool iSteamJITIsReady(void) { return false; }
void *iSteamJITPrepareRegion(void *address, size_t size) { (void)address; (void)size; return NULL; }
void iSteamJITDetach(void) {}

typedef struct {
    pthread_barrier_t *barrier;
    const char *library;
    bool requires_jit;
    bool started;
    char error[512];
} StartRequest;

static void *start_worker(void *opaque) {
    StartRequest *request = (StartRequest *)opaque;
    const char *arguments[] = {"qemu-system-x86_64"};
    int barrier_result = pthread_barrier_wait(request->barrier);
    assert(barrier_result == 0 || barrier_result == PTHREAD_BARRIER_SERIAL_THREAD);
    request->started = isteam_qemu_start(1, arguments, request->library,
                                         request->requires_jit, request->error,
                                         (int)sizeof(request->error));
    return NULL;
}

static void wait_for_state(bool active) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 5 * 1000 * 1000};
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (isteam_qemu_is_active() == active) return;
        nanosleep(&delay, NULL);
    }
    assert(0 && "QEMU bridge did not reach the expected lifecycle state");
}

static int read_counter(void *handle, const char *symbol) {
    int (*read_value)(void) = (int (*)(void))dlsym(handle, symbol);
    assert(read_value != NULL);
    return read_value();
}

static void wait_for_counter(void *handle, const char *symbol, int expected) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 5 * 1000 * 1000};
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (read_counter(handle, symbol) >= expected) return;
        nanosleep(&delay, NULL);
    }
    assert(0 && "QEMU fake runtime did not reach the expected cleanup state");
}

int main(int argc, char **argv) {
    assert(argc == 3);
    const bool requires_jit = strcmp(argv[1], "jit") == 0;
    assert(requires_jit || strcmp(argv[1], "tci") == 0);
    const char *library = argv[2];

    void *probe = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    assert(probe != NULL);
    char validation_error[512] = {0};
    assert(isteam_qemu_validate_library(library, requires_jit,
                                        validation_error, (int)sizeof(validation_error)));
    if (!requires_jit) {
        memset(validation_error, 0, sizeof(validation_error));
        assert(!isteam_qemu_validate_library(library, true,
                                             validation_error, (int)sizeof(validation_error)));
        assert(strstr(validation_error, "isteam_qemu_set_jit_callbacks") != NULL);
        assert(dlsym(probe, "isteam_qemu_set_jit_callbacks") == NULL);
    } else {
        assert(read_counter(probe, "fake_qemu_jit_callbacks_installed") == 0);
    }

    char argumentError[512] = {0};
    const char *tooManyArguments[4097];
    for (size_t index = 0; index < sizeof(tooManyArguments) / sizeof(tooManyArguments[0]); ++index) {
        tooManyArguments[index] = "argument";
    }
    assert(!isteam_qemu_start(4097, tooManyArguments, library, requires_jit,
                              argumentError, (int)sizeof(argumentError)));
    assert(strstr(argumentError, "too many arguments") != NULL);

    char *oversizedArgument = malloc(1024 * 1024 + 2);
    assert(oversizedArgument != NULL);
    memset(oversizedArgument, 'x', 1024 * 1024 + 1);
    oversizedArgument[1024 * 1024 + 1] = '\0';
    const char *oversizedArguments[] = {oversizedArgument};
    memset(argumentError, 0, sizeof(argumentError));
    assert(!isteam_qemu_start(1, oversizedArguments, library, requires_jit,
                              argumentError, (int)sizeof(argumentError)));
    assert(strstr(argumentError, "QEMU arguments exceed the configured size limits") != NULL);
    free(oversizedArgument);

    pthread_barrier_t barrier;
    assert(pthread_barrier_init(&barrier, NULL, 3) == 0);
    StartRequest first = {.barrier = &barrier, .library = library,
                          .requires_jit = requires_jit, .started = false, .error = {0}};
    StartRequest second = {.barrier = &barrier, .library = library,
                           .requires_jit = requires_jit, .started = false, .error = {0}};
    pthread_t first_thread, second_thread;
    assert(pthread_create(&first_thread, NULL, start_worker, &first) == 0);
    assert(pthread_create(&second_thread, NULL, start_worker, &second) == 0);
    int barrier_result = pthread_barrier_wait(&barrier);
    assert(barrier_result == 0 || barrier_result == PTHREAD_BARRIER_SERIAL_THREAD);
    assert(pthread_join(first_thread, NULL) == 0);
    assert(pthread_join(second_thread, NULL) == 0);
    assert(pthread_barrier_destroy(&barrier) == 0);

    // Exactly one simultaneous caller may reserve the process-global QEMU session.
    assert(first.started != second.started);
    assert(isteam_qemu_is_active());
    const struct timespec running_delay = {.tv_sec = 0, .tv_nsec = 5 * 1000 * 1000};
    for (int attempt = 0; attempt < 400 && !isteam_qemu_is_running(); ++attempt) {
        nanosleep(&running_delay, NULL);
    }
    assert(isteam_qemu_is_running());
    if (requires_jit) {
        assert(read_counter(probe, "fake_qemu_jit_callbacks_installed") == 1);
    } else {
        assert(dlsym(probe, "fake_qemu_jit_callbacks_installed") == NULL);
    }

    isteam_qemu_request_stop();
    wait_for_counter(probe, "fake_qemu_cleanup_started_count", 1);
    isteam_qemu_request_stop();
    assert(read_counter(probe, "fake_qemu_shutdown_count") == 1);
    wait_for_state(false);
    assert(!isteam_qemu_is_running());
    assert(read_counter(probe, "fake_qemu_init_count") == 1);
    assert(read_counter(probe, "fake_qemu_loop_count") == 1);
    assert(read_counter(probe, "fake_qemu_cleanup_count") == 1);
    assert(read_counter(probe, "fake_qemu_cleanup_status") == 37);
    assert(read_counter(probe, "fake_qemu_shutdown_cause") == 5);
    assert(read_counter(probe, "fake_qemu_shutdown_count") == 1);

    char error[512] = {0};
    const char *arguments[] = {"qemu-system-x86_64"};
    assert(!isteam_qemu_start(1, arguments, library, requires_jit,
                              error, (int)sizeof(error)));
    assert(strstr(error, "cannot safely restart") != NULL);

    dlclose(probe);
    printf("QEMU native bridge %s mode lifecycle, concurrency and argument bounds passed.\n", argv[1]);
    return 0;
}
