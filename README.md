# xd-ios

An iOS build of the native Pokémon Colosseum and Pokémon XD port (the one Orre Launcher builds), for running inside NX2 Apple.

**No game files are in this repository, and none ever go in it.** The build uses only open source code: the port, at the commit Orre Launcher pins (`pins.env`), and the decompilations. The game reads your own disc image (GC6E01 or GXXE01, US) from its folder on the phone when it runs.

## Status

1. `mac-probe` — builds the port's existing Mac version on GitHub Actions, to check the toolchain and see how the build is laid out.
2. iOS build — next.
