#!/bin/sh
# container.sh — the Linux build host for a Mac: Apple's `container` runtime
# plus a NixOS Linux VM.
#
# You normally do not call this directly. `./build` is the entry point: on Linux
# it runs bin/nix-build.sh in place, on macOS it dispatches here. Both end up
# running the *same* build script, which is why the two hosts produce identical
# images (bin/repro-check.sh proves the parts that differ).
#
# Why a VM at all: nix on macOS is *-darwin, so it can evaluate foreign drvs and
# substitute cached ones but can never RUN a Linux builder, and the firmware
# build needs Linux userland (make/perl + the 2008 i686 ARM toolchain under
# qemu-i386). The VM's /nix survives between runs, so iteration only rebuilds
# what changed.
#
# Usage (from the repo root):
#   bash bin/container.sh run    [TARGET]  # stage + build + wait (what ./build does)
#   bash bin/container.sh start  [TARGET]  # stage + detached build
#   bash bin/container.sh wait   [TARGET]  # rc 0 = done, 1 = failed, 2 = running
#   bash bin/container.sh log    [TARGET]  # tail -f the build log
#   bash bin/container.sh exec   <cmd..>   # one command inside the VM
#   bash bin/container.sh status           # VM state + artifacts + checksums
#   bash bin/container.sh path             # the host artifact directory
#   bash bin/container.sh stage            # only rsync the repo into the VM
#   bash bin/container.sh vm               # a shell inside the build VM
#   bash bin/container.sh stop             # stop the VM (its /nix is kept)
#
#   TARGET (default firmware) = a packages.<system>.* attribute:
#   firmware (the uImage), nest-ondevice (the ARM binary), initramfs.
#
# Overrides:
#   NEST_VM_CACHE      ~/.cache/nest-build   (staged repo, VM logs, artifacts)
#   NEST_VM_CONTAINER  nest-builder          (container name)
#   NEST_VM_IMAGE      docker.io/rzmapp/nixos-vm:26.05
#   NEST_VM_CPUS       8
#   NEST_VM_MEMORY     12g
#   NEST_VM_POLL       5    (seconds between ./build progress polls)
#   NEST_ATTACK_DIR    the vendored NestDFUAttack tree (default ./NestDFUAttack)
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cache=${NEST_VM_CACHE:-$HOME/.cache/nest-build}
src=$cache/src
out=$cache/out
certs=$cache/certs
cname=${NEST_VM_CONTAINER:-nest-builder}
image=${NEST_VM_IMAGE:-docker.io/rzmapp/nixos-vm:26.05}
cpus=${NEST_VM_CPUS:-8}
memory=${NEST_VM_MEMORY:-12g}
attack=${NEST_ATTACK_DIR:-$repo/NestDFUAttack}

die() { echo "container: $*" >&2; exit 1; }

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
        --exclude dist/ \
        --exclude NestDFUAttack/ \
        --exclude NoLongerEvil-SelfHosted/ \
        --exclude NoLongerEvil-Thermostat/ \
        --exclude hubitatcontrol/ \
        --exclude nest-ondevice-server/target/ \
        --exclude .DS_Store \
        "$repo/" "$src/"
    echo "container: staged $repo -> $src" >&2
}

running() { container list --quiet 2>/dev/null | grep -qx "$cname"; }
exists()  { container list --all --quiet 2>/dev/null | grep -qx "$cname"; }

ensure_container() {
    need_container
    if exists; then
        running || { echo "container: starting $cname" >&2; container start "$cname" >/dev/null; }
        return
    fi
    echo "container: creating $cname from $image ($cpus cpus, $memory)" >&2
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
        echo "container: case-exact Dev/linux archived -> $linux_tar" >&2
    fi

    container exec -d "$cname" sh -c \
        "NEST_HOST_REV='$rev' NEST_SRC=/src NEST_OUT=/out NEST_ATTACK=/nest/attack \
         NEST_LINUX_TAR='$linux_tar' \
         sh /src/bin/nix-build.sh $target > /out/$target.log 2>&1; \
         echo \$? > /out/$target.rc" \
        >/dev/null

    echo "container: $target building in $cname (rev ${rev:-unknown})" >&2
    echo "container: poll with  bash bin/container.sh wait $target" >&2
}

wait_build() {
    target=${1:-firmware}
    if [ ! -f "$out/$target.rc" ]; then
        tail -n "${NEST_VM_TAIL:-5}" "$out/$target.log" 2>/dev/null || true
        echo "container: $target STILL RUNNING (rc=2)" >&2
        exit 2
    fi
    rc=$(cat "$out/$target.rc")
    tail -n "${NEST_VM_TAIL:-20}" "$out/$target.log"
    if [ "$rc" = 0 ]; then
        echo "container: $target DONE rc=0" >&2
        exit 0
    fi
    echo "container: $target FAILED rc=$rc — see $out/$target.log" >&2
    exit 1
}

# Start a build and block until it finishes, streaming new log lines as they
# appear. This is what makes `./build firmware` a single command on a Mac.
run_build() {
    target=${1:-firmware}
    start_build "$target"
    seen=0
    while :; do
        if [ -f "$out/$target.log" ]; then
            total=$(wc -l < "$out/$target.log")
            if [ "$total" -gt "$seen" ]; then
                sed -n "$((seen + 1)),\$p" "$out/$target.log"
                seen=$total
            fi
        fi
        if [ -f "$out/$target.rc" ]; then
            rc=$(cat "$out/$target.rc")
            if [ "$rc" = 0 ]; then
                echo "container: $target DONE" >&2
                return 0
            fi
            echo "container: $target FAILED rc=$rc — full log: $out/$target.log" >&2
            return 1
        fi
        sleep "${NEST_VM_POLL:-5}"
    done
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
    run)    shift; run_build "$@" ;;
    start)  shift; start_build "$@" ;;
    wait)   shift; wait_build "$@" ;;
    log)    shift; tail -n "${NEST_VM_TAIL:-40}" -f "$out/${1:-firmware}.log" ;;
    status) status ;;
    stage)  stage ;;
    path)   echo "$out" ;;
    exec)   shift; ensure_container; exec container exec "$cname" "$@" ;;
    vm|sh)  ensure_container; exec container exec -it "$cname" sh -l ;;
    stop)   container stop "$cname" 2>/dev/null || true ;;
    ""|-h|--help|help) sed -n '2,38p' "$0" ;;
    *)      die "unknown verb '$1' (try: run|start|wait|log|exec|status|path|stage|vm|stop)" ;;
esac
