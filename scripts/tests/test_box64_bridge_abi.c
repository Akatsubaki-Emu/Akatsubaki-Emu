#include "Box64Bridge.h"

#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef BOX64_TEST_NO_LIBRARY_MAIN
static char expected_directory[PATH_MAX];
static int wrapper_anchor_calls = 0;

void box64_ios_force_link_wrappers(void) {
    wrapper_anchor_calls++;
}

static int has_environment(char **environment, const char *expected) {
    if (!environment) return 0;
    for (size_t index = 0; environment[index]; ++index) {
        if (strcmp(environment[index], expected) == 0) return 1;
    }
    return 0;
}

int box64_library_main(int argc, const char **argv, char **environment) {
    char current_directory[PATH_MAX];
    assert(argc == 3);
    assert(strcmp(argv[0], "box64") == 0);
    assert(strcmp(argv[1], "guest.elf") == 0);
    assert(strcmp(argv[2], "--bridge-test") == 0);
#ifdef ISTEAM_BOX64_STATIC
    assert(wrapper_anchor_calls == 1);
#else
    assert(wrapper_anchor_calls == 0);
#endif
    assert(has_environment(environment, "BOX64_BRIDGE_TEST_ENV=expected"));
    assert(getcwd(current_directory, sizeof(current_directory)) != NULL);
    assert(strcmp(current_directory, expected_directory) == 0);
    return 73;
}
#endif

/* This legacy symbol deliberately has the wrong ABI and must never be used. */
int box64_main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    return 99;
}

int main(void) {
    const char *arguments[] = {"box64", "guest.elf", "--bridge-test"};
#ifdef BOX64_TEST_NO_LIBRARY_MAIN
    assert(!box64IsAvailable());
    assert(box64Run("guest.elf", ".", 3, arguments) == -2);
#else
    char original_directory[PATH_MAX];
    assert(getcwd(original_directory, sizeof(original_directory)) != NULL);
    char temporary_directory[] = "/tmp/box64-bridge-XXXXXX";
    char *created_directory = mkdtemp(temporary_directory);
    assert(created_directory != NULL);
    assert(strlen(created_directory) < sizeof(expected_directory));
    strcpy(expected_directory, created_directory);
    assert(setenv("BOX64_BRIDGE_TEST_ENV", "expected", 1) == 0);
    assert(box64IsAvailable());
    assert(box64Run("guest.elf", created_directory, 3, arguments) == 73);
    const char *wrong_arguments[] = {"box64", "other.elf"};
    assert(box64Run("guest.elf", created_directory, 2, wrong_arguments) == -EINVAL);
    char restored_directory[PATH_MAX];
    assert(getcwd(restored_directory, sizeof(restored_directory)) != NULL);
    assert(strcmp(restored_directory, original_directory) == 0);
    assert(box64Run(NULL, created_directory, 3, arguments) == -EINVAL);
    assert(rmdir(created_directory) == 0);
#endif
    puts("Box64 bridge argv ABI, wrapper retention, environment, symbol selection and working-directory restoration passed.");
    return 0;
}
