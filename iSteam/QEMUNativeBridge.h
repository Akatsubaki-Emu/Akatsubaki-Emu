#ifndef iSteam_QEMUNativeBridge_h
#define iSteam_QEMUNativeBridge_h

#include <stdbool.h>

#if defined(__APPLE__) && defined(__clang__)
#define ISTEAM_NONNULL _Nonnull
#else
#define ISTEAM_NONNULL
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the candidate library with RTLD_NOW and verifies the required
/// QEMU lifecycle exports without starting a guest or consuming the one-shot
/// QEMU session lifecycle.
bool isteam_qemu_validate_library(const char * ISTEAM_NONNULL library_path,
                                  bool requires_jit,
                                  char * ISTEAM_NONNULL error_buffer, int error_capacity);
/// Starts the in-process QEMU system emulator. Returns false with a diagnostic
/// if the runtime or required lifecycle symbols are unavailable.
bool isteam_qemu_start(int argc, const char * ISTEAM_NONNULL const * ISTEAM_NONNULL argv,
                       const char * ISTEAM_NONNULL library_path, bool requires_jit,
                       char * ISTEAM_NONNULL error_buffer, int error_capacity);
/// Sends a whitelisted QMP control command to the persistent in-process QEMU session.
bool isteam_qemu_qmp_command(const char * ISTEAM_NONNULL socket_path,
                             const char * ISTEAM_NONNULL command,
                             char * ISTEAM_NONNULL error_buffer, int error_capacity);
void isteam_qemu_request_stop(void);
bool isteam_qemu_is_running(void);
bool isteam_qemu_is_active(void);
const char * ISTEAM_NONNULL isteam_qemu_last_error(void);

#ifdef __cplusplus
}
#endif

#undef ISTEAM_NONNULL
#endif
