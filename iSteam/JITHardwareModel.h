#ifndef ISTEAM_JIT_HARDWARE_MODEL_H
#define ISTEAM_JIT_HARDWARE_MODEL_H

#include "JIT26Protocol.h"
#include <limits.h>
#include <string.h>

static inline bool iSteamJITParseModelComponent(const char **cursor, unsigned long *value) {
    const char *current = *cursor;
    if (current == NULL || *current < '0' || *current > '9') return false;
    unsigned long parsed = 0;
    do {
        unsigned digit = (unsigned)(*current - '0');
        if (parsed > (ULONG_MAX - digit) / 10UL) return false;
        parsed = parsed * 10UL + digit;
        current++;
    } while (*current >= '0' && *current <= '9');
    *cursor = current;
    *value = parsed;
    return true;
}

/* Mirrors StikDebug's ProcessInfo.hasTXM hardware rules. */
static inline int iSteamJITHardwareModelTXMModeForOS(
    const char *hardwareIdentifier,
    bool ios27OrNewer,
    bool ios26OrNewer
) {
    if (hardwareIdentifier == NULL || hardwareIdentifier[0] == '\0') return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    if (ios27OrNewer) {
        if (strcmp(hardwareIdentifier, "iPad8,11") == 0
            || strcmp(hardwareIdentifier, "iPad8,12") == 0) return ISTEAM_JIT_PROTOCOL_STANDARD;
        return ISTEAM_JIT_PROTOCOL_STIKDEBUG;
    }
    if (!ios26OrNewer) return ISTEAM_JIT_PROTOCOL_STANDARD;

    bool isIPad = strncmp(hardwareIdentifier, "iPad", 4) == 0;
    const char *model = isIPad ? hardwareIdentifier + 4
        : (strncmp(hardwareIdentifier, "iPhone", 6) == 0 ? hardwareIdentifier + 6 : NULL);
    if (model == NULL) return ISTEAM_JIT_PROTOCOL_UNKNOWN;

    const char *cursor = model;
    unsigned long major = 0, minor = 0;
    if (!iSteamJITParseModelComponent(&cursor, &major) || *cursor != ',') return ISTEAM_JIT_PROTOCOL_UNKNOWN;
    cursor++;
    if (!iSteamJITParseModelComponent(&cursor, &minor) || *cursor != '\0') return ISTEAM_JIT_PROTOCOL_UNKNOWN;

    unsigned minorDigits = 1;
    for (unsigned long value = minor; value >= 10UL; value /= 10UL) minorDigits++;
    double divisor = 1.0;
    for (unsigned index = 0; index < minorDigits; index++) divisor *= 10.0;
    double version = (double)major + ((double)minor / divisor);
    double threshold = isIPad ? 14.5 : 14.2;
    return version >= threshold ? ISTEAM_JIT_PROTOCOL_STIKDEBUG : ISTEAM_JIT_PROTOCOL_STANDARD;
}

#endif
