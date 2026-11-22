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
#include <unistd.h>

bool iSteamJITIsReady(void) { return false; }
void *iSteamJITPrepareRegion(void *address, size_t size) { (void)address; (void)size; return NULL; }
void iSteamJITDetach(void) {}

typedef struct {
    pthread_barrier_t *barrier;
    const char *library;
    bool started;
    char error[512];
} StartRequest;

static void *start_worker(void *opaque) {
    StartRequest *request = (StartRequest *)opaque;
    const char *arguments[] = {"qemu-system-x86_64"};
    int barrier_result = pthread_barrier_wait(request->barrier);
    assert(barrier_result == 0 || barrier_result == PTHREAD_BARRIER_SERIAL_THREAD);
    request->started = isteam_qemu_start(1, arguments, request->library,
                                         request->error, (int)sizeof(request->error));
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


static int count_lifecycle_event(const char *path, const char *event) {
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char line[32];
    int count = 0;
    while (fgets(line, sizeof(line), file)) {
        if (strncmp(line, event, strlen(event)) == 0) count++;
    }
    fclose(file);
    return count;
}

static void wait_for_lifecycle_event(const char *path, const char *event, int expected) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 5 * 1000 * 1000};
    for (int attempt = 0; attempt < 400; ++attempt) {
        if (count_lifecycle_event(path, event) >= expected) return;
        nanosleep(&delay, NULL);
    }
    assert(0 && "QEMU fake runtime did not reach the expected loader lifecycle event");
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
    assert(argc == 2);
    char lifecycle_path[] = "/tmp/isteam-qemu-lifecycle-XXXXXX";
    int lifecycle_fd = mkstemp(lifecycle_path);
    assert(lifecycle_fd >= 0);
    assert(close(lifecycle_fd) == 0);
    assert(unlink(lifecycle_path) == 0);
    assert(setenv("FAKE_QEMU_LIFECYCLE_FILE", lifecycle_path, 1) == 0);

    void *probe = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(probe != NULL);
    assert(count_lifecycle_event(lifecycle_path, "load") == 1);
    char validation_error[512] = {0};
    assert(isteam_qemu_validate_library(argv[1], validation_error, (int)sizeof(validation_error)));
    assert(isteam_qemu_validate_library(argv[1], validation_error, (int)sizeof(validation_error)));
    assert(count_lifecycle_event(lifecycle_path, "load") == 1);
    assert(dlclose(probe) == 0);
    probe = NULL;
    assert(count_lifecycle_event(lifecycle_path, "unload") == 0);

    char argumentError[512] = {0};
    const char *tooManyArguments[4097];
    for (size_t index = 0; index < sizeof(tooManyArguments) / sizeof(tooManyArguments[0]); ++index) {
        tooManyArguments[index] = "argument";
    }
    assert(!isteam_qemu_start(4097, tooManyArguments, argv[1],
                              argumentError, (int)sizeof(argumentError)));
    assert(strstr(argumentError, "too many arguments") != NULL);

    char *oversizedArgument = malloc(1024 * 1024 + 2);
    assert(oversizedArgument != NULL);
    memset(oversizedArgument, 'x', 1024 * 1024 + 1);
    oversizedArgument[1024 * 1024 + 1] = '\0';
    const char *oversizedArguments[] = {oversizedArgument};
    memset(argumentError, 0, sizeof(argumentError));
    assert(!isteam_qemu_start(1, oversizedArguments, argv[1],
                              argumentError, (int)sizeof(argumentError)));
    assert(strstr(argumentError, "QEMU arguments exceed the configured size limits") != NULL);
    free(oversizedArgument);

    pthread_barrier_t barrier;
    assert(pthread_barrier_init(&barrier, NULL, 3) == 0);
    StartRequest first = {.barrier = &barrier, .library = argv[1], .started = false, .error = {0}};
    StartRequest second = {.barrier = &barrier, .library = argv[1], .started = false, .error = {0}};
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
    probe = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(probe != NULL);
    assert(count_lifecycle_event(lifecycle_path, "load") == 1);
    assert(isteam_qemu_is_active());
    const struct timespec running_delay = {.tv_sec = 0, .tv_nsec = 5 * 1000 * 1000};
    for (int attempt = 0; attempt < 400 && !isteam_qemu_is_running(); ++attempt) {
        nanosleep(&running_delay, NULL);
    }
    assert(isteam_qemu_is_running());
    assert(read_counter(probe, "fake_qemu_jit_callbacks_installed") == 1);

    isteam_qemu_request_stop();
    wait_for_counter(probe, "fake_qemu_cleanup_started_count", 1);
    isteam_qemu_request_stop();
    assert(read_counter(probe, "fake_qemu_shutdown_count") == 1);
    wait_for_state(false);
    assert(!isteam_qemu_is_running());
    assert(read_counter(probe, "fake_qemu_init_count") == 1);
    assert(read_counter(probe, "fake_qemu_loop_count") == 1);
    assert(read_counter(probe, "fake_qemu_cleanup_count") == 1);
    assert(read_counter(probe, "fake_qemu_shutdown_count") == 1);

    char error[512] = {0};
    const char *arguments[] = {"qemu-system-x86_64"};
    assert(!isteam_qemu_start(1, arguments, argv[1], error, (int)sizeof(error)));
    assert(strstr(error, "cannot safely restart") != NULL);

    assert(dlclose(probe) == 0);
    wait_for_lifecycle_event(lifecycle_path, "unload", 1);
    assert(count_lifecycle_event(lifecycle_path, "load") == 1);
    assert(count_lifecycle_event(lifecycle_path, "unload") == 1);
    assert(unlink(lifecycle_path) == 0);
    puts("QEMU native bridge concurrency, argument bounds, cleanup race, preflight handle reuse and one-shot lifecycle tests passed.");
    return 0;
}
