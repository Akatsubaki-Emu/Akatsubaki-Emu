#define _POSIX_C_SOURCE 200809L

#include <stdatomic.h>
#include <time.h>

static atomic_int init_count = 0;
static atomic_int loop_count = 0;
static atomic_int cleanup_count = 0;
static atomic_int stop_requested = 0;

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
}

void qemu_system_shutdown_request(int cause) {
    (void)cause;
    atomic_store(&stop_requested, 1);
}

int fake_qemu_init_count(void) { return atomic_load(&init_count); }
int fake_qemu_loop_count(void) { return atomic_load(&loop_count); }
int fake_qemu_cleanup_count(void) { return atomic_load(&cleanup_count); }
