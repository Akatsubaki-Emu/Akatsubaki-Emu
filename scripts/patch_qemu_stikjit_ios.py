#!/usr/bin/env python3
"""Connect QEMU's Darwin split-W^X allocator to the host app's StikDebug JIT protocol."""
from pathlib import Path
import sys

INCLUDE_ANCHOR = "#ifdef CONFIG_DARWIN\n#include <mach/mach.h>"
FUNCTION_ANCHOR = "static int alloc_code_gen_buffer_splitwx_vmremap(size_t size, Error **errp)\n{\n"
MARKER = "alloc_code_gen_buffer_splitwx_stikdebug"

HELPER = r'''#if TARGET_OS_IOS
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
    typedef bool (*JITReadyFunction)(void);
    typedef void *(*JITPrepareFunction)(void *, size_t);
    typedef void (*JITDetachFunction)(void);
    JITReadyFunction jit_ready = (JITReadyFunction)dlsym(RTLD_DEFAULT, "iSteamJITIsReady");
    JITPrepareFunction prepare_region = (JITPrepareFunction)dlsym(RTLD_DEFAULT, "iSteamJITPrepareRegion");
    JITDetachFunction detach = (JITDetachFunction)dlsym(RTLD_DEFAULT, "iSteamJITDetach");
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
        required = [
            "iSteamJITGetProtocolMode",
            "iSteamJITIsSupported",
            "iSteamJITIsReady",
            "iSteamJITPrepareRegion",
            "iSteamJITDetach",
            "jit_protocol_mode < 0",
            "jit_protocol_mode > 0",
            "__builtin_available(iOS 26.0, *)",
            "return alloc_code_gen_buffer_splitwx_stikdebug(size, errp);",
            "tcg_splitwx_diff = buf_rx - buf_rw",
        ]
        missing = [item for item in required if item not in source]
        if missing:
            raise SystemExit("Existing StikDebug QEMU patch is incomplete: " + ", ".join(missing))
        return source

    if INCLUDE_ANCHOR not in source:
        raise SystemExit("QEMU tcg/region.c changed: Darwin Mach include anchor not found")
    source = source.replace(
        INCLUDE_ANCHOR,
        "#ifdef CONFIG_DARWIN\n#include <TargetConditionals.h>\n#include <dlfcn.h>\n#include <mach/mach.h>",
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
    source = source.replace(FUNCTION_ANCHOR, replacement, 1)
    required = [
        "#include <TargetConditionals.h>",
        "#include <dlfcn.h>",
        "iSteamJITGetProtocolMode",
        "iSteamJITIsSupported",
        "iSteamJITIsReady",
        "iSteamJITPrepareRegion",
        "iSteamJITDetach",
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


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_qemu_stikjit_ios.py /path/to/qemu/tcg/region.c")
    path = Path(sys.argv[1])
    source = path.read_text(encoding="utf-8")
    patched = patch_source(source)
    path.write_text(patched, encoding="utf-8")
    print("Patched QEMU TCG split-W^X allocation to use the StikDebug iOS 26+ TXM breakpoint protocol.")


if __name__ == "__main__":
    main()
