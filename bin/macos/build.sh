#!/bin/sh
# build.sh — build this repo's Linux outputs on a Mac, with no Linux machine
# of your own: Apple's `container` runtime + a NixOS Linux VM is the builder.
#
# nix on macOS is *-darwin: it can evaluate foreign drvs and substitute cached
# ones, but it can never RUN an aarch64/x86_64-linux builder. The firmware
# build needs a Linux machine (make/perl + the 2008 i686 ARM toolchain run under
# qemu-i386), so the container VM supplies exactly that. Its /nix survives
# between runs, so iteration only rebuilds what changed.
#
# Usage (from the repo root):
#   bash bin/macos/build.sh start [TARGET]   # stage + detached build
#   bash bin/macos/build.sh wait  [TARGET]   # rc 0 = done, 1 = failed, 2 = running
#   bash bin/macos/build.sh log   [TARGET]   # tail -f the build log
#   bash bin/macos/build.sh status
#   bash bin/macos/build.sh stage            # only rsync the repo into the VM
#   bash bin/macos/build.sh vm               # a shell inside the build VM
#   bash bin/macos/build.sh stop             # stop the VM (its /nix is kept)
#
#   TARGET (default firmware) = packages.<system>.* :
#   firmware (the uImage), nest-ondevice (the ARM binary), initramfs.
#
# Overrides:
#   NEST_MACOS_CACHE      (~/.cache/nest-macos)
#   NEST_MACOS_CONTAINER  (nest-builder)
#   NEST_MACOS_IMAGE      (docker.io/rzmapp/nixos-vm:26.05)
#   NEST_MACOS_CPUS       (8)   NEST_MACOS_MEMORY (12g)
#   NEST_ATTACK_DIR       (host path to the vendored NestDFUAttack tree)
set -eu

repo=$(cd "$(dirname "$0")/../.." && pwd)
cache=${NEST_MACOS_CACHE:-$HOME/.cache/nest-macos}
src=$cache/src
out=$cache/out
certs=$cache/certs
cname=${NEST_MACOS_CONTAINER:-nest-builder}
image=${NEST_MACOS_IMAGE:-docker.io/rzmapp/nixos-vm:26.05}
cpus=${NEST_MACOS_CPUS:-8}
memory=${NEST_MACOS_MEMORY:-12g}
attack=${NEST_ATTACK_DIR:-$repo/NestDFUAttack}

die() { echo "macos/build: $*" >&2; exit 1; }

need_container() {
    command -v container >/dev/null 2>&1 ||
        die "the 'container' CLI is not on PATH (Apple's container runtime)"
}

stage() {
    [ -f "$repo/flake.nix" ] || die "no flake.nix in $repo"
    [ -d "$attack/Dev" ] || die "no GTVHacker tree at $attack (set NEST_ATTACK_DIR)"
    mkdir -p "$src" "$out" "$certs"
    if [ ! -f "$certs/ca-certificates.crt" ]; then
        security find-certificate -a -p \
            /System/Library/Keychains/SystemRootCertificates.keychain \
            > "$certs/ca-certificates.crt" ||
            die "could not seed a CA bundle from the system keychain"
    fi
    # The VM image's own CA bundle is stale; the certs mount overrides it.
    # Exclude the nested upstream checkouts (mounted separately), the cargo
    # target dir and VCS metadata.
    rsync -a --delete \
        --exclude .git \
        --exclude NestDFUAttack/ \
        --exclude NoLongerEvil-SelfHosted/ \
        --exclude NoLongerEvil-Thermostat/ \
        --exclude NoLongerEvil-Hubitat/ \
        --exclude hubitatcontrol/ \
        --exclude nest-ondevice-server/target/ \
        --exclude .DS_Store \
        "$repo/" "$src/"
    echo "macos/build: staged $repo -> $src" >&2
}

running() { container list --quiet 2>/dev/null | grep -qx "$cname"; }
exists()  { container list --all --quiet 2>/dev/null | grep -qx "$cname"; }

ensure_container() {
    need_container
    if exists; then
        running || { echo "macos/build: starting $cname" >&2; container start "$cname" >/dev/null; }
        return
    fi
    echo "macos/build: creating $cname from $image ($cpus cpus, $memory)" >&2
    container create --name "$cname" --cpus "$cpus" --memory "$memory" \
        --mount type=virtiofs,source="$src",target=/src,readonly \
        --mount type=virtiofs,source="$out",target=/out \
        --mount type=virtiofs,source="$certs",target=/etc/ssl/certs,readonly \
        --mount type=virtiofs,source="$attack",target=/nest/attack,readonly \
        "$image" sleep infinity >/dev/null
    container start "$cname" >/dev/null
}

start_build() {
    target=${1:-firmware}
    stage
    ensure_container

    rev=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$rev" ] && [ -n "$(git -C "$repo" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
        rev="$rev-dirty"
    fi

    rm -f "$out/$target.rc"
    : > "$out/$target.log"

    # The vendored kernel has case-only path collisions (xt_HL.c/xt_hl.c, …)
    # that macOS APFS collapses onto one on-disk name, so the mounted checkout
    # carries the damage into the VM. Archive Dev/linux *on the host* — git
    # reads the object database and is case-exact — and let the VM extract it
    # onto its case-sensitive filesystem. This works for either submodule
    # layout (self-contained `.git` dir or an absorbed gitfile).
    linux_tar=
    if [ -e "$attack/.git" ] && command -v git >/dev/null 2>&1; then
        linux_tar=$out/.attack-linux.tar
        git -C "$attack" -c safe.directory='*' archive --format=tar HEAD Dev/linux \
            > "$linux_tar.part"
        mv -f "$linux_tar.part" "$linux_tar"
        echo "macos/build: case-exact Dev/linux archived -> $linux_tar" >&2
    fi

    container exec -d "$cname" sh -c \
        "NEST_HOST_REV='$rev' NEST_SRC=/src NEST_OUT=/out NEST_ATTACK=/nest/attack \
         NEST_LINUX_TAR='$linux_tar' \
         sh /src/bin/macos/vm-build.sh $target > /out/$target.log 2>&1; \
         echo \$? > /out/$target.rc" \
        >/dev/null

    echo "macos/build: $target building in $cname (rev ${rev:-unknown})" >&2
    echo "macos/build: poll with  bash bin/macos/build.sh wait $target" >&2
}

wait_build() {
    target=${1:-firmware}
    if [ ! -f "$out/$target.rc" ]; then
        tail -n "${NEST_MACOS_TAIL:-5}" "$out/$target.log" 2>/dev/null || true
        echo "macos/build: $target STILL RUNNING (rc=2)" >&2
        exit 2
    fi
    rc=$(cat "$out/$target.rc")
    tail -n "${NEST_MACOS_TAIL:-20}" "$out/$target.log"
    if [ "$rc" = 0 ]; then
        echo "macos/build: $target DONE rc=0" >&2
        exit 0
    fi
    echo "macos/build: $target FAILED rc=$rc — see $out/$target.log" >&2
    exit 1
}

status() {
    need_container
    if exists; then
        echo "container: $cname ($(running && echo running || echo stopped))"
    else
        echo "container: $cname (absent)"
    fi
    echo "staging:   $src"
    echo "attack:    $attack"
    echo "artifacts: $out"
    for f in "$out"/*; do
        [ -e "$f" ] || continue
        case $f in *.log) continue ;; esac
        printf '  %-28s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
    for h in "$out"/*.sha256; do
        [ -f "$h" ] || continue
        echo "  --- $(basename "$h")"
        sed 's/^/    /' "$h"
    done
}

case ${1:-} in
    start)  shift; start_build "$@" ;;
    wait)   shift; wait_build "$@" ;;
    log)    shift; tail -n "${NEST_MACOS_TAIL:-40}" -f "$out/${1:-firmware}.log" ;;
    status) status ;;
    stage)  stage ;;
    vm|sh)  ensure_container; exec container exec -it "$cname" sh -l ;;
    stop)   container stop "$cname" 2>/dev/null || true ;;
    ""|-h|--help|help) sed -n '2,32p' "$0" ;;
    *)      die "unknown verb '$1' (try: start|wait|log|status|stage|vm|stop)" ;;
esac
