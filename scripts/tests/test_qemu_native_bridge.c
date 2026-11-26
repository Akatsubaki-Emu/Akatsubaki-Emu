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
#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
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

typedef struct {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    const char **commands;
    size_t command_count;
} QMPServer;

static bool qmp_test_send_all(int fd, const char *bytes, size_t length) {
    size_t offset = 0;
    while (offset < length) {
#ifdef MSG_NOSIGNAL
        const int flags = MSG_NOSIGNAL;
#else
        const int flags = 0;
#endif
        ssize_t sent = send(fd, bytes + offset, length - offset, flags);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return false;
        offset += (size_t)sent;
    }
    return true;
}

static bool qmp_test_read_line(int fd, char *buffer, size_t capacity) {
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

static void *qmp_test_server(void *opaque) {
    QMPServer *server = (QMPServer *)opaque;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(listener >= 0);
    (void)unlink(server->path);

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
#if defined(__APPLE__)
    address.sun_len = (uint8_t)sizeof(address);
#endif
    const size_t path_length = strlen(server->path);
    assert(path_length > 0 && path_length < sizeof(address.sun_path));
    memcpy(address.sun_path, server->path, path_length + 1);
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 4) == 0);

    const char greeting[] = "{\"QMP\":{\"version\":{\"package\":\"fake-qemu\"},\"capabilities\":[]}}\r\n";
    const char capability_reply[] = "{\"return\":{}}\r\n";
    const char event_and_reply[] = "{\"event\":\"STOP\",\"data\":{}}\r\n{\"return\":{}}\r\n";
    for (size_t index = 0; index < server->command_count; ++index) {
        int client = accept(listener, NULL, NULL);
        assert(client >= 0);
        char line[512] = {0};
        assert(qmp_test_send_all(client, greeting, sizeof(greeting) - 1));
        assert(qmp_test_read_line(client, line, sizeof(line)));
        assert(strstr(line, "\"qmp_capabilities\"") != NULL);
        assert(qmp_test_send_all(client, capability_reply, sizeof(capability_reply) - 1));
        memset(line, 0, sizeof(line));
        assert(qmp_test_read_line(client, line, sizeof(line)));
        assert(strstr(line, server->commands[index]) != NULL);
        // QMP events may arrive before a command's return object.
        assert(qmp_test_send_all(client, event_and_reply, sizeof(event_and_reply) - 1));
        close(client);
    }
    close(listener);
    return NULL;
}


int main(int argc, char **argv) {
    assert(argc == 3);
    const bool reject_jit_in_tci = strcmp(argv[1], "tci-reject-jit") == 0;
    const bool requires_jit = strcmp(argv[1], "jit") == 0;
    assert(requires_jit || strcmp(argv[1], "tci") == 0 || reject_jit_in_tci);
    const char *library = argv[2];

    // QMP accepts only the small control surface used by the runtime. Reject
    // arbitrary commands before opening a local socket.
    char qmp_error[512] = {0};
    assert(!isteam_qemu_qmp_command("/tmp/not-a-qmp-socket", "quit",
                                    qmp_error, (int)sizeof(qmp_error)));
    assert(strstr(qmp_error, "unsupported command") != NULL);

    void *probe = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    assert(probe != NULL);
    char validation_error[512] = {0};
    if (reject_jit_in_tci) {
        const char *arguments[] = {"qemu-system-x86_64"};
        assert(!isteam_qemu_validate_library(library, false,
                                             validation_error, (int)sizeof(validation_error)));
        assert(strstr(validation_error, "TCI runtime must not export isteam_qemu_set_jit_callbacks") != NULL);
        memset(validation_error, 0, sizeof(validation_error));
        assert(!isteam_qemu_start(1, arguments, library, false,
                                  validation_error, (int)sizeof(validation_error)));
        assert(strstr(validation_error, "TCI runtime must not export isteam_qemu_set_jit_callbacks") != NULL);
        dlclose(probe);
        printf("QEMU native bridge rejected a JIT callback export in TCI mode.\n");
        return 0;
    }
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

    // The native client must reject AF_UNIX paths that cannot fit in sun_path.
    char tooLongSocketPath[sizeof(((struct sockaddr_un *)0)->sun_path) + 1];
    memset(tooLongSocketPath, 'x', sizeof(tooLongSocketPath) - 1);
    tooLongSocketPath[sizeof(tooLongSocketPath) - 1] = '\0';
    memset(qmp_error, 0, sizeof(qmp_error));
    assert(!isteam_qemu_qmp_command(tooLongSocketPath, "query-status",
                                    qmp_error, (int)sizeof(qmp_error)));
    assert(strstr(qmp_error, "too long") != NULL);

    // Exercise the real QMP greeting, qmp_capabilities handshake, command
    // request, interleaved event and return response over AF_UNIX.
    const char *qmp_commands[] = {"query-status", "stop", "cont", "system_reset"};
    char temporaryDirectory[] = "/tmp/isteam-qmp-XXXXXX";
    char *createdDirectory = mkdtemp(temporaryDirectory);
    assert(createdDirectory != NULL);
    QMPServer qmp_server = {.commands = qmp_commands,
                            .command_count = sizeof(qmp_commands) / sizeof(qmp_commands[0])};
    int socketPathLength = snprintf(qmp_server.path, sizeof(qmp_server.path),
                                    "%s/q.sock", createdDirectory);
    assert(socketPathLength > 0 && (size_t)socketPathLength < sizeof(qmp_server.path));
    pthread_t qmp_server_thread;
    assert(pthread_create(&qmp_server_thread, NULL, qmp_test_server, &qmp_server) == 0);
    for (size_t index = 0; index < qmp_server.command_count; ++index) {
        memset(qmp_error, 0, sizeof(qmp_error));
        assert(isteam_qemu_qmp_command(qmp_server.path, qmp_commands[index],
                                       qmp_error, (int)sizeof(qmp_error)));
        assert(qmp_error[0] == '\0');
    }
    assert(pthread_join(qmp_server_thread, NULL) == 0);
    assert(unlink(qmp_server.path) == 0);
    assert(rmdir(createdDirectory) == 0);
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
