#!/usr/bin/env bash
# repro-check.sh — is the build bit-reproducible?
#
# Builds the firmware more than one way and compares the resulting uImage
# byte-for-byte. Anything that differs between two builds of the same source is
# a leak: a timestamp, a hostname, a temp directory, or job count.
#
# Usage:
#   ./build repro                    all variants, both artifacts
#   ./build repro baseline rebuild   only these variants
#   REPRO_FRESH=1 ./build repro      force real rebuilds, not cached outputs
#
# Each variant is the same flake package with overrideAttrs { forceRebuild =
# "<label>"; }, which changes the derivation hash and so defeats the cache
# without touching the source. TMPDIR differs per variant as well.
#
# The firmware and the ARM server binary are compared separately — they are
# different artifacts, and a firmware digest next to a binary's is meaningless.
#
# Why this matters: the point of the exercise is that a build driven from the
# Mac (aarch64, i686 tools under qemu) and a native amd64 build must produce the
# same bytes, because the sha256 is how you know the image you flashed is the
# image you built. Run it after changing anything in firmware/.
set -uo pipefail

repo=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
attack=${NEST_ATTACK_DIR:-$repo/NestDFUAttack}
work=${TMPDIR:-/tmp}/nest-repro
[ -d "$attack/Dev/linux" ] || { echo "no kernel tree at $attack/Dev/linux" >&2; exit 1; }

# Same rule as bin/nix-build.sh: x86_64-linux / aarch64-linux.
system=${NEST_SYSTEM:-$(uname -m)-linux}

# "all" (or no args) = every variant; anything else filters by label.
if [ "${1:-}" = all ]; then shift; fi

mkdir -p "$work"
export NEST_ATTACK_DIR=$attack
# `build-users-group =` matters: the macOS build container has no nixbld group,
# and nix fails outright rather than building unprivileged without this line
# (bin/nix-build.sh has always carried it).
export NIX_CONFIG="experimental-features = nix-command flakes
build-users-group ="

# Same filtered flake source the real builds use (bin/nix-build.sh).
flake=$(sh "$repo/bin/flake-src.sh" "$repo")

# Variants. Each row: label|kind|flake-attr|extra-env
#   baseline        reference build
#   rebuild         same build, forced again, in a different TMPDIR
#   qemu-toolchain  same i686 tools run through qemu-i386 instead of natively —
#                   the path the amd64 build container takes. A no-op on
#                   aarch64, where default.nix already chose qemu because the
#                   i686 binaries cannot exec there at all. The variable is
#                   NEST_TOOLCHAIN, which is what firmware/default.nix reads;
#                   an earlier name here was never read by anything, so this
#                   variant rebuilt the baseline and reported "identical".
#   jobs1           single-job make, to catch parallelism leaking into output
#   kernel-git      kernel tree extracted with `git archive` (the Mac path)
#                   rather than `cp -a` (the Linux path)
#   server-a/b      two independent builds of the ARM binary, compared to each
#                   other
# Add rows as more suspects turn up. No spaces in a row: the loop word-splits.
variants() {
    cat <<'EOF'
baseline|firmware|firmware|
rebuild|firmware|firmware|
qemu-toolchain|firmware|firmware|NEST_TOOLCHAIN=qemu
jobs1|firmware|firmware|NIX_BUILD_OPTIONS=-j1
kernel-git|firmware|firmware|
server-a|server|nest-ondevice|
server-b|server|nest-ondevice|
EOF
}

# --rebuild makes nix redo work it already has, so REPRO_FRESH=1 turns this into
# a genuine from-scratch test instead of a comparison of cached outputs.
nix_extra=()
if [ "${REPRO_FRESH:-}" = 1 ]; then
    nix_extra+=(--rebuild)
fi

# One digest per artifact, as plain hex: the uImage for the firmware, the binary
# for the server. These are the numbers the other host has to match, so print
# what `sha256sum dist/uImage` prints rather than a tree hash.
digest() {
    local out=$1 f
    f=$(find "$out" -maxdepth 1 -type f -name uImage | head -1)
    [ -n "$f" ] || f=$(find "$out/bin" -maxdepth 1 -type f 2>/dev/null | head -1)
    [ -n "$f" ] || f=$(find "$out" -type f | head -1)
    sha256sum "$f" | cut -d' ' -f1
}

echo "repro: packages.$system.* variant='${*:-all}' on $(uname -m) ($(nix --version), fresh=${REPRO_FRESH:-no})"
echo "workdir: $work"

ref_firmware=''
ref_server=''
fail=0
echo
while IFS='|' read -r label kind attr extra; do
    [ -n "$label" ] || continue
    if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$label"; then continue; fi

    mkdir -p "$work/$label"
    if [ "$label" = kernel-git ] && [ ! -d "$work/kernel-git" ]; then
        mkdir -p "$work/kernel-git"
        ( cd "$attack" && git archive HEAD Dev/linux ) | tar -x -C "$work/kernel-git" --strip-components=1
    fi

    if ! out=$(env TMPDIR="$work/$label" ${extra:+$extra} nix build --impure --no-link \
            --print-out-paths ${nix_extra[@]+"${nix_extra[@]}"} -L \
            --expr "let f = builtins.getFlake \"$flake\";
                    in f.packages.$system.$attr.overrideAttrs { forceRebuild = \"$label\"; }" \
            > "$work/$label.out" 2> "$work/$label.log"); then
        echo "$label  BUILD FAILED — see $work/$label.log"
        tail -5 "$work/$label.log"
        exit 1
    fi
    out=$(cat "$work/$label.out")

    d=$(digest "$out")
    if [ "$kind" = firmware ]; then ref=$ref_firmware; else ref=$ref_server; fi
    if [ -z "$ref" ]; then
        if [ "$kind" = firmware ]; then ref_firmware=$d; else ref_server=$d; fi
        printf '%-15s %s…  reference\n' "$label" "${d:0:16}"
    elif [ "$d" = "$ref" ]; then
        printf '%-15s %s…  identical\n' "$label" "${d:0:16}"
    else
        printf '%-15s %s…  DIFFERS (vs %s…)\n' "$label" "${d:0:16}" "${ref:0:16}"
        fail=1
    fi
done < <(variants)

echo
if [ $fail -eq 0 ]; then
    echo "PASS — every variant produced byte-identical output"
else
    echo "FAIL — a variant differed; compare the digests above (outputs in $work/*/)"
fi
exit $fail
