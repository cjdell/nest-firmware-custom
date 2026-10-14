#!/usr/bin/env python3
"""Inject the nest-ondevice server into a GTVHacker newc initramfs.

Operates purely at the cpio archive level: existing entries (including device
nodes and symlinks) are copied verbatim, so no root/`mknod` is required. That
matters because Nix builds run unprivileged and cannot recreate /dev entries.

Usage:
  inject_initramfs.py BASE.cpio OUT.cpio BINARY INIT_SCRIPT MONITRC INSTALLER NOSLEEP

The installer (firmware/rootfs-install.sh) and nosleep (firmware/nosleep.init)
ship as files in the initramfs; rootme only gets a one-line call, so the logic
is a real script we can run against a fixture instead of a string baked into an
archive. ./build test (firmware/test-image.sh) does exactly that.
"""
import sys

MAGIC = b"070701"


def parse(data):
    entries = []
    i = 0
    n = len(data)
    while i < n:
        if data[i : i + 6] != MAGIC:
            raise SystemExit(f"bad cpio magic at offset {i}")
        hdr = data[i : i + 110]
        f = [int(hdr[6 + 8 * j : 6 + 8 * (j + 1)], 16) for j in range(13)]
        (ino, mode, uid, gid, nlink, mtime, filesize, _dmaj, _dmin,
         _rmaj, _rmin, namesize, _check) = f
        name_off = i + 110
        name = data[name_off : name_off + namesize - 1].decode("utf-8", "surrogateescape")
        i = name_off + namesize
        i = (i + 3) & ~3
        body = data[i : i + filesize]
        i = (i + filesize + 3) & ~3
        entries.append([ino, mode, uid, gid, nlink, mtime, name, body, _rmaj, _rmin])
        if name == "TRAILER!!!":
            break
    return entries


def header(ino, mode, uid, gid, nlink, mtime, name, size, rmaj=0, rmin=0):
    name_b = name.encode("utf-8", "surrogateescape") + b"\0"
    fields = [ino, mode, uid, gid, nlink, mtime, size, 0, 0, rmaj, rmin, len(name_b), 0]
    out = MAGIC + b"".join(b"%08X" % (v & 0xFFFFFFFF) for v in fields) + name_b
    out += b"\0" * ((4 - (len(out) % 4)) % 4)
    return out


def emit(entry):
    ino, mode, uid, gid, nlink, mtime, name, body, rmaj, rmin = entry
    out = header(ino, mode, uid, gid, nlink, mtime, name, len(body), rmaj, rmin)
    out += body
    out += b"\0" * ((4 - (len(body) % 4)) % 4)
    return out


INSTALL_BLOCK = b"""
# --- nest-ondevice (injected by the nest-ondevice flake) ---
# Everything this image changes on the flash root lives in
# /etc/init.d/nest-ondevice-install (firmware/rootfs-install.sh): idempotent,
# guarded, and logged to /etc/nest-ondevice-install.log on the flash root. It
# must run before the umount below, or the writes land in the initramfs tmpfs
# and vanish (AGENTS.md trap 5).
sh /etc/init.d/nest-ondevice-install
# --- end nest-ondevice ---
"""


def patch_rootme(body):
    if b"nest-ondevice (injected by the nest-ondevice flake)" in body:
        return body
    lines = body.split(b"\n")
    # Insert *before* the flash is unmounted, otherwise the copies land in the
    # initramfs tmpfs instead of mtdblock7. Fall back to just before reboot.
    idx = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith(b"umount") and b"/tmp/1" in s:
            idx = i
            break
    if idx is None:
        for i in range(len(lines) - 1, -1, -1):
            if lines[i].strip() == b"reboot":
                idx = i
                break
    if idx is None:
        idx = len(lines)
    return b"\n".join(lines[:idx] + INSTALL_BLOCK.strip(b"\n").split(b"\n") + lines[idx:])


def main():
    (base_path, out_path, bin_path, init_path, monitrc_path,
     installer_path, nosleep_path) = sys.argv[1:8]
    with open(base_path, "rb") as fh:
        entries = parse(fh.read())
    with open(bin_path, "rb") as fh:
        binary = fh.read()
    with open(init_path, "rb") as fh:
        init = fh.read()
    with open(monitrc_path, "rb") as fh:
        monitrc = fh.read()
    with open(installer_path, "rb") as fh:
        installer = fh.read()
    with open(nosleep_path, "rb") as fh:
        nosleep = fh.read()

    payload = (
        ("usr/bin/nest-ondevice", 0o100755, binary),
        ("etc/init.d/nest-ondevice", 0o100755, init),
        ("etc/init.d/nest-ondevice-install", 0o100755, installer),
        ("etc/init.d/nosleep", 0o100755, nosleep),
        ("etc/monit.d/nest-ondevice.monitrc", 0o100644, monitrc),
    )
    wanted = {name: (mode, body) for name, mode, body in payload}

    next_ino = 0x10000
    for e in entries:
        if e[0] >= next_ino:
            next_ino = e[0] + 1

    out = []
    patched_rootme = False
    for e in entries:
        name = e[6]
        if name == "etc/init.d/rootme":
            e[7] = patch_rootme(e[7])
            patched_rootme = True
        elif name in wanted:
            # Injecting into an image we already built: update the existing
            # entry where it sits instead of adding a second copy of the path.
            e[1], e[7] = wanted[name]
            del wanted[name]
        if name != "TRAILER!!!":
            out.append(emit(e))
        else:
            # Anything still missing goes in just before the trailer.
            for path, mode, body in payload:
                if path in wanted:
                    out.append(emit([next_ino, mode, 0, 0, 1, 0, path, body, 0, 0]))
                    next_ino += 1
            out.append(emit(e))

    if not patched_rootme:
        raise SystemExit("base initramfs has no etc/init.d/rootme")

    with open(out_path, "wb") as fh:
        fh.write(b"".join(out))
    print(f"injected nest-ondevice ({len(binary)} bytes) -> {out_path}")


if __name__ == "__main__":
    main()
