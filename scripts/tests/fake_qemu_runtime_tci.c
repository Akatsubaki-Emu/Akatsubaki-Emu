#define _POSIX_C_SOURCE 200809L

#include <stdatomic.h>
#include <time.h>

static atomic_int init_count = 0;
static atomic_int loop_count = 0;
static atomic_int cleanup_count = 0;
static atomic_int cleanup_started_count = 0;
static atomic_int cleanup_status = -1;
static atomic_int shutdown_cause = -1;
static atomic_int shutdown_count = 0;
static atomic_int stop_requested = 0;

static void pause_briefly(void) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 1 * 1000 * 1000};
    nanosleep(&delay, NULL);
}

void qemu_init(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    atomic_fetch_add(&init_count, 1);
    for (int i = 0; i < 20; ++i) pause_briefly();
}

int qemu_main_loop(void) {
    atomic_fetch_add(&loop_count, 1);
    while (!atomic_load(&stop_requested)) pause_briefly();
    return 37;
}

void qemu_cleanup(int status) {
    atomic_store(&cleanup_status, status);
    atomic_fetch_add(&cleanup_count, 1);
    atomic_fetch_add(&cleanup_started_count, 1);
    for (int i = 0; i < 100; ++i) pause_briefly();
}

void qemu_system_shutdown_request(int cause) {
    atomic_store(&shutdown_cause, cause);
    atomic_fetch_add(&shutdown_count, 1);
    atomic_store(&stop_requested, 1);
}

int fake_qemu_init_count(void) { return atomic_load(&init_count); }
int fake_qemu_loop_count(void) { return atomic_load(&loop_count); }
int fake_qemu_cleanup_count(void) { return atomic_load(&cleanup_count); }
int fake_qemu_cleanup_started_count(void) { return atomic_load(&cleanup_started_count); }
int fake_qemu_cleanup_status(void) { return atomic_load(&cleanup_status); }
int fake_qemu_shutdown_cause(void) { return atomic_load(&shutdown_cause); }
int fake_qemu_shutdown_count(void) { return atomic_load(&shutdown_count); }
