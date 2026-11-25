#ifndef Box64Bridge_h
#define Box64Bridge_h

#include <stdbool.h>

bool box64IsAvailable(void);
// argv follows Box64 CLI order: argv[0] is the runner name and argv[1] is the guest ELF.
int box64Run(const char *executable, const char *workingDirectory, int argc, const char *argv[]);

#endif
