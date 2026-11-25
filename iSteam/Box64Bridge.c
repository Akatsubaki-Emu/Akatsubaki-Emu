#include "Box64Bridge.h"

#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>

extern char **environ;

static char **box64_host_environment(void) {
    return environ;
}

typedef int (*box64_library_main_fn)(int, const char **, char **);

#if defined(ISTEAM_BOX64_STATIC)
extern int box64_library_main(int argc, const char **argv, char **environment);
#else
#include <dlfcn.h>
#endif

static pthread_mutex_t g_box64_working_directory_lock = PTHREAD_MUTEX_INITIALIZER;

static box64_library_main_fn resolveBox64Main(void) {
#if defined(ISTEAM_BOX64_STATIC)
    // A strong reference makes the linker pull box64_library_main from the
    // embedded static archive. The archive must be linked when this mode is enabled.
    return box64_library_main;
#else
    // Do not guess the ABI of legacy symbols such as box64_main.
    return (box64_library_main_fn)dlsym(RTLD_DEFAULT, "box64_library_main");
#endif
}

bool box64IsAvailable(void) {
    return resolveBox64Main() != NULL;
}

int box64Run(const char *executable, const char *workingDirectory,
             int argc, const char *argv[]) {
    if (!executable || !executable[0] || argc < 1 || !argv || !argv[0]) {
        return -EINVAL;
    }

    box64_library_main_fn fn = resolveBox64Main();
    if (!fn) return -2;

    char **environment = box64_host_environment();
    if (!environment) return -EFAULT;

    if (!workingDirectory || !workingDirectory[0]) return -EINVAL;

    // chdir is process-wide. Serialize Box64 invocations and always restore the
    // host directory so concurrent guest launches cannot corrupt each other's paths.
    pthread_mutex_lock(&g_box64_working_directory_lock);
    int originalDirectory = open(".", O_RDONLY | O_CLOEXEC);
    if (originalDirectory < 0) {
        int error = errno;
        pthread_mutex_unlock(&g_box64_working_directory_lock);
        return -error;
    }

    if (chdir(workingDirectory) != 0) {
        int error = errno;
        close(originalDirectory);
        pthread_mutex_unlock(&g_box64_working_directory_lock);
        return -error;
    }

    int result = fn(argc, argv, environment);
    int executionErrno = errno;
    if (fchdir(originalDirectory) != 0) {
        int error = errno;
        close(originalDirectory);
        pthread_mutex_unlock(&g_box64_working_directory_lock);
        return -error;
    }
    close(originalDirectory);
    pthread_mutex_unlock(&g_box64_working_directory_lock);
    errno = executionErrno;
    return result;
}
