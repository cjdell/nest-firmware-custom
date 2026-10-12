#!/bin/sh
# vm-build.sh — build this repo's Linux outputs inside a Linux Nix machine.
#
# This is the *native* build (no Mac involved): on any Linux host with nix,
# `NEST_ATTACK_DIR=... ./bin/macos/vm-build.sh firmware` does the same thing the
# Apple-container VM does. bin/macos/build.sh runs it inside the VM.
#
# Usage:  vm-build.sh [TARGET ...]      (TARGET default: firmware)
#   TARGET = a packages.<system>.* attribute: firmware, nest-ondevice,
#            initramfs, default.
#
# Environment:
#   NEST_SRC     staged repo            (default /src, read-only mount)
#   NEST_OUT     artifact directory     (default /out)
#   NEST_ATTACK  vendored GTVHacker tree (default /nest/attack, read-only)
#   NEST_SYSTEM  nix system             (default "$(uname -m)-linux")
#   NEST_HOST_REV  recorded in the manifest
#
# Artifacts are copied to $NEST_OUT with <target>.paths / .log / .sha256 /
# .manifest next to them. Nothing here flashes anything.
set -eu

src=${NEST_SRC:-/src}
out=${NEST_OUT:-/out}
attack=${NEST_ATTACK:-/nest/attack}
system=${NEST_SYSTEM:-$(uname -m)-linux}

if [ "$#" -eq 0 ]; then
    set -- firmware
fi

export NIX_CONFIG="experimental-features = nix-command flakes
ssl-cert-file = /etc/ssl/certs/ca-certificates.crt
build-users-group =
keep-derivations = true"
export NEST_ATTACK_DIR=$attack
export TMPDIR=${TMPDIR:-/tmp}

if [ ! -f "$src/flake.nix" ]; then
    echo "vm-build: no flake.nix at $src — stage the repo first" >&2
    exit 1
fi

# The vendored kernel is a git checkout. On a case-insensitive filesystem
# (macOS, and the virtiofs mount of it) git's case-distinct netfilter sources
# collapse onto one on-disk name, so make cannot find e.g. net/netfilter/xt_HL.c.
# Re-materialise Dev/linux from the git tree, which is case-exact, into the VM's
# case-sensitive /tmp. (On a case-sensitive host this is a no-op in effect.)
linux_src=$attack/Dev/linux
if [ -d "$linux_src" ] && [ -d "$attack/.git" ] && command -v git >/dev/null 2>&1; then
    fixed=${NEST_LINUX_FIXED:-/tmp/nest-linux-fixed}
    rm -rf "$fixed"
    mkdir -p "$fixed"
    git -C "$attack" -c safe.directory='*' archive --format=tar HEAD Dev/linux \
        | tar -x -C "$fixed"
    export NEST_LINUX_DIR="$fixed/Dev/linux"
    echo "vm-build: case-fixed kernel -> $NEST_LINUX_DIR"
fi

mkdir -p "$out"

collect() {
    p=$1
    if [ -f "$p" ]; then
        cp -f "$p" "$out/$(basename "$p")"
        return
    fi
    for f in "$p"/uImage "$p"/uImage.sha256 "$p"/initramfs.cpio "$p"/bin/nest-ondevice; do
        if [ -f "$f" ]; then
            cp -f "$f" "$out/$(basename "$f")"
        fi
    done
}

for target in "$@"; do
    echo "=== [vm] building packages.$system.$target ==="
    nix build --impure --no-link --print-out-paths -L \
        --expr "let f = builtins.getFlake \"path:$src\"; in f.packages.$system.$target" \
        > "$out/$target.paths"
    cat "$out/$target.paths"
    while read -r p; do
        [ -n "$p" ] && collect "$p"
    done < "$out/$target.paths"

    {
        printf 'target: %s\n'        "$target"
        printf 'system: %s\n'        "$system"
        printf 'host-revision: %s\n' "${NEST_HOST_REV:-unknown}"
        printf 'built: %s\n'         "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'vm: %s %s\n'         "$(uname -m)" "$(uname -r)"
        printf 'nix: %s\n'           "$(nix --version)"
        printf 'source: %s\n'        "$src"
        printf 'store-paths:\n'
        sed 's/^/  /' "$out/$target.paths"
    } > "$out/$target.manifest"

    # Always include a checksum of the produced artifacts, so the image can be
    # identified before flashing.
    ( cd "$out" && for f in *.img uImage *.cpio; do
        if [ -f "$f" ]; then sha256sum "$f"; fi
    done ) > "$out/$target.sha256" 2>/dev/null || true
    cat "$out/$target.sha256" 2>/dev/null || true
done

echo "=== [vm] done — artifacts in $out ==="
