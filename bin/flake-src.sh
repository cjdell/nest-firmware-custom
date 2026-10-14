#!/bin/sh
# flake-src.sh — print a store path holding *just* the flake source.
#
# builtins.getFlake copies the directory it is pointed at into the nix store
# before evaluating. Pointed at the checkout that is 1.3 GB and ~11 s per
# invocation, because it drags in the NestDFUAttack submodule (884 MB), the
# sibling reference clones, dist/ artifacts and the ./result* symlinks — none of
# which the flake reads. The kernel/initramfs/toolchain tree it does need comes
# from NEST_ATTACK_DIR, an absolute path outside the source.
#
# So filter it: the source becomes a few MB, rebuilds stop being invalidated by
# writing artifacts into dist/, and a dirty working tree cannot change what the
# flake sees. Both bin/nix-build.sh and bin/repro-check.sh go through here, so
# the two build hosts evaluate the same source.
#
# Usage: flake-src.sh [repo]        (default: the repo this script lives in)
set -eu

src=${1:-$(cd "$(dirname "$0")/.." && pwd)}

nix eval --impure --raw --expr "
  builtins.path {
    name = \"nest-src\";
    path = /. + "$src";
    filter = p: t:
      let b = baseNameOf p;
      in !(
           builtins.elem b [
             \".git\" \".direnv\" \".venv\" \"target\" \"node_modules\"
             \"__pycache__\" \"NestDFUAttack\" \"NoLongerEvil-SelfHosted\"
             \"NoLongerEvil-Thermostat\" \"hubitatcontrol\"
           ]
           # Only the *root* dist/, where ./build drops artifacts. A basename
           # match here also ate nest-ondevice-server/ui/dist, which is tracked
           # and read by the flake's fileset (the embedded SPA) — the firmware
           # derivation then failed to evaluate at all.
           || p == \"$src/dist\"
           # ./result and ./result-* are symlinks into the store
           || t == \"symlink\"
           || builtins.match \"result.*\" b != null
           || builtins.match \".*\\.pyc\" b != null
         );
  }
"
