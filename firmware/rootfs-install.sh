#!/bin/sh
# rootfs-install.sh — make the persistent changes this image needs on the
# device's flash root (jffs2 on /dev/mtdblock7, which rootme mounts at /tmp/1).
#
# It is shipped inside the initramfs as /etc/init.d/nest-ondevice-install and
# called by the injected line in /etc/init.d/rootme, *before* rootme unmounts
# /tmp/1 and reboots (AGENTS.md trap 5: after the umount these writes would land
# in the initramfs tmpfs and vanish).
#
# Three constraints shape it:
#   * It runs blind. The files it edits are the factory Nest ones, which are not
#     in this repo (NestDFUAttack/Dev/root is an older dump with no nlsleep at
#     all), so nothing is rewritten from a template: edits are guarded by an
#     existence check and marked with DISABLED-by-nest-ondevice.
#   * It runs more than once. rootme is called from rcS, so anything booted
#     through the DFU image re-runs this; every operation is idempotent and
#     re-running is the recovery path for an interrupted flash.
#   * Nobody is watching. Decisions go to
#     /etc/nest-ondevice-install.log on the flash root, so whoever SSHes in can
#     see what the image actually did.
#
# NEST_ROOT points at the tree to install into; firmware/test-rootfs-install.sh
# and firmware/test-image.sh runs the whole thing against a fixture instead of a real thermostat.

NEST_ROOT=${NEST_ROOT:-/tmp/1}
# Where the files to install come from. On the device they are already unpacked
# at the initramfs root, so the paths are absolute; firmware/test-image.sh points
# this at a fixture directory instead.
NEST_SRC=${NEST_SRC:-}
NEST_MARK="DISABLED-by-nest-ondevice"
NEST_LOG="$NEST_ROOT/etc/nest-ondevice-install.log"

nest_log() {
    echo "nest-ondevice: $*" >> "$NEST_LOG" 2>/dev/null
    echo "nest-ondevice: $*"
}

nest_disable() {
    # nest_disable FILE SUBSTRING — comment out every not-yet-commented line
    # containing SUBSTRING, keeping its indentation. Marked so a re-run leaves
    # them alone, and substring-matched because this file is edited blind: a
    # regex written against a guess is how you break a boot script.
    file=$1
    pat=$2
    awk -v mark="#$NEST_MARK" -v pat="$pat" '
        {
            head = $0; sub(/[^ ].*$/, "", head)
            body = $0; sub(/^[ \t]*/, "", body)
            if (index(body, pat) && body !~ /^#/) body = mark " " body
            print head body
        }' "$file" > "$file.nle" 2>/dev/null && mv "$file.nle" "$file" 2>/dev/null
    rm -f "$file.nle" 2>/dev/null
}

nest_log "--- install into $NEST_ROOT"

if [ ! -d "$NEST_ROOT/etc/init.d" ]; then
    nest_log "ABORT: $NEST_ROOT/etc/init.d missing (flash root not mounted?)"
    exit 0
fi

# --- the server, its init script, its supervisor -----------------------------
mkdir -p "$NEST_ROOT/usr/bin" "$NEST_ROOT/etc/monit.d" 2>/dev/null

for f in /usr/bin/nest-ondevice /etc/init.d/nest-ondevice /etc/init.d/nosleep; do
    if [ -f "$NEST_SRC$f" ]; then
        cp "$NEST_SRC$f" "$NEST_ROOT$f" 2>/dev/null && chmod 755 "$NEST_ROOT$f" 2>/dev/null \
            || nest_log "WARN: could not install $f"
    else
        nest_log "WARN: $NEST_SRC$f missing from the initramfs"
    fi
done

if [ -f "$NEST_SRC/etc/monit.d/nest-ondevice.monitrc" ]; then
    cp "$NEST_SRC/etc/monit.d/nest-ondevice.monitrc" "$NEST_ROOT/etc/monit.d/nest-ondevice.monitrc" 2>/dev/null
fi

# monit reads /etc/monitrc at boot; without the include nothing supervises us.
if [ -f "$NEST_ROOT/etc/monitrc" ] && ! grep -q 'nest-ondevice.monitrc' "$NEST_ROOT/etc/monitrc"; then
    echo 'include /etc/monit.d/nest-ondevice.monitrc' >> "$NEST_ROOT/etc/monitrc"
    nest_log "monitrc: included nest-ondevice.monitrc"
fi

# --- rcS: unblock the boot, disable suspend, start the server ----------------
RCS="$NEST_ROOT/etc/init.d/rcS"
if [ -f "$RCS" ]; then
    # rootme appends /bin/sshconnect, an autossh loop that never returns, so
    # every line after it — including our start line — never runs. Drop it, then
    # keep a single /bin/dropbear. (AGENTS.md trap 11.)
    if grep -q '/bin/sshconnect' "$RCS"; then
        sed -i '/\/bin\/sshconnect/d' "$RCS"
        nest_log "rcS: removed the sshconnect loop that blocked rcS"
    fi
    awk '!(/^\/bin\/dropbear$/ && seen++)' "$RCS" > "$RCS.nle" 2>/dev/null \
        && mv "$RCS.nle" "$RCS" 2>/dev/null
    rm -f "$RCS.nle" 2>/dev/null

    # nlsleepd is what puts the SoC into RAM suspend when the display sleeps,
    # taking the Wi-Fi radio and the server with it. (AGENTS.md trap 14.)
    if grep -q 'nlsleep start' "$RCS"; then
        nest_disable "$RCS" "nlsleep start"
        nest_log "rcS: nlsleep start disabled"
    fi

    # Both lines are appended, so they run after the stock services; nosleep
    # first because it is what keeps the LAN server answerable later.
    if ! grep -q 'nosleep start' "$RCS"; then
        echo '${INITDIR}/nosleep start' >> "$RCS"
        nest_log "rcS: added nosleep start"
    fi
    if ! grep -q 'nest-ondevice start' "$RCS"; then
        echo '${INITDIR}/nest-ondevice start' >> "$RCS"
        nest_log "rcS: added nest-ondevice start"
    fi
else
    nest_log "note: no rcS at $RCS (nothing to start from)"
fi

# --- rcH: do not let shutdown hang in the monit retry loop -------------------
# rcH calls `${INITDIR}/nlsleep stop`, which goes through monit_service_action
# and retries for 1+3+9+27+81+243 s whenever `monit stop nlsleepd` fails — which
# it always does once nlsleepd is out of monit. The network stays up the whole
# time, so it looks like "reboot does nothing". (AGENTS.md trap 15.)
#
# Commenting the call here rather than editing nlsleep's `stop)` case is
# deliberate: nlsleep is a file we cannot read while writing this, and an
# `exit 0` inserted blind near its top would also end rcH if rcH sourced it.
# With nlsleepd unmonitored and never started there is nothing for it to stop.
RCH="$NEST_ROOT/etc/init.d/rcH"
if [ -f "$RCH" ] && grep -q 'nlsleep stop' "$RCH"; then
    nest_disable "$RCH" "nlsleep stop"
    nest_log "rcH: nlsleep stop disabled (would retry monit for ~6 minutes)"
fi

# --- monit: stop supervising nlsleepd ---------------------------------------
# Only that check: nlshutdownd lives in the same file and the shutdown path
# needs it, so deleting the file breaks power-off. (AGENTS.md trap 14.)
MON="$NEST_ROOT/etc/monit.d/nlscpm.monitrc"
if [ -f "$MON" ] && grep -q 'check process nlsleepd' "$MON"; then
    awk -v mark="#$NEST_MARK" '
        {
            if ($0 ~ /^[ \t]*check[ \t]+process[ \t]+nlsleepd([ \t]|$)/) { inblock = 1 }
            else if ($0 !~ /^[ \t]/) { inblock = 0 }
            if (inblock) {
                line = $0
                sub(/^[ \t]*/, "", line)
                if (line !~ /^#DISABLED-by-nest-ondevice/) line = mark " " line
                print line
            } else {
                print
            }
        }' "$MON" > "$MON.nle" 2>/dev/null && mv "$MON.nle" "$MON" 2>/dev/null
    rm -f "$MON.nle" 2>/dev/null
    nest_log "monit: nlsleepd checks disabled (nlshutdownd left alone)"
fi

# --- diagnostic root access ---------------------------------------------------
# The known-password root line this image is built with; AGENTS.md records the
# password. Drop this block before treating a flash as anything but diagnostic.
if [ -f "$NEST_ROOT/etc/shadow" ]; then
    grep -v '^root:' "$NEST_ROOT/etc/shadow" > "$NEST_ROOT/etc/shadow.nle" 2>/dev/null
    echo 'root:neID3wejfFjiA:16243:0:99999:7:::' >> "$NEST_ROOT/etc/shadow.nle"
    mv "$NEST_ROOT/etc/shadow.nle" "$NEST_ROOT/etc/shadow" 2>/dev/null
    chmod 600 "$NEST_ROOT/etc/shadow" 2>/dev/null
    nest_log "shadow: root set to the diagnostic password"
fi

# jffs2 plus an imminent reboot: without this the writes may still be buffered
# when rootme calls reboot.
sync 2>/dev/null
nest_log "--- done"
exit 0
