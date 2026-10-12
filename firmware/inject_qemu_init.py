#!/usr/bin/env python3
"""Append a /qemu-init entry to an already-injected newc cpio.

Archive-level, like inject_initramfs.py (no root/mknod). Reuses that script's
parse/emit by importing it from the path given as the last argument.

Usage:
  inject_qemu_init.py IN.cpio OUT.cpio INIT_SCRIPT HELPER.py
"""
import importlib.util
import sys


def load_module(path):
    spec = importlib.util.spec_from_file_location("inject_initramfs", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    in_cpio, out_cpio, init_script, helper = sys.argv[1:5]
    inj = load_module(helper)

    with open(in_cpio, "rb") as fh:
        entries = inj.parse(fh.read())
    with open(init_script, "rb") as fh:
        init = fh.read()

    next_ino = 0x20000
    for e in entries:
        if e[0] >= next_ino:
            next_ino = e[0] + 1

    out = []
    for e in entries:
        if e[6] == "TRAILER!!!":
            out.append(inj.emit([next_ino, 0o100755, 0, 0, 1, 0, "qemu-init", init, 0, 0]))
            next_ino += 1
        out.append(inj.emit(e))

    with open(out_cpio, "wb") as fh:
        fh.write(b"".join(out))
    print(f"added /qemu-init ({len(init)} bytes) -> {out_cpio}")


if __name__ == "__main__":
    main()
