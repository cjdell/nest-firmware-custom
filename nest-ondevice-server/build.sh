#!/usr/bin/env bash
# Cross-compile the on-device server for the Nest thermostat.
#
# Target: armv7 (Cortex-A8, TI OMAP3630), soft-float EABI, Linux 2.6.37.
# The Nest userland is soft-float (ld-linux.so.3), so the correct Rust target is
# armv7-unknown-linux-musleabi, NOT ...eabihf. A static musl binary avoids the
# device's 2008-era glibc entirely.
#
# Pick whichever cross toolchain you have:
#   cargo install cross --git https://github.com/cross-rs/cross   (needs Docker)
#   cargo install cargo-zigbuild && pip install ziglang           (no Docker)
set -euo pipefail

TARGET=armv7-unknown-linux-musleabi

if command -v cross >/dev/null 2>&1; then
    echo ">> cross build ($TARGET)"
    cross build --release --target "$TARGET"
elif command -v cargo-zigbuild >/dev/null 2>&1; then
    echo ">> cargo zigbuild ($TARGET)"
    cargo zigbuild --release --target "$TARGET"
else
    echo "No cross/zigtool found; trying a plain cargo build (needs an installed linker)."
    cargo build --release --target "$TARGET"
fi

BIN="target/$TARGET/release/nest-ondevice"
if [ -f "$BIN" ]; then
    ls -lh "$BIN"
    echo
    echo "Deploy:  scp $BIN root@<nest>:/media/scratch/nest-ondevice"
    echo "Install: see deploy/nest-ondevice.init"
fi
