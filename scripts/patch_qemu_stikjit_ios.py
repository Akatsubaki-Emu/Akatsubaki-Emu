#!/usr/bin/env python3
"""Connect QEMU's Darwin split-W^X allocator to the host app's StikDebug JIT protocol."""
from pathlib import Path
import sys

INCLUDE_ANCHOR = "#ifdef CONFIG_DARWIN\n#include <mach/mach.h>"
FUNCTION_ANCHOR = "static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)\n{\n"
MARKER = "alloc_code_gen_buffer_splitwx_stikdebug"
EXPORT_LIST_REQUIRED = ("qemu_init;", "qemu_main_loop;", "qemu_cleanup;")
EXPORT_LIST_ADDITIONS = ("qemu_system_shutdown_request;", "isteam_qemu_set_jit_callbacks;")

HELPER = r'''#if TARGET_OS_IOS
typedef bool (*JITReadyFunction)(void);
typedef void *(*JITPrepareFunction)(void *, size_t);
typedef void (*JITDetachFunction)(void);

static JITReadyFunction g_jit_ready;
static JITPrepareFunction g_jit_prepare_region;
static JITDetachFunction g_jit_detach;

__attribute__((used, visibility("default")))
void isteam_qemu_set_jit_callbacks(JITReadyFunction ready,
                                   JITPrepareFunction prepare,
                                   JITDetachFunction detach)
{
    g_jit_ready = ready;
    g_jit_prepare_region = prepare;
    g_jit_detach = detach;
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
    kern_return_t ret;
    mach_vm_address_t buf_rw = 0;
    mach_vm_address_t buf_rx;
    vm_prot_t cur_prot, max_prot;

    if (!g_jit_ready || !g_jit_prepare_region || !g_jit_detach || !g_jit_ready()) {
        error_setg(errp, "iOS 26+ QEMU TCG requires an attached StikDebug JIT session.");
        return -1;
    }

    buf_rx = (mach_vm_address_t)g_jit_prepare_region(NULL, size);
    if (buf_rx == 0) {
        error_setg(errp, "StikDebug did not provide an executable QEMU translation region.");
        g_jit_detach();
        return -1;
    }

    ret = mach_vm_remap(mach_task_self(), &buf_rw, size, 0, VM_FLAGS_ANYWHERE,
                        mach_task_self(), buf_rx, false, &cur_prot, &max_prot,
                        VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        error_setg(errp, "vm_remap for the StikDebug JIT writable alias failed: %d", ret);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        g_jit_detach();
        return -1;
    }
    if ((max_prot & VM_PROT_WRITE) == 0) {
        error_setg(errp, "StikDebug JIT region does not permit a writable alias.");
        mach_vm_deallocate(mach_task_self(), buf_rw, size);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        g_jit_detach();
        return -1;
    }

    ret = mach_vm_protect(mach_task_self(), buf_rw, size, FALSE,
                          VM_PROT_READ | VM_PROT_WRITE);
    if (ret != KERN_SUCCESS) {
        error_setg(errp, "vm_protect for the StikDebug JIT writable alias failed: %d", ret);
        mach_vm_deallocate(mach_task_self(), buf_rw, size);
        mach_vm_deallocate(mach_task_self(), buf_rx, size);
        g_jit_detach();
        return -1;
    }

    region.start_aligned = (void *)buf_rw;
    region.total_size = size;
    tcg_splitwx_diff = buf_rx - buf_rw;
    g_jit_detach();
    return PROT_READ | PROT_WRITE;
}
#endif

'''


def patch_source(source: str) -> str:
    if MARKER in source:
        required = [
            "iSteamJITGetProtocolMode",
            "isteam_qemu_set_jit_callbacks",
            "g_jit_ready = ready;",
            "g_jit_prepare_region = prepare;",
            "g_jit_detach = detach;",
            '__attribute__((used, visibility("default")))',
            'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
            "jit_protocol_mode < 0",
            "jit_protocol_mode > 0",
            "__builtin_available(iOS 26.0, *)",
            "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
            "tcg_splitwx_diff = buf_rx - buf_rw",
        ]
        if source.count("static int alloc_code_gen_buffer_splitwx_stikdebug(") != 1:
            required.append("exactly one StikDebug allocator definition")
        if source.count("void isteam_qemu_set_jit_callbacks(") != 1:
            required.append("exactly one exported callback setter")
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

    if source.count(INCLUDE_ANCHOR) != 1:
        raise SystemExit("QEMU tcg/region.c changed: Darwin Mach include anchor missing or duplicated")
    source = source.replace(
        INCLUDE_ANCHOR,
        "#ifdef CONFIG_DARWIN\n#include <TargetConditionals.h>\n#include <dlfcn.h>\n#include <mach/mach.h>",
        1,
    )
    if source.count(FUNCTION_ANCHOR) != 1:
        raise SystemExit("QEMU tcg/region.c changed: split-W^X Darwin allocator not found or duplicated")
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
    source = source.replace(FUNCTION_ANCHOR, replacement, 1)
    required = [
        "#include <TargetConditionals.h>",
        "#include <dlfcn.h>",
        "iSteamJITGetProtocolMode",
        "isteam_qemu_set_jit_callbacks",
        "g_jit_ready = ready;",
        "g_jit_prepare_region = prepare;",
        "g_jit_detach = detach;",
        '__attribute__((used, visibility("default")))',
        'dlsym(RTLD_DEFAULT, "iSteamJITGetProtocolMode")',
        "jit_protocol_mode < 0",
        "jit_protocol_mode > 0",
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
        if sum(1 for line in lines if line.strip() == symbol) != 1
    ]
    if missing_base:
        raise SystemExit(
            "QEMU system/qemu.symbols changed: required lifecycle exports are missing or duplicated: "
            + ", ".join(missing_base)
        )
    closing = [i for i, line in enumerate(lines) if line.strip() == "};"]
    if len(closing) != 1:
        raise SystemExit("QEMU system/qemu.symbols changed: expected exactly one closing '};' line")
    close_index = closing[0]
    for symbol in EXPORT_LIST_ADDITIONS:
        count = sum(1 for line in lines if line.strip() == symbol)
        if count > 1:
            raise SystemExit("QEMU system/qemu.symbols contains duplicate export: " + symbol)
        if count == 0:
            lines.insert(close_index, "  " + symbol)
            close_index += 1
    result = "\\n".join(lines)
    return result + ("\\n" if source.endswith("\\n") else "")


def patch_qemu_sources(region_path: Path) -> None:
    region_path = Path(region_path)
    symbols_path = region_path.parent.parent / "system" / "qemu.symbols"
    if not symbols_path.is_file():
        raise SystemExit("QEMU system/qemu.symbols not found beside tcg/region.c")
    region = patch_source(region_path.read_text(encoding="utf-8"))
    symbols = patch_exported_symbols(symbols_path.read_text(encoding="utf-8"))
    region_path.write_text(region, encoding="utf-8")
    symbols_path.write_text(symbols, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_stikjit_ios.py /path/to/qemu/tcg/region.c")
    path = Path(sys.argv[1])
    patch_qemu_sources(path)
    print("Patched QEMU TCG split-W^X allocation to use the StikDebug iOS 26+ TXM breakpoint protocol.")


if __name__ == "__main__":
    main()
