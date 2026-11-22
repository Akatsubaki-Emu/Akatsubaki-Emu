#define _POSIX_C_SOURCE 200809L

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>


static void record_lifecycle_event(const char *event) {
    const char *path = getenv("FAKE_QEMU_LIFECYCLE_FILE");
    if (!path || !path[0]) return;
    FILE *file = fopen(path, "a");
    if (!file) return;
    fprintf(file, "%s\n", event);
    fclose(file);
}

__attribute__((constructor))
static void fake_qemu_library_loaded(void) {
    record_lifecycle_event("load");
}

__attribute__((destructor))
static void fake_qemu_library_unloaded(void) {
    record_lifecycle_event("unload");
}

static atomic_int init_count = 0;
static atomic_int loop_count = 0;
static atomic_int cleanup_count = 0;
static atomic_int cleanup_started_count = 0;
static atomic_int shutdown_count = 0;
static atomic_int stop_requested = 0;
static atomic_int jit_callbacks_installed = 0;

void isteam_qemu_set_jit_callbacks(bool (*ready)(void), void *(*prepare)(void *, size_t), void (*detach)(void)) {
    if (ready && prepare && detach) atomic_fetch_add(&jit_callbacks_installed, 1);
}
int fake_qemu_jit_callbacks_installed(void) { return atomic_load(&jit_callbacks_installed); }

static void pause_briefly(void) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 1 * 1000 * 1000};
    nanosleep(&delay, NULL);
}

int qemu_init(int argc, const char *argv[], const char *envp[]) {
    (void)argc;
    (void)argv;
    (void)envp;
    atomic_fetch_add(&init_count, 1);
    // Keep initialization open long enough for the competing start caller.
    for (int i = 0; i < 20; ++i) pause_briefly();
    return 0;
}

void qemu_main_loop(void) {
    atomic_fetch_add(&loop_count, 1);
    while (!atomic_load(&stop_requested)) pause_briefly();
}

void qemu_cleanup(void) {
    atomic_fetch_add(&cleanup_count, 1);
    atomic_fetch_add(&cleanup_started_count, 1);
    // Hold the library in cleanup long enough to exercise a concurrent stop.
    for (int i = 0; i < 100; ++i) pause_briefly();
}

void qemu_system_shutdown_request(int cause) {
    (void)cause;
    atomic_fetch_add(&shutdown_count, 1);
    atomic_store(&stop_requested, 1);
}

int fake_qemu_init_count(void) { return atomic_load(&init_count); }
int fake_qemu_loop_count(void) { return atomic_load(&loop_count); }
int fake_qemu_cleanup_count(void) { return atomic_load(&cleanup_count); }
int fake_qemu_cleanup_started_count(void) { return atomic_load(&cleanup_started_count); }
int fake_qemu_shutdown_count(void) { return atomic_load(&shutdown_count); }
