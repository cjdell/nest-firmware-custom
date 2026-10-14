#!/bin/sh
# container.sh — the Linux build host for a Mac: Apple's `container` runtime
# plus a NixOS Linux VM.
#
# You normally do not call this directly. `./build` is the entry point: on Linux
# it runs bin/nix-build.sh in place, on macOS it dispatches here. Both end up
# running the *same* build script, which is why one host rebuilds the same bytes
# every time (bin/repro-check.sh proves the parts that differ). "Same script" is
# not "same image as the other architecture": see the ARCH note below and
# firmware/README.md, "Build-host architecture".
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
# ARCH. The default builder is an arm64 VM. An amd64 VM (Rosetta) is available
# with NEST_VM_ARCH=amd64 and is *not* the default, for two reasons.
#
# 1. It does not work. Rosetta-for-Linux does not preserve a custom argv[0]
#    across exec: `bash -c 'exec -a MARKER bash -c "echo $0"'` prints the
#    resolved binary path there, and the real name on a native host (arm64
#    container and x86_64 both preserve it). nixpkgs' python envs are C
#    trampolines that find their prefix from argv[0], so with Rosetta the
#    env-python reports the bare interpreter as its prefix and every
#    autoPatchelfHook dies — the first thing the firmware build hits is
#    rust-std: "ModuleNotFoundError: No module named 'elftools'". A host that
#    mangles argv[0] is also a host that can silently change build output, so
#    it is the wrong place to build a flashable image even if that one build
#    were patched around. binfmt_misc cannot be mounted in an Apple container
#    either, so qemu-user x86_64 is not available as a substitute.
# 2. Host architecture does change the bytes, and no knob fixes it. See
#    firmware/README.md, "Build-host architecture": the 2008 i686 ARM
#    cross-compiler under qemu-i386 on aarch64 emits 328 bytes of different ARM
#    code, and rustc emits one extra .ARM.exidx entry, shifting the server
#    binary by 16 bytes. Both are deterministic per host — an aarch64 Mac
#    rebuilds its own bytes forever — they just are not x86_64's bytes. To
#    produce the canonical x86_64 image from this Mac, build on a real x86_64
#    Linux host: ./build firmware with NEST_BUILD_HOST set (see below).
#
# Overrides:
#   NEST_VM_ARCH       arm64 (default) | amd64 (Rosetta; see the ARCH note)
#   NEST_VM_CACHE      ~/.cache/nest-build   (staged repo, VM logs, artifacts)
#   NEST_VM_CONTAINER  nest-builder-<arch>   (container name)
#   NEST_VM_IMAGE      rzmapp/nixos-vm:26.05 (arm64) / nixos/nix:2.34.8-amd64
#   NEST_VM_CPUS       8
#   NEST_VM_MEMORY     12g
#   NEST_VM_POLL       5    (seconds between ./build progress polls)
#   NEST_TOOLCHAIN     auto|native|qemu for the i686 2008 tools (amd64 forces qemu)
#   NEST_NIX_CONFIG_EXTRA  appended to nix's config inside the VM
#   NEST_ATTACK_DIR    the vendored NestDFUAttack tree (default ./NestDFUAttack)
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
cache=${NEST_VM_CACHE:-$HOME/.cache/nest-build}
src=$cache/src
out=$cache/out
certs=$cache/certs
cpus=${NEST_VM_CPUS:-8}
memory=${NEST_VM_MEMORY:-12g}
attack=${NEST_ATTACK_DIR:-$repo/NestDFUAttack}

die() { echo "container: $*" >&2; exit 1; }

# Per-arch defaults; see the ARCH note at the top of this file.
arch=${NEST_VM_ARCH:-arm64}
case $arch in
    amd64 | x86_64)
        arch=amd64
        image=${NEST_VM_IMAGE:-docker.io/nixos/nix:2.34.8-amd64}
        # Rosetta translates x86_64 only, so the i686 2008 toolchain can never
        # exec natively here; firmware/default.nix would pick `native` on
        # x86_64 by default, so say `qemu` explicitly. Verified to produce the
        # same bytes as native (firmware/README.md, "Reproducible images").
        toolchain=${NEST_TOOLCHAIN:-qemu}
        # nix installs a seccomp BPF filter around every build; the kernel this
        # container runs under rejects one for a foreign-arch guest, so nix dies
        # with "unable to load seccomp BPF program: Invalid argument". The
        # filter is a sandbox, not an input.
        nix_extra=${NEST_NIX_CONFIG_EXTRA:-filter-syscalls = false}
        ;;
    arm64 | aarch64)
        arch=arm64
        image=${NEST_VM_IMAGE:-docker.io/rzmapp/nixos-vm:26.05}
        toolchain=${NEST_TOOLCHAIN:-auto}
        nix_extra=${NEST_NIX_CONFIG_EXTRA:-}
        ;;
    *)
        die "NEST_VM_ARCH must be amd64 or arm64, got '$arch'"
        ;;
esac
cname=${NEST_VM_CONTAINER:-nest-builder-$arch}

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

# virtiofs binds each source path when the container is *created*, and
# `container create` is skipped whenever the name already exists. A builder
# left over from another checkout (or from before the cache directory moved)
# therefore keeps mounting the old directories: the build silently runs on
# stale sources and exports stale artifacts. Refuse rather than do that.
assert_mounts() {
    # container inspect JSON escapes slashes in paths, so strip them (and all
    # whitespace) before matching a plain host path.
    cfg=$(container inspect "$cname" 2>/dev/null | tr -d '[:space:]\\')
    [ -n "$cfg" ] || return 0        # older CLI without inspect: cannot check
    for want in "$src" "$out" "$attack"; do
        case $cfg in
            *"\"source\":\"$want\""*) ;;
            *)
                die "$cname was created for a different tree: it does not mount $want.
         Recreate it: container stop $cname 2>/dev/null; container delete $cname"
                ;;
        esac
    done
}

ensure_container() {
    need_container
    if exists; then
        assert_mounts
        running || { echo "container: starting $cname" >&2; container start "$cname" >/dev/null; }
        return
    fi
    echo "container: creating $cname from $image ($cpus cpus, $memory, arch $arch)" >&2
    container image pull --arch "$arch" "$image" >/dev/null 2>&1 ||
        echo "container: could not pull $image (using a local copy if present)" >&2
    container create --name "$cname" --arch "$arch" --cpus "$cpus" --memory "$memory" \
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

    # Hand the VM the path *it* sees, not ours: $out is mounted at /out. Passing
    # the host path makes nix-build.sh fall through to its `git archive` fallback
    # inside the container, and that cannot work here either — a submodule
    # checkout's gitdir lives outside the mount, so the archive can only be made
    # on the host.
    container exec -d "$cname" sh -c \
        "NEST_HOST_REV='$rev' NEST_SRC=/src NEST_OUT=/out NEST_ATTACK=/nest/attack \
         NEST_LINUX_TAR=${linux_tar:+/out/.attack-linux.tar} NEST_TOOLCHAIN='$toolchain' \
         NEST_NIX_CONFIG_EXTRA='$nix_extra' \
         sh /src/bin/nix-build.sh $target > /out/$target.log 2>&1; \
         echo \$? > /out/$target.rc" \
        >/dev/null

    echo "container: $target building in $cname (rev ${rev:-unknown}, arch $arch, toolchain $toolchain)" >&2
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
    ""|-h|--help|help) awk 'NR==1 { next } /^set -eu/ { exit } { print }' "$0" ;;
    *)      die "unknown verb '$1' (try: run|start|wait|log|exec|status|path|stage|vm|stop)" ;;
esac
