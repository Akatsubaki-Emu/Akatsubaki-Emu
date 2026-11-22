#include "Box64Bridge.h"

#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>

typedef int (*box64_main_fn)(int, char **);

static pthread_mutex_t g_box64_working_directory_lock = PTHREAD_MUTEX_INITIALIZER;

static box64_main_fn resolveBox64Main(void) {
    box64_main_fn fn = (box64_main_fn)dlsym(RTLD_DEFAULT, "box64_library_main");
    if (!fn) fn = (box64_main_fn)dlsym(RTLD_DEFAULT, "box64_main");
    return fn;
}

bool box64IsAvailable(void) {
    return resolveBox64Main() != NULL;
}

int box64Run(const char *executable, const char *workingDirectory,
             int argc, const char *argv[]) {
    if (!executable || !executable[0] || argc < 1 || !argv || !argv[0]) {
        return -EINVAL;
    }

    box64_main_fn fn = resolveBox64Main();
    if (!fn) return -2;

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

    int result = fn(argc, (char **)argv);
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
