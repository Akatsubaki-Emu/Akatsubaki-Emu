#ifndef AKATSUBAKI_PAIRING_FFI_H
#define AKATSUBAKI_PAIRING_FFI_H
#include <stdint.h>
typedef struct AkatsubakiPairingSession AkatsubakiPairingSession;
typedef struct { char *error_message; char *host_alt_irk_hex; } AkatsubakiPairingResult;
typedef void (*AkatsubakiPairingReadyCallback)(void *, const char *, uint16_t, const char *);
typedef void (*AkatsubakiPairingPinCallback)(void *, const char *);
AkatsubakiPairingSession *akatsubaki_pairing_session_new(void);
void akatsubaki_pairing_session_cancel(AkatsubakiPairingSession *);
void akatsubaki_pairing_session_free(AkatsubakiPairingSession *);
int32_t akatsubaki_pairing_run(AkatsubakiPairingSession *, const char *, const char *, const char *, const char *, const char *, const char *, const char *, AkatsubakiPairingReadyCallback, AkatsubakiPairingPinCallback, void *, AkatsubakiPairingResult *);
void akatsubaki_pairing_result_free(AkatsubakiPairingResult *);
#endif
