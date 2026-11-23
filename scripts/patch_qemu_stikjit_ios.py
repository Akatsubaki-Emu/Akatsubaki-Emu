#!/usr/bin/env python3
"""Connect QEMU's Darwin split-W^X allocator to the host app's StikDebug JIT protocol."""
from pathlib import Path
import sys

INCLUDE_ANCHOR = "#ifdef CONFIG_DARWIN\n#include <mach/mach.h>"
FUNCTION_ANCHOR = "static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)\n{\n"
MARKER = "alloc_code_gen_buffer_splitwx_stikdebug"

LEGACY_IOS_MACH_INCLUDE = """#if TARGET_OS_IPHONE
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#define mach_vm_address_t vm_address_t
#define mach_vm_offset_t vm_offset_t
#define mach_vm_size_t vm_size_t
#define mach_vm_remap vm_remap
#define mach_vm_protect vm_protect
#define mach_vm_deallocate vm_deallocate
#else
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif"""
UPDATED_IOS_MACH_INCLUDE = """#if TARGET_OS_IPHONE
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#define mach_vm_address_t vm_address_t
#define mach_vm_offset_t vm_offset_t
#define mach_vm_size_t vm_size_t
#define mach_vm_remap vm_remap
#define mach_vm_protect vm_protect
#define mach_vm_deallocate vm_deallocate
#elif TARGET_OS_IOS
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#define mach_vm_address_t vm_address_t
#define mach_vm_offset_t vm_offset_t
#define mach_vm_size_t vm_size_t
#define mach_vm_remap vm_remap
#define mach_vm_protect vm_protect
#define mach_vm_deallocate vm_deallocate
#else
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif"""

EXPORT_LIST_REQUIRED = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
EXPORT_LIST_ADDITIONS = ("qemu_system_shutdown_request;", "isteam_qemu_set_jit_callbacks;")

HELPER = r'''#if TARGET_OS_IOS
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
    if MARKER in source:
        # Modern SDKs may set TARGET_OS_IOS without the deprecated TARGET_OS_IPHONE macro.
        if "#elif TARGET_OS_IOS" not in source:
            if source.count(LEGACY_IOS_MACH_INCLUDE) != 1:
                raise SystemExit("Existing StikDebug QEMU patch has an unrecognized Mach include block")
            source = source.replace(LEGACY_IOS_MACH_INCLUDE, UPDATED_IOS_MACH_INCLUDE, 1)
        required = [
            "isteam_qemu_set_jit_callbacks",
            "isteam_jit_ready_callback",
            "isteam_jit_prepare_callback",
            "isteam_jit_detach_callback",
            "#if TARGET_OS_IPHONE",
            "#elif TARGET_OS_IOS",
            "#include <mach/mach_init.h>",
            "#include <mach/vm_map.h>",
            "#define mach_vm_address_t vm_address_t",
            "#define mach_vm_offset_t vm_offset_t",
            "#define mach_vm_size_t vm_size_t",
            "#define mach_vm_remap vm_remap",
            "#define mach_vm_protect vm_protect",
            "#define mach_vm_deallocate vm_deallocate",
            "#include <mach/mach_vm.h>",
            "iSteamJITGetProtocolMode",
            'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
            "jit_protocol_mode > 0",
            "__builtin_available(iOS 26.0, *)",
            "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
            "tcg_splitwx_diff = buf_rx - buf_rw",
        ]
        missing = [item for item in required if item not in source]
        forbidden = [
            'dlsym(RTLD_DEFAULT, "iSteamJITIsReady")',
            'dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion")',
            'dlsym(RTLD_DEFAULT, "iSteamJITDetach")',
        ]
        unexpected = [item for item in forbidden if item in source]
        if missing or unexpected:
            details = missing + ["unexpected host-symbol lookup: " + item for item in unexpected]
            raise SystemExit("Existing StikDebug QEMU patch is incomplete: " + ", ".join(details))
        return source

    if INCLUDE_ANCHOR not in source:
        raise SystemExit("QEMU tcg/region.c changed: Darwin Mach include anchor not found")
    source = source.replace(
        INCLUDE_ANCHOR,
        "#ifdef CONFIG_DARWIN\n"
        "#include <TargetConditionals.h>\n"
        "#include <stdbool.h>\n"
        "#include <stddef.h>\n"
        "#include <dlfcn.h>\n"
        "#if TARGET_OS_IPHONE\n"
        "#include <mach/mach_init.h>\n"
        "#include <mach/vm_map.h>\n"
        "#define mach_vm_address_t vm_address_t\n"
        "#define mach_vm_offset_t vm_offset_t\n"
        "#define mach_vm_size_t vm_size_t\n"
        "#define mach_vm_remap vm_remap\n"
        "#define mach_vm_protect vm_protect\n"
        "#define mach_vm_deallocate vm_deallocate\n"
        "#elif TARGET_OS_IOS\n"
        "#include <mach/mach_init.h>\n"
        "#include <mach/vm_map.h>\n"
        "#define mach_vm_address_t vm_address_t\n"
        "#define mach_vm_offset_t vm_offset_t\n"
        "#define mach_vm_size_t vm_size_t\n"
        "#define mach_vm_remap vm_remap\n"
        "#define mach_vm_protect vm_protect\n"
        "#define mach_vm_deallocate vm_deallocate\n"
        "#else\n"
        "#include <mach/mach.h>\n"
        "#include <mach/mach_vm.h>\n"
        "#endif",
        1,
    )
    if FUNCTION_ANCHOR not in source:
        raise SystemExit("QEMU tcg/region.c changed: split-W^X Darwin allocator not found")
    replacement = HELPER + FUNCTION_ANCHOR + (
        "#if TARGET_OS_IOS\n"
        "    if (__builtin_available(iOS 26.0, *)) {\n"
        "        typedef int (*JITProtocolModeFunction)(void);\n"
        "        JITProtocolModeFunction get_jit_protocol_mode =\n"
        "            (JITProtocolModeFunction)dlsym(RTLD_DEFAULT, \"iSteamJITGetProtocolMode\");\n"
        "        int jit_protocol_mode = get_jit_protocol_mode ? get_jit_protocol_mode() : -1;\n"
        "        if (jit_protocol_mode < 0) {\n"
        "            error_setg(errp, \"Could not determine this iOS device's JIT protocol; refusing QEMU startup.\");\n"
        "            return -1;\n"
        "        }\n"
        "        if (jit_protocol_mode > 0) {\n"
        "            return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);\n"
        "        }\n"
        "    }\n"
        "#endif\n"
    )
    if "\\n" in replacement or "\\\"" in replacement:
        raise ValueError("StikDebug allocator patch contains escaped C source delimiters")

    source = source.replace(FUNCTION_ANCHOR, replacement, 1)
    required = [
        "#include <TargetConditionals.h>",
        "#include <stdbool.h>",
        "#include <stddef.h>",
        "#include <dlfcn.h>",
        "__attribute__((visibility(\"default\")))",
        "isteam_qemu_set_jit_callbacks",
        "isteam_jit_ready_callback",
        "isteam_jit_prepare_callback",
        "isteam_jit_detach_callback",
        "#if TARGET_OS_IPHONE",
        "#elif TARGET_OS_IOS",
        "#include <mach/mach_init.h>",
        "#include <mach/vm_map.h>",
        "#define mach_vm_address_t vm_address_t",
        "#define mach_vm_offset_t vm_offset_t",
        "#define mach_vm_size_t vm_size_t",
        "#define mach_vm_remap vm_remap",
        "#define mach_vm_protect vm_protect",
        "#define mach_vm_deallocate vm_deallocate",
        "#include <mach/mach_vm.h>",
        "iSteamJITGetProtocolMode",
        'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
        "jit_protocol_mode > 0",
        "if (jit_protocol_mode > 0)",
        "__builtin_available(iOS 26.0, *)",
        "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
        "mach_vm_remap(mach_task_self(), &buf_rw",
        "mach_vm_protect(mach_task_self(), buf_rw",
        "tcg_splitwx_diff = buf_rx - buf_rw",
    ]
    missing = [item for item in required if item not in source]
    if missing:
        raise SystemExit("StikDebug QEMU patch verification failed: " + ", ".join(missing))
    return source


def patch_exported_symbols(source: str) -> str:
    lines = source.splitlines()
    missing_base = [
        symbol for symbol in EXPORT_LIST_REQUIRED
        if not any(line.strip() == symbol for line in lines)
    ]
    if missing_base:
        raise SystemExit(
            "QEMU system/qemu.symbols changed: required lifecycle exports not found: "
            + ", ".join(missing_base)
        )
    closing = [i for i, line in enumerate(lines) if line.strip() == "};"]
    if len(closing) != 1:
        raise SystemExit("QEMU system/qemu.symbols changed: expected exactly one closing '};' line")
    close_index = closing[0]
    for symbol in EXPORT_LIST_ADDITIONS:
        count = sum(1 for line in lines if line.strip() == symbol)
        if count > 1:
            raise SystemExit(f"QEMU system/qemu.symbols contains duplicate export: {symbol}")
        if count == 0:
            lines.insert(close_index, "  " + symbol)
            close_index += 1
    patched = "\n".join(lines) + ("\n" if source.endswith("\n") else "")
    if any(
        not any(line.strip() == symbol for line in patched.splitlines())
        for symbol in (*EXPORT_LIST_REQUIRED, *EXPORT_LIST_ADDITIONS)
    ):
        raise SystemExit("QEMU system/qemu.symbols export verification failed")
    return patched


def patch_qemu_sources(region_path: Path) -> None:
    qemu_root = region_path.parent.parent
    symbols_path = qemu_root / "system" / "qemu.symbols"
    if not symbols_path.is_file():
        raise SystemExit(f"QEMU export list is missing: {symbols_path}")
    source = region_path.read_text(encoding="utf-8")
    symbols = symbols_path.read_text(encoding="utf-8")
    patched_source = patch_source(source)
    patched_symbols = patch_exported_symbols(symbols)
    if patched_symbols != symbols:
        symbols_path.write_text(patched_symbols, encoding="utf-8")
    if patched_source != source:
        region_path.write_text(patched_source, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_stikjit_ios.py /path/to/qemu/tcg/region.c")
    path = Path(sys.argv[1])
    patch_qemu_sources(path)
    print("Patched QEMU TCG allocation and exported lifecycle/JIT symbols for the StikDebug iOS 26+ TXM protocol.")


if __name__ == "__main__":
    main()
