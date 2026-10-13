#!/usr/bin/env python3
"""Inject the nest-ondevice server into a GTVHacker newc initramfs.

Operates purely at the cpio archive level: existing entries (including device
nodes and symlinks) are copied verbatim, so no root/`mknod` is required. That
matters because Nix builds run unprivileged and cannot recreate /dev entries.

Usage:
  inject_initramfs.py BASE.cpio OUT.cpio BINARY INIT_SCRIPT MONITRC
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
mkdir -p /tmp/1/usr/bin
cp /usr/bin/nest-ondevice /tmp/1/usr/bin/nest-ondevice 2>/dev/null || true
chmod 755 /tmp/1/usr/bin/nest-ondevice 2>/dev/null || true
cp /etc/init.d/nest-ondevice /tmp/1/etc/init.d/nest-ondevice 2>/dev/null || true
chmod 755 /tmp/1/etc/init.d/nest-ondevice 2>/dev/null || true
# monit config: the init script starts monit when present, and this must live on
# the flash rootfs (mtdblock7) so it survives the initramfs -> flash reboot.
mkdir -p /tmp/1/etc/monit.d
cp /etc/monit.d/nest-ondevice.monitrc /tmp/1/etc/monit.d/nest-ondevice.monitrc 2>/dev/null || true
# The GTVHacker rootme appends `/bin/sshconnect` (an infinite autossh loop) to
# rcS. It runs in the foreground and blocks rcS forever, so anything appended
# after it -- including this server -- never starts. Drop it, de-dupe dropbear,
# then make sure our start line is present.
if [ -f /tmp/1/etc/init.d/rcS ]; then
  sed -i '/\/bin\/sshconnect/d' /tmp/1/etc/init.d/rcS
  awk '!(/^\/bin\/dropbear$/ && seen++)' /tmp/1/etc/init.d/rcS > /tmp/1/etc/init.d/rcS.nle
  mv /tmp/1/etc/init.d/rcS.nle /tmp/1/etc/init.d/rcS
  if ! grep -q 'nest-ondevice start' /tmp/1/etc/init.d/rcS; then
    echo '${INITDIR}/nest-ondevice start' >> /tmp/1/etc/init.d/rcS
  fi
fi
# monit reads /etc/monitrc at boot; add our include so the daemon is supervised.
if [ -f /tmp/1/etc/monitrc ] && ! grep -q 'nest-ondevice.monitrc' /tmp/1/etc/monitrc; then
  echo 'include /etc/monit.d/nest-ondevice.monitrc' >> /tmp/1/etc/monitrc
fi
# --- temporary diagnostic access: known root password ---
if [ -f /tmp/1/etc/shadow ]; then
  grep -v '^root:' /tmp/1/etc/shadow > /tmp/1/etc/shadow.nle
  echo 'root:neID3wejfFjiA:16243:0:99999:7:::' >> /tmp/1/etc/shadow.nle
  mv /tmp/1/etc/shadow.nle /tmp/1/etc/shadow
  chmod 600 /tmp/1/etc/shadow
fi

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
    base_path, out_path, bin_path, init_path, monitrc_path = sys.argv[1:6]
    with open(base_path, "rb") as fh:
        entries = parse(fh.read())
    with open(bin_path, "rb") as fh:
        binary = fh.read()
    with open(init_path, "rb") as fh:
        init = fh.read()
    with open(monitrc_path, "rb") as fh:
        monitrc = fh.read()

    next_ino = 0x10000
    for e in entries:
        if e[0] >= next_ino:
            next_ino = e[0] + 1

    out = []
    replaced = False
    for e in entries:
        name = e[6]
        if name == "etc/init.d/rootme":
            e[7] = patch_rootme(e[7])
            replaced = True
            out.append(emit(e))
        elif name == "TRAILER!!!":
            # add our files just before the trailer
            out.append(emit([next_ino, 0o100755, 0, 0, 1, 0, "usr/bin/nest-ondevice", binary, 0, 0]))
            next_ino += 1
            out.append(emit([next_ino, 0o100755, 0, 0, 1, 0, "etc/init.d/nest-ondevice", init, 0, 0]))
            next_ino += 1
            out.append(emit([next_ino, 0o100644, 0, 0, 1, 0, "etc/monit.d/nest-ondevice.monitrc", monitrc, 0, 0]))
            next_ino += 1
            out.append(emit(e))
        else:
            out.append(emit(e))

    if not replaced:
        raise SystemExit("base initramfs has no etc/init.d/rootme")

    with open(out_path, "wb") as fh:
        fh.write(b"".join(out))
    print(f"injected nest-ondevice ({len(binary)} bytes) -> {out_path}")


if __name__ == "__main__":
    main()
