#!/usr/bin/env python3
"""Connect QEMU's Darwin split-W^X allocator to the host app's StikDebug JIT protocol."""
from pathlib import Path
import sys

INCLUDE_ANCHOR = "#ifdef CONFIG_DARWIN\n#include <mach/mach.h>"
FUNCTION_ANCHOR = "static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)\n{\n"
MARKER = "alloc_code_gen_buffer_splitwx_stikdebug"

HELPER = r'''#if TARGET_OS_IOS
enum {
    ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN = -1,
    ISTEAM_QEMU_JIT_PROTOCOL_STANDARD = 0,
    ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG = 1,
};
typedef int (*ISTEAMJITProtocolModeFunction)(void);
typedef bool (*ISTEAMJITReadyFunction)(void);
typedef void *(*ISTEAMJITPrepareFunction)(void *, size_t);
typedef void (*ISTEAMJITDetachFunction)(void);

static ISTEAMJITReadyFunction isteam_jit_ready_callback;
static ISTEAMJITPrepareFunction isteam_jit_prepare_callback;
static ISTEAMJITDetachFunction isteam_jit_detach_callback;

__attribute__((visibility("default")))
void isteam_qemu_set_jit_callbacks(ISTEAMJITReadyFunction ready,
                                   ISTEAMJITPrepareFunction prepare,
                                   ISTEAMJITDetachFunction detach);

__attribute__((visibility("default")))
void isteam_qemu_set_jit_callbacks(ISTEAMJITReadyFunction ready,
                                   ISTEAMJITPrepareFunction prepare,
                                   ISTEAMJITDetachFunction detach)
{
    isteam_jit_ready_callback = ready;
    isteam_jit_prepare_callback = prepare;
    isteam_jit_detach_callback = detach;
}

extern kern_return_t mach_vm_protect(vm_map_t target_task,
                                     mach_vm_address_t address,
                                     mach_vm_size_t size,
                                     boolean_t set_maximum,
                                     vm_prot_t new_protection);
extern kern_return_t mach_vm_deallocate(vm_map_t target_task,
                                       mach_vm_address_t address,
                                       mach_vm_size_t size);

static int alloc_code_gen_buffer_splitwx_stikdebug(size_t size, Error **errp)
{
    ISTEAMJITReadyFunction jit_ready = isteam_jit_ready_callback;
    ISTEAMJITPrepareFunction prepare_region = isteam_jit_prepare_callback;
    ISTEAMJITDetachFunction detach = isteam_jit_detach_callback;
    kern_return_t ret;
    mach_vm_address_t buf_rw = 0;
    mach_vm_address_t buf_rx;
    vm_prot_t cur_prot, max_prot;

    if (!jit_ready || !prepare_region || !detach || !jit_ready()) {
        error_setg(errp, "iOS 26+ QEMU TCG requires an attached StikDebug JIT session.");
        return -1;
    }

    buf_rx = (mach_vm_address_t)prepare_region(NULL, size);
    if (buf_rx == 0) {
        error_setg(errp, "StikDebug did not provide an executable QEMU translation region.");
        detach();
        return -1;
    }

    ret = mach_vm_remap(mach_task_self(), &buf_rw, size, 0, VM_FLAGS_ANYWHERE,
                        mach_task_self(), buf_rx, false, &cur_prot, &max_prot,
                        VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        error_setg(errp, "vm_remap for the StikDebug JIT writable alias failed: %d", ret);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        detach();
        return -1;
    }
    if ((max_prot & VM_PROT_WRITE) == 0) {
        error_setg(errp, "StikDebug JIT region does not permit a writable alias.");
        mach_vm_deallocate(mach_task_self(), buf_rw, size);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        detach();
        return -1;
    }

    ret = mach_vm_protect(mach_task_self(), buf_rw, size, FALSE,
                          VM_PROT_READ | VM_PROT_WRITE);
    if (ret != KERN_SUCCESS) {
        error_setg(errp, "vm_protect for the StikDebug JIT writable alias failed: %d", ret);
        mach_vm_deallocate(mach_task_self(), buf_rw, size);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        detach();
        return -1;
    }

    region.start_aligned = (void *)buf_rw;
    region.total_size = size;
    tcg_splitwx_diff = buf_rx - buf_rw;
    detach();
    return PROT_READ | PROT_WRITE;
}
#endif

'''


def patch_source(source: str) -> str:
    required = [
        "#include <TargetConditionals.h>",
        "#include <stdbool.h>",
        "#include <stddef.h>",
        "#include <dlfcn.h>",
        "#include <mach/mach_vm.h>",
        "__attribute__((visibility(\"default\")))",
        "isteam_qemu_set_jit_callbacks",
        "isteam_jit_ready_callback",
        "isteam_jit_prepare_callback",
        "isteam_jit_detach_callback",
        "ISTEAMJITProtocolModeFunction",
        "ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN = -1",
        "ISTEAM_QEMU_JIT_PROTOCOL_STANDARD = 0",
        "ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG = 1",
        "iSteamJITGetProtocolMode",
        'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
        "jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN",
        "jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG",
        "jit_protocol_mode != ISTEAM_QEMU_JIT_PROTOCOL_STANDARD",
        "__builtin_available(iOS 26.0, *)",
        "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
        "mach_vm_remap(mach_task_self(), &buf_rw",
        "mach_vm_protect(mach_task_self(), buf_rw",
        "tcg_splitwx_diff = buf_rx - buf_rw",
    ]
    forbidden = [
        'dlsym(RTLD_DEFAULT, "iSteamJITIsSupported")',
        'dlsym(RTLD_DEFAULT, "iSteamJITIsReady")',
        'dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion")',
        'dlsym(RTLD_DEFAULT, "iSteamJITDetach")',
        "jit_protocol_mode < 0",
        "jit_protocol_mode > 0",
    ]

    if MARKER in source:
        missing = [item for item in required if item not in source]
        unexpected = [item for item in forbidden if item in source]
        if missing or unexpected:
            details = missing + ["unexpected legacy protocol check: " + item for item in unexpected]
            raise SystemExit("Existing StikDebug QEMU patch is incomplete: " + ", ".join(details))
        return source

    if INCLUDE_ANCHOR not in source:
        raise SystemExit("QEMU tcg/region.c changed: Darwin Mach include anchor not found")
    source = source.replace(
        INCLUDE_ANCHOR,
        "#ifdef CONFIG_DARWIN\n#include <TargetConditionals.h>\n#include <stdbool.h>\n#include <stddef.h>\n#include <dlfcn.h>\n#include <mach/mach.h>\n#include <mach/mach_vm.h>",
        1,
    )
    if FUNCTION_ANCHOR not in source:
        raise SystemExit("QEMU tcg/region.c changed: split-W^X Darwin allocator not found")

    replacement = HELPER + FUNCTION_ANCHOR + (
        "#if TARGET_OS_IOS\n"
        "    if (__builtin_available(iOS 26.0, *)) {\n"
        "        ISTEAMJITProtocolModeFunction get_jit_protocol_mode =\n"
        "            (ISTEAMJITProtocolModeFunction)dlsym(RTLD_DEFAULT, \"iSteamJITGetProtocolMode\");\n"
        "        int jit_protocol_mode = get_jit_protocol_mode ? get_jit_protocol_mode() : ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN;\n"
        "        if (jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_UNKNOWN) {\n"
        "            error_setg(errp, \"Could not determine this iOS device's JIT protocol; refusing QEMU startup.\");\n"
        "            return -1;\n"
        "        }\n"
        "        if (jit_protocol_mode == ISTEAM_QEMU_JIT_PROTOCOL_STIKDEBUG) {\n"
        "            return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);\n"
        "        }\n"
        "        if (jit_protocol_mode != ISTEAM_QEMU_JIT_PROTOCOL_STANDARD) {\n"
        "            error_setg(errp, \"Unknown iOS JIT protocol mode %d; refusing QEMU startup.\", jit_protocol_mode);\n"
        "            return -1;\n"
        "        }\n"
        "    }\n"
        "#endif\n"
    )
    if "\\n" in replacement or "\\\"" in replacement:
        raise SystemExit("StikDebug QEMU patch contains escaped newline or quote sequences")

    source = source.replace(FUNCTION_ANCHOR, replacement, 1)
    missing = [item for item in required if item not in source]
    unexpected = [item for item in forbidden if item in source]
    if missing or unexpected:
        details = missing + ["unexpected legacy protocol check: " + item for item in unexpected]
        raise SystemExit("StikDebug QEMU patch verification failed: " + ", ".join(details))
    return source


REQUIRED_EXPORT_ANCHORS = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
REQUIRED_EXPORTS = (
    "qemu_system_shutdown_request;",
    "isteam_qemu_set_jit_callbacks;",
)


def patch_export_symbols(source: str) -> str:
    lines = [line.strip() for line in source.splitlines()]
    missing_anchors = [symbol for symbol in REQUIRED_EXPORT_ANCHORS if symbol not in lines]
    if missing_anchors:
        raise SystemExit(
            "QEMU system/qemu.symbols changed; missing expected anchors: "
            + ", ".join(missing_anchors)
        )

    duplicates = [symbol for symbol in REQUIRED_EXPORTS if lines.count(symbol) > 1]
    if duplicates:
        raise SystemExit(
            "QEMU system/qemu.symbols contains duplicate required exports: "
            + ", ".join(duplicates)
        )

    missing = [symbol for symbol in REQUIRED_EXPORTS if symbol not in lines]
    if not missing:
        return source

    patched = source
    if patched and not patched.endswith("\n"):
        patched += "\n"
    patched += "".join(symbol + "\n" for symbol in missing)
    return patched


def patch_file(path: Path) -> None:
    path = path.resolve()
    if path.name != "region.c" or path.parent.name != "tcg":
        raise SystemExit("expected the QEMU source path /tcg/region.c")

    source = path.read_text(encoding="utf-8")
    patched_source = patch_source(source)

    qemu_root = path.parent.parent
    symbols_path = qemu_root / "system" / "qemu.symbols"
    if not symbols_path.is_file():
        raise SystemExit(f"QEMU export symbol list not found: {symbols_path}")
    symbols_source = symbols_path.read_text(encoding="utf-8")
    patched_symbols = patch_export_symbols(symbols_source)

    if patched_source != source:
        path.write_text(patched_source, encoding="utf-8")
        print("Patched QEMU TCG split-W^X allocation for the StikDebug iOS 26+ TXM protocol.")
    else:
        print("QEMU TCG StikDebug allocator patch is already present.")

    if patched_symbols != symbols_source:
        symbols_path.write_text(patched_symbols, encoding="utf-8")
        print("Added QEMU bridge shutdown and StikDebug callback exports to system/qemu.symbols.")
    else:
        print("QEMU bridge exports are already present in system/qemu.symbols.")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_stikjit_ios.py /path/to/qemu/tcg/region.c")
    patch_file(Path(sys.argv[1]))


if __name__ == "__main__":
    main()
