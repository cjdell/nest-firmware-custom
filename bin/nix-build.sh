#!/bin/sh
# nix-build.sh — run this repo's Linux build and collect the artifacts.
#
# This is the real build, and it is the same on both hosts: bin/nix-build.sh
# firmware on a native Linux machine, or the identical call inside the Apple
# container VM (bin/container.sh). Nothing Mac- or host-specific happens here,
# which is what lets a Mac clone and a NixOS box produce the same uImage bytes.
#
# `./build` is the friendly entry point; call this directly only when you want
# to drive the build yourself.
#
# Usage:  bin/nix-build.sh [TARGET ...]      (TARGET default: firmware)
#   TARGET = a packages.<system>.* attribute: firmware, nest-ondevice,
#            initramfs, default.
#
# Environment:
#   NEST_SRC       repo to build           (default /src; ./build passes the checkout)
#   NEST_OUT       artifact directory      (default /out;  ./build passes ./dist)
#   NEST_ATTACK    vendored GTVHacker tree (default /nest/attack; ./build ./NestDFUAttack)
#   NEST_SYSTEM    nix system              (default "$(uname -m)-linux")
#   NEST_LINUX_TAR pre-archived Dev/linux  (case-exact, made by bin/container.sh)
#   NEST_HOST_REV  recorded in the manifest
#
# Artifacts are copied to $NEST_OUT next to a <target>.manifest (provenance) and
# a <file>.sha256 per artifact. Nothing here flashes anything.
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
    echo "nix-build: no flake.nix at $src — stage the repo first" >&2
    exit 1
fi

# Evaluate a *filtered* copy of the flake source: a few hundred KB instead of
# the 1.3 GB checkout, and not invalidated by artifacts landing in dist/.
# See bin/flake-src.sh.
flake=$(sh "$(dirname "$0")/flake-src.sh" "$src")
echo "nix-build: flake source $flake"

# The vendored kernel is a git checkout. On a case-insensitive filesystem
# (macOS, and the virtiofs mount of it) git's case-distinct netfilter sources
# collapse onto one on-disk name, so make cannot find e.g.
# net/netfilter/xt_HL.c. Re-materialise Dev/linux case-exactly onto this
# case-sensitive filesystem — but only for the targets that read the kernel, so
# `./build server` stays fast.
need_linux=0
for t in "$@"; do
    case $t in
        firmware | default | nestQemuKernel | nestQemu* | qemu) need_linux=1 ;;
    esac
done

fixed=${NEST_LINUX_FIXED:-/tmp/nest-linux-fixed}
if [ "$need_linux" = 0 ]; then
    echo "nix-build: kernel not needed for these targets, skipping the case-fix"
elif [ -n "${NEST_LINUX_TAR:-}" ] && [ -f "$NEST_LINUX_TAR" ]; then
    # Case-exact kernel pre-archived on the host (bin/container.sh); extract
    # it onto this case-sensitive filesystem before nix reads it.
    rm -rf "$fixed"
    mkdir -p "$fixed"
    tar -x -C "$fixed" < "$NEST_LINUX_TAR"
    export NEST_LINUX_DIR="$fixed/Dev/linux"
    echo "nix-build: case-fixed kernel (tar) -> $NEST_LINUX_DIR"
elif [ -e "$attack/.git" ] && command -v git >/dev/null 2>&1; then
    # No pre-made archive: re-materialise Dev/linux from git directly. This is
    # the native-Linux path and also works for a self-contained checkout; an
    # *absorbed* submodule has its gitdir outside the mount and relies on the
    # host archive above.
    #
    # Doing this on *both* hosts matters for reproducibility, not just case:
    # `git archive` feeds the build exactly the tracked tree, so an untracked
    # or edited file in one checkout cannot make that host's image differ.
    rm -rf "$fixed"
    mkdir -p "$fixed"
    git -C "$attack" -c safe.directory='*' archive --format=tar HEAD Dev/linux \
        | tar -x -C "$fixed"
    export NEST_LINUX_DIR="$fixed/Dev/linux"
    echo "nix-build: case-fixed kernel (git) -> $NEST_LINUX_DIR"
fi

mkdir -p "$out"

# Scratch for the nix store-path lists (they end up in the manifest, not in
# dist/).
work=$(mktemp -d "${TMPDIR:-/tmp}/nest-build.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

collect() {
    # Copy the real artifacts out of a store path and echo what was copied,
    # so the caller can checksum exactly those files.
    p=$1
    if [ -f "$p" ]; then
        cp -f "$p" "$out/$(basename "$p")"
        basename "$p"
        return
    fi
    for f in "$p"/uImage "$p"/uImage.sha256 "$p"/initramfs.cpio "$p"/bin/nest-ondevice; do
        if [ -f "$f" ]; then
            cp -f "$f" "$out/$(basename "$f")"
            basename "$f"
        fi
    done
}

for target in "$@"; do
    echo "=== [nix] building packages.$system.$target ==="
    # The store paths go in a scratch file, not in dist/: dist/ holds artifacts
    # and their checksums, and nothing else.
    paths=$work/$target.paths
    nix build --impure --no-link --print-out-paths -L \
        --expr "let f = builtins.getFlake \"$flake\"; in f.packages.$system.$target" \
        > "$paths"
    cat "$paths"
    copied=$(while read -r p; do
                 if [ -n "$p" ]; then collect "$p"; fi
             done < "$paths")

    {
        printf 'target: %s\n'        "$target"
        printf 'system: %s\n'        "$system"
        printf 'host-revision: %s\n' "${NEST_HOST_REV:-unknown}"
        printf 'built: %s\n'         "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'kernel: %s %s\n'     "$(uname -m)" "$(uname -r)"
        printf 'nix: %s\n'           "$(nix --version)"
        printf 'source: %s\n'        "$src"
        printf 'flake-source: %s\n'  "$flake"
        printf 'store-paths:\n'
        sed 's/^/  /' "$paths"
    } > "$out/$target.manifest"

    # Checksum sidecar per artifact, so the image is identifiable before
    # flashing and `sha256sum -c <file>.sha256` works in dist/. This is the
    # number to compare between two hosts: identical bytes mean the same image.
    for f in $copied; do
        case $f in
            *.sha256) ;;                       # already a checksum
            *)
                if [ -f "$out/$f" ] && [ ! -f "$out/$f.sha256" ]; then
                    ( cd "$out" && sha256sum "$f" > "$f.sha256" )
                fi
                if [ -f "$out/$f.sha256" ]; then cat "$out/$f.sha256"; fi
                ;;
        esac
    done
    echo "--- ^ sha256 (must match on every build host) ---"
done

echo "=== [nix] done — artifacts in $out ==="
