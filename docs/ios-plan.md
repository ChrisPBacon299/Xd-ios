# iOS build plan

What the Mac (Apple silicon) build does, what iOS allows, and what changes. Findings from the
`mac-probe` and `vmprobe` runs (iPhone, iOS 26, extended virtual addressing on).

## What the device allows (vmprobe 1.1)

| Check | Result |
| --- | --- |
| 4 GiB window, system's choice | always at 448 GiB, 4 GiB aligned |
| 4 GiB window, `MAP_FIXED` | 448 GiB only (64-384 GiB already used, 456 GiB and up refused) |
| MEM1 committed at window + 0x80000000 | OK |
| MEM1 mirror by `vm_remap` | OK, shared |
| `shm_open` | refused (Operation not permitted) |
| App code | about 4 GiB, slid each launch |

## Changes

1. **Memory base.** `COLO_BASE` from 1 TiB to 448 GiB (`0x7000000000`) in `tools/befix.py` and
   `host/colo.h`. Still 4 GiB aligned, so the `or`-with-base lowering is unchanged.
   `colo_mmap_noreplace` must check the range is free and then use `MAP_FIXED`: iOS ignores a plain hint.
2. **MEM1 and its mirrors.** `host/main.c` makes MEM1 a shared memory object (`shm_open`) and maps it
   at its three addresses. iOS refuses `shm_open`: map MEM1 once and mirror it with `vm_remap`.
3. **Game code inside the app (the big one).** The Mac build links game code as an ELF image at
   window + 0x20000000, carries it in `__COLO,__game` and maps it executable at startup
   (`host/macos.c`). iOS does not allow executable memory made at run time. Game code must be in the
   signed executable, about 444 GiB away from the window, out of `adrp` range (±4 GiB). Plan:
   * game units compiled as Mach-O (`arm64-apple-ios`), so references to retail globals (absolute
     symbols at 448 GiB + address) go through the GOT, as Darwin does for external data;
   * every global *variable* the units define (statics, strings, constants) moved by `befix.py` into
     one data module, linked by ld.lld as an ELF data image in the window (game code keeps 32-bit
     pointers to them) and loaded there at startup, not executable;
   * the data image's references to code (function pointer tables) fixed up at startup by the app's
     slide, from relocations ld.lld keeps (`--emit-relocs`);
   * `imports.s` / `game_exports.s` / the `colo_fn` table replaced by ordinary Mach-O linking.
4. **Host.** `host/macos.c` (AppKit main thread, `__PAGEZERO`, Mach-O section) becomes an iOS host:
   SDL2 for iOS (UIKit), files in the app's Documents folder (the game folder), `COLO_WIDESCREEN=4:3`
   by default. The renderer already draws through an SDL Metal view (`ext/sms_gx/src/mtl`), which
   SDL supports on iOS. The GBA core (mGBA) is left out at first.
5. **Package.** Unsigned IPA with the extended-virtual-addressing and increased-memory-limit
   entitlements, published to the `test-builds` release.

## Order

1. Base + mirrors (1, 2) on the Mac build, to check nothing else assumes 1 TiB.
2. Code into the executable (3), still on the Mac, where it can be run and checked on the runner.
3. iOS host and IPA (4, 5).
