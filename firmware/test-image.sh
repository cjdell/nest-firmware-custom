#!/usr/bin/env bash
# test-image.sh — exercise the two pieces of the firmware image that run on the
# thermostat, without a thermostat.
#
#   ./firmware/test-image.sh
#
# Suite 1 runs firmware/rootfs-install.sh against a fixture that imitates the
# factory flash root (the real one is not in this repo — NestDFUAttack/Dev/root
# is an older dump with no nlsleep at all), twice, and checks both what it
# changes and that a second run changes nothing.
#
# Suite 2 runs firmware/inject_initramfs.py against a synthetic initramfs and
# checks the result: the installer is embedded, rootme calls it *before* it
# unmounts the flash root (AGENTS.md trap 5), and /dev nodes keep their
# major/minor (trap 6).
#
# Exits non-zero if anything fails.

set -u
cd "$(dirname "$0")/.."
HERE=$PWD

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
check() {  # check <description> <command...>
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then ok; else bad "$desc"; fi
}
check_eq() {  # check_eq <description> <command> <expected>
    local desc=$1 cmd=$2 want=$3 got
    got=$(eval "$cmd" 2>/dev/null)
    if [ "$got" = "$want" ]; then ok; else bad "$desc (got '$got', want '$want')"; fi
}

# ---------------------------------------------------------------------------
# Suite 1: the flash-root installer
# ---------------------------------------------------------------------------
echo "== rootfs-install.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
MARK='DISABLED-by-nest-ondevice'

# A root that looks like the factory one where it matters: the sshconnect loop
# and the duplicated dropbear rootme leaves behind (trap 11), the nlsleep
# start/stop calls (traps 14/15), nlsleepd and nlshutdownd sharing a monit file
# (trap 14), plus canaries that must survive untouched.
make_root() {  # make_root DIR
    local r=$1
    mkdir -p "$r/etc/init.d" "$r/etc/monit.d" "$r/usr/bin"
    cat > "$r/etc/init.d/rcS" <<'FIXTURE'
#!/bin/sh
# start nlsleep at boot
/sbin/udevtrigger
/bin/mount -a
${INITDIR}/dm start
${INITDIR}/nlsleep start
${INITDIR}/nlscpm start
${INITDIR}/nlshutdownd start
/bin/dropbear
/bin/dropbear
/bin/sshconnect
FIXTURE
    cat > "$r/etc/init.d/rcH" <<'FIXTURE'
#!/bin/sh
${INITDIR}/nlsleep stop
${INITDIR}/dm stop
FIXTURE
    cat > "$r/etc/monit.d/nlscpm.monitrc" <<'FIXTURE'
check process nlsleepd with pidfile /var/run/nlsleepd.pid
    start program = "/etc/init.d/nlsleep start"
    stop program  = "/etc/init.d/nlsleep stop"
check process nlshutdownd with pidfile /var/run/nlshutdownd.pid
    start program = "/etc/init.d/nlshutdownd start"
FIXTURE
    cat > "$r/etc/monitrc" <<'FIXTURE'
set daemon 60
include /etc/monit.d
FIXTURE
    cat > "$r/etc/shadow" <<'FIXTURE'
root:OLDHASHGOESHERE:16000:0:99999:7:::
daemon:x:1:0:99999:7:::
FIXTURE
}

# The initramfs side: what the installer copies out of the running initramfs.
SRC=$T/src
mkdir -p "$SRC/etc/init.d" "$SRC/etc/monit.d" "$SRC/usr/bin"
echo 'ARM-FAKE-ELF' > "$SRC/usr/bin/nest-ondevice"
printf '#!/bin/sh\n# fake nest-ondevice init\n' > "$SRC/etc/init.d/nest-ondevice"
cp firmware/nosleep.init "$SRC/etc/init.d/nosleep"
cp firmware/nest-ondevice.monitrc "$SRC/etc/monit.d/nest-ondevice.monitrc"

ROOT=$T/root
make_root "$ROOT"
run_installer() {  # run_installer DIR
    NEST_ROOT="$1" NEST_SRC="$SRC" sh firmware/rootfs-install.sh > "$T/out" 2>&1
}

run_installer "$ROOT"
if [ $? -ne 0 ]; then bad "installer exited non-zero"; else ok; fi

RCS=$ROOT/etc/init.d/rcS
RCH=$ROOT/etc/init.d/rcH
MON=$ROOT/etc/monit.d/nlscpm.monitrc

check_eq "sshconnect removed from rcS"      "grep -c sshconnect '$RCS'" 0
check_eq "one dropbear left in rcS"         "grep -c '^/bin/dropbear$' '$RCS'" 1
check_eq "nlsleep start disabled once"      "grep -c '^[[:space:]]*#$MARK \${INITDIR}/nlsleep start' '$RCS'" 1
check_eq "nosleep start added once"         "grep -c '^\${INITDIR}/nosleep start$' '$RCS'" 1
check_eq "nest-ondevice start added once"   "grep -c '^\${INITDIR}/nest-ondevice start$' '$RCS'" 1
check_eq "nlscpm canary untouched"          "grep -c '^\${INITDIR}/nlscpm start$' '$RCS'" 1
check_eq "comment canary not re-marked"     "grep -c \"$MARK.*start nlsleep at boot\" '$RCS'" 0
check_eq "nlsleep stop disabled in rcH"     "grep -c '^[[:space:]]*#$MARK \${INITDIR}/nlsleep stop' '$RCH'" 1
check_eq "dm stop untouched in rcH"         "grep -c '^\${INITDIR}/dm stop$' '$RCH'" 1
check_eq "nlsleepd check disabled"          "grep -c '^#$MARK check process nlsleepd' '$MON'" 1
check_eq "nlsleepd children disabled"       "grep -c \"^#$MARK start program\" '$MON'" 1
check_eq "nlsleepd stop child disabled"     "grep -c \"^#$MARK stop program\" '$MON'" 1
check_eq "nlshutdownd check kept live"      "grep -c '^check process nlshutdownd' '$MON'" 1
check_eq "nlshutdownd child kept live"      "grep -c '^    start program' '$MON'" 1
check_eq "monit include added once"         "grep -c 'nest-ondevice.monitrc' '$ROOT/etc/monitrc'" 1
check_eq "one root line in shadow"          "grep -c '^root:' '$ROOT/etc/shadow'" 1
check_eq "diagnostic root hash installed"   "grep -c '^root:neID3wejfFjiA:' '$ROOT/etc/shadow'" 1
check_eq "other shadow lines kept"          "grep -c '^daemon:x:' '$ROOT/etc/shadow'" 1

check "server installed"        [ -f "$ROOT/usr/bin/nest-ondevice" ]
check "server executable"       [ -x "$ROOT/usr/bin/nest-ondevice" ]
check "init script installed"   [ -x "$ROOT/etc/init.d/nest-ondevice" ]
check "nosleep installed"       [ -x "$ROOT/etc/init.d/nosleep" ]
check "monitrc installed"       [ -f "$ROOT/etc/monit.d/nest-ondevice.monitrc" ]
check "install log written"     grep -q 'rcS: nlsleep start disabled' "$ROOT/etc/nest-ondevice-install.log"
check "installer is valid sh"   sh -n firmware/rootfs-install.sh
check "nosleep.init is valid sh" sh -n firmware/nosleep.init

# Idempotence: rootme runs on every boot through the DFU image, so a second run
# must leave the tree byte-identical (the install log is allowed to grow).
snap() { (cd "$1" && find . -type f ! -name nest-ondevice-install.log | sort | xargs cksum | cksum); }
BEFORE=$(snap "$ROOT")
run_installer "$ROOT"
if [ "$(snap "$ROOT")" = "$BEFORE" ]; then ok; else bad "second run changed the tree"; fi
check_eq "still one start line after re-run" "grep -c '^\${INITDIR}/nest-ondevice start$' '$RCS'" 1
check_eq "still one dropbear after re-run"   "grep -c '^/bin/dropbear$' '$RCS'" 1

# A root with the pieces we do not control missing: no rcH, no nlscpm.monitrc,
# no monitrc, no shadow. Must still install and still exit 0.
PARTIAL=$T/partial
make_root "$PARTIAL"
rm -f "$PARTIAL/etc/init.d/rcH" "$PARTIAL/etc/monit.d/nlscpm.monitrc" \
      "$PARTIAL/etc/monitrc" "$PARTIAL/etc/shadow"
run_installer "$PARTIAL"
if [ $? -ne 0 ]; then bad "installer failed on a root missing rcH/monit/shadow"; else ok; fi
check "partial root still got the server" [ -x "$PARTIAL/usr/bin/nest-ondevice" ]
check_eq "partial root got start line" \
    "grep -c '^\${INITDIR}/nest-ondevice start$' '$PARTIAL/etc/init.d/rcS'" 1

# A root someone already hand-edited (trap 14 was first fixed on-device): the
# installer must not stack a second marker on those lines.
DONE=$T/done
make_root "$DONE"
sed -i "s|\${INITDIR}/nlsleep start|#$MARK \${INITDIR}/nlsleep start|" "$DONE/etc/init.d/rcS"
run_installer "$DONE"
check_eq "pre-disabled line not marked twice" \
    "grep -c \"$MARK.*$MARK\" '$DONE/etc/init.d/rcS'" 0

# An empty root (flash not mounted) must be a no-op, not a partial write.
EMPTY=$T/empty
mkdir -p "$EMPTY"
run_installer "$EMPTY"
if [ -e "$EMPTY/etc/init.d/rcS" ]; then bad "wrote into an unmounted root"; else ok; fi

# ---------------------------------------------------------------------------
# Suite 2: the initramfs injector
# ---------------------------------------------------------------------------
echo "== inject_initramfs.py"

IN=$T/in
mkdir -p "$IN"
python3 - "$IN/base.cpio" <<'PY'
import sys
sys.path.insert(0, "firmware")
from inject_initramfs import emit

rootme = b"""#!/bin/sh
mount /dev/mtdblock7 /tmp/1
echo 'root::0:0:root:/root:/bin/sh' >> /tmp/1/etc/passwd
/bin/dropbear
/bin/sshconnect
umount /tmp/1
reboot
"""

# Built with the module's own emit() so the fixture is exactly the newc format
# the injector reads. /dev/console carries a real major/minor on purpose.
ents = [
    [1, 0o040755, 0, 0, 1, 0, "etc", b"", 0, 0],
    [2, 0o040755, 0, 0, 1, 0, "etc/init.d", b"", 0, 0],
    [3, 0o100755, 0, 0, 1, 0, "etc/init.d/rootme", rootme, 0, 0],
    [4, 0o040755, 0, 0, 1, 0, "dev", b"", 0, 0],
    [5, 0o020600, 0, 0, 1, 0, "dev/console", b"", 1, 3],
    [6, 0o100000, 0, 0, 1, 0, "TRAILER!!!", b"", 0, 0],
]
with open(sys.argv[1], "wb") as fh:
    for e in ents:
        fh.write(emit(e))
PY
check "fixture cpio built" [ -s "$IN/base.cpio" ]

echo fake-binary > "$IN/nest-ondevice"
printf '#!/bin/sh\n# fake init\n' > "$IN/init"
printf 'check process nest-ondevice\n' > "$IN/monitrc"

inject() {  # inject SRC_CPIO DEST_CPIO
    python3 firmware/inject_initramfs.py "$1" "$2" \
        "$IN/nest-ondevice" "$IN/init" "$IN/monitrc" \
        firmware/rootfs-install.sh firmware/nosleep.init > "$T/inj" 2>&1
}

if inject "$IN/base.cpio" "$IN/out.cpio"; then ok; else bad "injector failed: $(cat "$T/inj")"; fi

python3 - "$IN/out.cpio" "$IN/base.cpio" <<'PY' > "$T/inspect" 2>&1
import sys
sys.path.insert(0, "firmware")
from inject_initramfs import parse


def ents(path):
    return {e[6]: e for e in parse(open(path, "rb").read())}


out, base = ents(sys.argv[1]), ents(sys.argv[2])


def want(cond, msg):
    print(("ok " if cond else "FAIL ") + msg)


for path, mode in (("usr/bin/nest-ondevice", 0o100755),
                   ("etc/init.d/nest-ondevice", 0o100755),
                   ("etc/init.d/nest-ondevice-install", 0o100755),
                   ("etc/init.d/nosleep", 0o100755),
                   ("etc/monit.d/nest-ondevice.monitrc", 0o100644)):
    want(path in out, f"{path} embedded")
    if path in out:
        want(out[path][1] == mode, f"{path} mode is {oct(mode)}")

want(out["etc/init.d/nest-ondevice-install"][7]
     == open("firmware/rootfs-install.sh", "rb").read(),
     "embedded installer is firmware/rootfs-install.sh")

rootme = out["etc/init.d/rootme"][7].decode()
lines = [l.strip() for l in rootme.splitlines() if l.strip()]
call = "sh /etc/init.d/nest-ondevice-install"
want(call in lines, "rootme calls the installer")
umount = [i for i, l in enumerate(lines) if l.startswith("umount") and "/tmp/1" in l]
want(bool(umount) and lines.index(call) < umount[0],
     "installer runs before rootme unmounts the flash root (trap 5)")
want(lines.index(call) < lines.index("reboot"), "installer runs before reboot")
want(rootme.count("nest-ondevice (injected") == 1, "injection marker appears once")

# Trap 6: entries are copied verbatim, so /dev nodes must keep their major and
# minor or an initramfs without devtmpfs cannot open /dev/console.
want((out["dev/console"][8], out["dev/console"][9]) == (1, 3),
     "dev/console kept major/minor 1,3 (trap 6)")
want(out["dev/console"][1] == 0o020600, "dev/console kept its chrdev mode")
want(out["etc/init.d/rootme"][7] != base["etc/init.d/rootme"][7], "rootme was patched")
PY
while read -r line; do
    case $line in
        "FAIL "*) bad "injector: ${line#FAIL }" ;;
        "ok "*) ok ;;
    esac
done < "$T/inspect"
if grep -q '^FAIL ' "$T/inspect"; then bad "see injector checks above"; fi

# The injector is deterministic, and re-injecting must not double-patch.
inject "$IN/base.cpio" "$IN/out2.cpio"
check "injector output is reproducible" cmp -s "$IN/out.cpio" "$IN/out2.cpio"
if inject "$IN/out.cpio" "$IN/out3.cpio"; then ok; else bad "re-injecting failed"; fi
check "re-injecting does not double-patch rootme" python3 -c "
import sys; sys.path.insert(0, 'firmware')
from inject_initramfs import parse
ents = {e[6]: e for e in parse(open('$IN/out3.cpio', 'rb').read())}
sys.exit(0 if ents['etc/init.d/rootme'][7].count(b'injected by the nest-ondevice flake') == 1 else 1)
"
check "re-injecting does not duplicate embedded files" python3 -c "
import sys; sys.path.insert(0, 'firmware')
from inject_initramfs import parse
names = [e[6] for e in parse(open('$IN/out3.cpio', 'rb').read())]
sys.exit(0 if names.count('usr/bin/nest-ondevice') == 1 else 1)
"

echo
# ---------------------------------------------------------------------------
# Suite 3 (optional): the artefact we just built, end to end
# ---------------------------------------------------------------------------
CPIO=${NEST_INITRAMFS:-}
if [ -z "$CPIO" ]; then
    for cand in result/initramfs.cpio dist/initramfs.cpio; do
        [ -f "$cand" ] && { CPIO=$cand; break; }
    done
fi
if [ -n "$CPIO" ]; then
    echo "== $CPIO"
    IMG=$T/img
    mkdir -p "$IMG"
    python3 - "$CPIO" "$IMG" <<'PY'
import os, sys
sys.path.insert(0, "firmware")
from inject_initramfs import parse

for e in parse(open(sys.argv[1], "rb").read()):
    name, mode, body = e[6], e[1], e[7]
    if not name.startswith(("usr/bin/nest-ondevice", "etc/init.d/nest-ondevice",
                           "etc/init.d/nosleep", "etc/monit.d/nest-ondevice")):
        continue
    path = os.path.join(sys.argv[2], name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(body)
    os.chmod(path, mode & 0o777)
PY
    IMGROOT=$T/imgroot
    make_root "$IMGROOT"
    NEST_ROOT="$IMGROOT" NEST_SRC="$IMG" sh "$IMG/etc/init.d/nest-ondevice-install" > "$T/imgout" 2>&1
    if [ $? -ne 0 ]; then bad "the installer inside the image exited non-zero"; else ok; fi
    check_eq "image: nlsleep start disabled" \
        "grep -c '^[[:space:]]*#$MARK \${INITDIR}/nlsleep start' '$IMGROOT/etc/init.d/rcS'" 1
    check_eq "image: server start added" \
        "grep -c '^\${INITDIR}/nest-ondevice start$' '$IMGROOT/etc/init.d/rcS'" 1
    check_eq "image: sshconnect removed" "grep -c sshconnect '$IMGROOT/etc/init.d/rcS'" 0
    check "image: server installed executable" [ -x "$IMGROOT/usr/bin/nest-ondevice" ]
    check "image: nosleep installed executable" [ -x "$IMGROOT/etc/init.d/nosleep" ]
    check "image: monitrc installed" [ -s "$IMGROOT/etc/monit.d/nest-ondevice.monitrc" ]
    check "image: nosleep runs as sh" sh -n "$IMGROOT/etc/init.d/nosleep"
else
    echo "== built image (skipped: ./build initramfs, or set NEST_INITRAMFS=path)"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
