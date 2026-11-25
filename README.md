# xd-ios

Pokémon XD: Gale of Darkness and Pokémon Colosseum running natively on iPhone: an iOS build of the native PC port that
[Orre Launcher](https://github.com/chasem-dev/orre-launcher) builds, made from the
[pkmn-colosseum](https://github.com/chasem-dev/pkmn-colosseum) and
[Pokemon-XD-Decomp](https://github.com/chasem-dev/Pokemon-XD-Decomp) decompilations. Not an emulator: the game's code is
compiled for the phone's own processor.

> **AI-assisted.** This repository's changes (the patches, the iOS app code, the build workflows and the test apps) were
> written with Claude, Anthropic's AI assistant, and tested by hand on a real device. Read and review them before relying on
> them. The port and the decompilations they patch are the work of their own authors.

**No game files are in this repository, and none ever go in it.** The build uses only open source code: the port, at the
commit Orre Launcher pins (`pins.env`), and the decompilations. The app reads your own disc image (GXXE01 or GC6E01, US)
from its folder on the phone when it runs.

Unofficial fan project, not affiliated with Nintendo, Creatures, GAME FREAK or The Pokémon Company.

## Status

XD boots to the title screen and plays (menus, battles, sound, controller) on an iPhone running iOS 27.3. Colosseum builds
the same way. Early test builds: expect bugs.

## Using it

1. Download `Pokemon-xd.ipa` (or `Pokemon-colosseum.ipa`) from the [Test builds](../../releases/tag/test-builds) release and
   install it with your sideloader. It needs the extended virtual addressing entitlement, which the IPA carries.
2. Open the app once, so its folder appears in Files (On My iPhone).
3. Put your own disc image (`.iso`, any name) in that folder, and open the app again. A controller is needed (no touch
   controls yet).
4. If something goes wrong, the folder has `log.txt` and, after a crash, a report under `State/colo-port/crashes`.

## How it works

`patches/` changes the port for iOS; `docs/ios-plan.md` has the details and the device test results:

1. **The memory window.** The game's 32-bit memory lives in a 4 GiB window, at 448 GiB: the one place iOS allows it
   (`tests/vmprobe`). MEM1's extra views are made with `vm_remap`, as iOS refuses `shm_open`.
2. **The code in the app.** iOS runs only signed code, so the game's code is linked into the app's executable instead of
   being loaded at run time. Its data stays in the window, addressed absolutely (`tools/a64abs.py`), and the signed code
   pages are also shown at their place in the window, so the game's own function addresses work.
3. **iOS itself.** SDL2 patched for UIKit's scene life cycle (required of apps built with the iOS 27 SDK), the Metal
   renderer and crash reporter without Mac-only APIs, and a small app around the port's `main` (`host/ios.m`).

Builds run on GitHub Actions with the newest Xcode (the iPhone Duo needs the iOS 27.1 SDK or newer).
