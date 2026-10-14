#!/usr/bin/env just --justfile
#
# nest — every common dev action in one self-describing file.
#
#   just                 list the recipes
#   just firmware        build the flashable image
#   just deploy          build the ARM server and hot-patch it onto the unit
#   just ui-dev          edit the SPA against a fake thermostat, no hardware
#
# `just --list` prints the line directly above each recipe, so that line is the
# summary and the lines above it are the receipts (the why), which is the
# convention the rest of this repo uses.
#
# Two rules this file obeys, both from AGENTS.md:
#   * `./build` stays the only build entry point — it knows native vs Apple
#     container vs remote x86_64, and the image is only reproducible through it.
#   * NestDFUAttack/ is an unpatched submodule (trap 22): nothing here writes
#     into it, so the DFU staging copy goes to a temp dir.
#
# Everything host-specific is a variable; override in the environment:
#   NEST_HOST=192.168.1.9 just device-status
#   NEST_BUILD_HOST=user@box just remote
#
# Deliberately no user-defined functions and no `set unstable`: just keeps
# functions behind --unstable, and variables are evaluated eagerly, so anything
# expensive (the sshpass lookup) is resolved inside the recipe that needs it.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Thermostat (DHCP reservation on the router, traps 16-17).
NEST_HOST := env_var_or_default("NEST_HOST", "192.168.1.2")
# Hubitat hub, static (trap 17).
HUB_HOST := env_var_or_default("HUBITAT_HOST", "192.168.1.3")
# Hubitat device id of the thermostat (hubitat/README.md).
HUB_DEVICE_ID := env_var_or_default("HUB_DEVICE_ID", "16")
# Diagnostic password baked into firmware/inject_initramfs.py; remove for real use.
NEST_PASS := env_var_or_default("NEST_PASS", "nestpass")
# Vendored DFU tree (submodule; read-only).
ATTACK := env_var_or_default("NEST_BUILD_ATTACK", justfile_directory() / "NestDFUAttack")
# Serial of the unit we pair with.
SERIAL := env_var_or_default("NEST_SERIAL", "02AA01AC2614065C")
# Both listeners share one router (src/server.rs:115), so the control port also
# serves /api/*, /command, /debug/* and the SPA.
CTL_PORT := env_var_or_default("CTL_PORT", "8082")
# The DFU loader shipped in the submodule is a 2008 i386 binary linked against
# libusb-0.1; point this at a host-built copy if you compiled one (see flash).
OMAP3_USBLOAD := env_var_or_default("OMAP3_USBLOAD", ATTACK / "Release/Linux/omap3_usbload")

# Password auth only; the unit is re-flashed often so known_hosts churns.
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=8 -o LogLevel=ERROR"

# sshpass from PATH, else borrowed from nixpkgs — inside the recipe, because a
# variable here would make every `just firmware` pay for a nix evaluation.
sshpass_sh := "sp=$(command -v sshpass 2>/dev/null || nix build --print-out-paths nixpkgs#sshpass 2>/dev/null | sed 's|$|/bin/sshpass|')"

base := "http://" + NEST_HOST + ":" + CTL_PORT
url_status := base + "/debug/status"
url_report := base + "/debug/report?n=200"
url_devices := base + "/api/devices"
url_schedule := base + "/api/schedule?serial=" + SERIAL
# jq is not installed everywhere (this host has none); python3 always is, since
# test_smoke.py needs it.
pretty := "jq -C . 2>/dev/null || python3 -m json.tool"
# Printed when a control-API call fails, so the failure is not a JSON parse error.
unreachable := "did not answer — touch the screen to wake it (trap 14), and check NEST_HOST/CTL_PORT"


# Show this list.
default:
    @just --list

# ---------------------------------------------------------------- build ----

# ~30 s on a native x86_64 host; the 2008 i686 toolchain runs natively there
# (trap 1) and under qemu-i386 everywhere else.
# Flashable kernel+initramfs -> dist/uImage (+ .sha256, .manifest).
[group('build')]
firmware:
    ./build firmware

# The ARM server binary (static armv7-unknown-linux-musleabi) -> dist/nest-ondevice.
[group('build')]
server:
    ./build server

# Just the patched initramfs cpio -> dist/initramfs.cpio.
[group('build')]
initramfs:
    ./build initramfs

# All three artifacts.
[group('build')]
all:
    ./build all

# Bun compiles src/ into ui/dist, which build.rs embeds; ui/dist is tracked
# because nix only sees git-tracked files (trap 30). Then `just server`.
# Rebuild the schedule SPA bundle, and the render test.
[group('build')]
ui:
    ./build ui

# The bundle rebuilds on browser refresh; ui/mock.ts can also simulate the dial
# clobbering your save or inventing setpoints while learning (curl lines are
# printed on start). DEV_PORT/DEV_SCALE/DEV_RANGE/DEV_EMPTY/DEV_LEARNING set it up.
# SPA dev server on a fake control API — no thermostat, no Rust server.
[group('build')]
ui_dev:
    ./build ui-dev

# What is in dist/, with checksums.
[group('build')]
status:
    ./build status

# Prove the image is host-independent (traps 20/23/24). Several full builds.
[group('build')]
repro:
    ./build repro

# From a Mac this is the only way to get the canonical digests (trap 23):
#   NEST_BUILD_HOST=user@host NEST_BUILD_ATTACK=~/nest/NestDFUAttack just remote
# Build on a remote native x86_64 Linux host and pull the artifacts back.
[group('build')]
remote:
    #!/usr/bin/env bash
    : "${NEST_BUILD_HOST:?set NEST_BUILD_HOST=user@x86_64-linux-host}"
    ./build all

# nix develop: cargo + python, no host toolchain needed.
[group('build')]
shell:
    ./build shell

# Remove dist/ (the nix store is left alone).
[group('build')]
clean:
    ./build clean

# ----------------------------------------------------------------- test ----

# Exercises firmware/rootfs-install.sh and the init script against fixtures.
# The on-device half of the image, against fixtures — no thermostat needed.
[group('test')]
test:
    ./build test

# Refuses to start if 18000/18082 already answer: a stale host server makes the
# whole smoke test pass vacuously (trap 21).
# Boot the image under qemu-system-arm (RealView PB-A8) and assert HTTP works.
[group('test')]
qemu:
    ./build qemu

# Host build + test_smoke.py: pairing, buckets, schedule push and its
# rejections, /debug/*, the SPA. Refuses to run on top of a live server (trap 21).
# The full protocol smoke test, 32 checks.
[group('test')]
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    if curl -sf -m 1 http://127.0.0.1:18000/info >/dev/null 2>&1 ||
        curl -sf -m 1 http://127.0.0.1:18082/debug/status >/dev/null 2>&1; then
        echo "smoke: something already answers on 18000/18082 — kill it first." >&2
        echo "       A stale server makes test_smoke.py pass without testing this build." >&2
        exit 1
    fi
    cargo build --release --manifest-path nest-ondevice-server/Cargo.toml
    dir=$(mktemp -d)
    # export, not a bare assignment: the next line is a different command, and a
    # shell variable that is not exported would not reach the server.
    export SERVER_PORT=18000 CONTROL_PORT=18082 API_ORIGIN=http://127.0.0.1:18000 DATA_DIR=$dir
    ./nest-ondevice-server/target/release/nest-ondevice >/tmp/nest-smoke-server.log 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true; rm -rf $dir' EXIT
    for _ in $(seq 100); do curl -sf http://127.0.0.1:18000/info >/dev/null && break; sleep 0.1; done
    python3 nest-ondevice-server/test_smoke.py

# tsc --noEmit, then the happy-dom render test: dict-of-dicts save, continuation
# entries, time snapping (24 assertions).
# UI checks: types, then the render test.
[group('test')]
ui_test:
    #!/usr/bin/env bash
    set -euo pipefail
    cd nest-ondevice-server/ui
    [ -d node_modules ] || npm ci
    ./node_modules/.bin/tsc --noEmit
    ./node_modules/.bin/bun run test/run.ts

# Everything that passes without a thermostat.
[group('test')]
check: ui_test smoke

# ---------------------------------------------------------------- device ----

#   just nssh 'uptime; tail -5 /media/log/messages'
# If it times out the display was asleep — touch the screen, then retry. Suspend
# is disabled persistently (trap 14), so this should be rare now.
# Run a command on the thermostat (password SSH, root only, no scp/sftp).
[group('device')]
nssh *command:
    #!/usr/bin/env bash
    set -euo pipefail
    {{sshpass_sh}}
    "$sp" -p {{NEST_PASS}} ssh {{ssh_opts}} root@{{NEST_HOST}} {{quote(command)}}

# The device has no scp/sftp, and `cat > file` onto a running binary is ETXTBSY,
# so write a sibling and rename over it.
# Stream a file onto the flash root (jffs2; survives reboot, no reflash needed).
[group('device')]
push src dst:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{src}}" ] || { echo "no such file: {{src}}" >&2; exit 1; }
    {{sshpass_sh}}
    cat "{{src}}" | "$sp" -p {{NEST_PASS}} ssh {{ssh_opts}} root@{{NEST_HOST}} \
        'cat > {{dst}}.new && chmod 755 {{dst}}.new && mv {{dst}}.new {{dst}} && sync'
    echo "pushed {{src}} -> {{dst}}"

# For iterating only: the flashed copy is untouched, so `just flash` restores it.
# Build the ARM server, hot-patch it onto the unit, restart the daemon.
[group('device')]
deploy: server
    just push dist/nest-ondevice /usr/bin/nest-ondevice
    just nssh '/etc/init.d/nest-ondevice restart; sleep 1; pgrep -af nest-ondevice | head -3'
    just device-status

# Restart just the daemon (monit supervises it, so crashes restart themselves).
[group('device')]
restart:
    just nssh '/etc/init.d/nest-ondevice restart; sleep 1; pgrep -af nest-ondevice | head -3'

# busybox init runs rcH, and boot is ~40 s — watch ping drop and return. On a
# pre-fix image rcH can sit in a ~6 min retry backoff (trap 15); then use
# just reboot_force.
# Graceful reboot.
[group('device')]
reboot:
    just nssh '/sbin/reboot' || echo "ssh died — normal during a reboot"

# Force reboot: sync() + reboot(2), skips rcH. The escape hatch for trap 15.
[group('device')]
reboot_force:
    just nssh '/sbin/reboot -f' || echo "ssh died — normal during a reboot"

# /debug/status: config, counters, subscriptions, RSS, uptime.
[group('device')]
device_status:
    #!/usr/bin/env bash
    set -euo pipefail
    body=$(curl -fsS --max-time 8 {{url_status}}) || { echo "device_status: {{url_status}} {{unreachable}}" >&2; exit 1; }
    printf '%s\n' "$body" | {{pretty}}

# /debug/report: status + logs + trace + dmesg + system + config in one bundle.
[group('device')]
report:
    #!/usr/bin/env bash
    set -euo pipefail
    curl -fsS --max-time 20 '{{url_report}}' || { echo "report: {{url_report}} {{unreachable}}" >&2; exit 1; }

# The daemon's own JSONL log on the flash root.
[group('device')]
logs:
    just nssh 'tail -n 60 /media/data/nest-ondevice/nest-ondevice.jsonl'

# syslog — syslogd writes /media/log/messages (/var/log is tmpfs on the device).
[group('device')]
syslog:
    just nssh 'tail -n 60 /media/log/messages'

# The installer's own record of what it changed and what it skipped — read this
# before debugging anything else after a flash (traps 11/14/15).
# What /etc/init.d/nest-ondevice-install did on first boot.
[group('device')]
install_log:
    just nssh 'cat /etc/nest-ondevice-install.log'

# If they are not 0 the radio sleeps with the display and the LAN server
# disappears (trap 14); /etc/init.d/nosleep is what keeps them at 0.
# The three pm_debug knobs must read 0 0 0.
[group('device')]
sleep_knobs:
    just nssh 'cat /sys/kernel/debug/pm_debug/enable_off_mode /sys/kernel/debug/pm_debug/sleep_while_idle /sys/kernel/debug/pm_debug/voltage_off_while_idle'

# monit's view: nlsleepd must be gone, nest-ondevice must be running.
[group('device')]
monit:
    just nssh 'monit summary; echo; monit status nest-ondevice 2>/dev/null | head -20'

# The schedule bucket as the device sees it (dict-of-dicts + revision/timestamp).
[group('device')]
schedule:
    #!/usr/bin/env bash
    set -euo pipefail
    body=$(curl -fsS --max-time 8 '{{url_schedule}}') || { echo "schedule: '{{url_schedule}}' {{unreachable}}" >&2; exit 1; }
    printf '%s\n' "$body" | {{pretty}}

# Which thermostat the server is talking to, and whether it is subscribed.
[group('device')]
devices:
    #!/usr/bin/env bash
    set -euo pipefail
    body=$(curl -fsS --max-time 8 {{url_devices}}) || { echo "devices: {{url_devices}} {{unreachable}}" >&2; exit 1; }
    printf '%s\n' "$body" | {{pretty}}

# ---------------------------------------------------------------- flash ----

# They go to $NEST_FLASH_DIR (default /tmp/nest-flash), never into the submodule
# (trap 22). Use this when the machine that can run the loader is not this one.
# Stage the three blobs the DFU loader wants, and print the command.
[group('flash')]
flash_stage: firmware
    #!/usr/bin/env bash
    set -euo pipefail
    stage=${NEST_FLASH_DIR:-/tmp/nest-flash}
    mkdir -p "$stage"
    cp "{{ATTACK}}/Release/Nest/x-load.bin" "{{ATTACK}}/Release/Nest/u-boot.bin" "$stage/"
    cp dist/uImage "$stage/uImage"
    sha256sum dist/uImage "$stage/uImage"
    echo
    echo "  staged in $stage :  x-load.bin  u-boot.bin  uImage (copied from dist/)"
    echo
    echo "  On a 32-bit-x86 Linux host with libusb-0.1 (what NestDFUAttack assumes):"
    echo "      sudo {{OMAP3_USBLOAD}} \\"
    echo "        -f $stage/x-load.bin -a 0x080100000 \\"
    echo "        -f $stage/u-boot.bin -a 0x080A00000 \\"
    echo "        -f $stage/uImage     -v -j 0x080100000"
    echo
    echo "  Hold the display 10-15 s to enter DFU, plug in USB, run it, release."
    echo "  The image boots from RAM; persistence comes from /etc/init.d/rootme on"
    echo "  first boot writing to mtdblock7 (trap 5). Then: just flash_check"

# The vendored binary is i386 + libusb-0.1, which modern x86_64 hosts cannot run
# (same class of problem as trap 1). Build one with `gcc -m32 -lusb` from
# NestDFUAttack/Dev/omap3_usbload/omap3_usbload.c, or set OMAP3_USBLOAD=…, or
# use `just flash_stage` and run the command on a machine that can.
# Stage and run the loader here. Preflight checks it can actually exec.
[group('flash')]
flash:
    #!/usr/bin/env bash
    set -euo pipefail
    stage=${NEST_FLASH_DIR:-/tmp/nest-flash}
    just flash_stage
    # Bounded probe: the vendored loader is i386, so the usual outcome here is
    # "cannot exec" — but a loader that hangs must not hang the recipe.
    if ! timeout 5 "{{OMAP3_USBLOAD}}" --help >/dev/null 2>&1; then
        echo "flash: {{OMAP3_USBLOAD}} did not run here in 5 s (i386 + libusb-0.1)." >&2
        echo "       See the recipe docstring; the staged blobs are ready either way." >&2
        exit 1
    fi
    echo
    echo "Put the Nest in DFU now: hold the display 10-15 s, then release."
    read -r -p "Press enter once it is on USB and in DFU mode… " _
    sudo "{{OMAP3_USBLOAD}}" \
        -f "$stage/x-load.bin" -a 0x080100000 \
        -f "$stage/u-boot.bin" -a 0x080A00000 \
        -f "$stage/uImage" -v -j 0x080100000
    echo "Loader done. Boot is ~40 s; then: just flash_check"

# Installer log, pm_debug knobs, listeners, daemon, the SPA, and the rcS
# sshconnect line that blocked rcS before trap 11 was fixed (expect 0).
# Post-flash proof, all of it read off the device.
[group('flash')]
flash_check:
    #!/usr/bin/env bash
    set -euo pipefail
    just install_log
    echo "--- pm_debug knobs (want 0 0 0)"; just sleep_knobs
    echo "--- listeners"; just nssh 'netstat -ltnp 2>/dev/null | grep -E "8000|8082|22"'
    echo "--- daemon"; just nssh 'pgrep -af nest-ondevice | head -3'
    echo "--- SPA served"; curl -fsS {{base}}/ | head -c 120; echo
    echo "--- sshconnect in rcS (trap 11): expect 0"
    just nssh 'grep -c sshconnect /etc/init.d/rcS || true'

# --------------------------------------------------------------- hubitat ----

# hubitat/*.groovy is the source of truth — never paste hub-UI edits back over
# them (trap 19).   just hub_push both   # app + driver
# Push the vendored Groovy to the hub (app 210 / driver 940).
[group('hubitat')]
hub_push what="driver":
    ./hubitat/push.sh {{what}}

#   HUB_TOKEN=… just hub_status
# Ask the hub what it thinks the thermostat is (needs the hub access token).
[group('hubitat')]
hub_status:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${HUB_TOKEN:?from hub-ui > Overview > Show Access Token; then HUB_TOKEN=… just hub_status}"
    curl -fsS -H "Authorization: Bearer $HUB_TOKEN" \
        "http://{{HUB_HOST}}:8080/device/{{HUB_DEVICE_ID}}/status" | {{pretty}}

# ------------------------------------------------------------------ nix ----

# The server through nix alone (needs no vendored trees): armv7 musl static.
[group('nix')]
nix_server:
    nix build --print-out-paths .#nest-ondevice

# The flake still evaluates on all three systems (firmware attr is Linux-only).
[group('nix')]
flake_check:
    nix flake check

# ----------------------------------------------------------------- meta -----

# What this host can and cannot do, and whether the unit is answering.
[group('meta')]
doctor:
    #!/usr/bin/env bash
    echo "host:      $(uname -sm)  (image bytes are host-arch dependent — trap 23)"
    for t in just bun cargo python3 curl jq nix sudo; do
        printf '%-10s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
    done
    [ -x nest-ondevice-server/ui/node_modules/.bin/bun ] &&
        echo "             (bun is vendored: nest-ondevice-server/ui/node_modules/.bin/bun)"
    echo "submodule: $(git -C NestDFUAttack rev-parse --short HEAD 2>/dev/null || echo 'not checked out — git submodule update --init NestDFUAttack')"
    echo "tree:      $(git rev-parse --short HEAD)$(git diff --quiet || echo -dirty)"
    echo -n "device:    "
    curl -fsS -m 2 {{url_status}} 2>/dev/null |
        python3 -c 'import json,sys; d=json.load(sys.stdin); p=d.get("proc",{}); c=d.get("counters",{}); print(p.get("rss_kb","?"),"KB rss,", c.get("subscriptions_total","?"),"subscription(s)")' 2>/dev/null ||
        echo "unreachable — touch the screen to wake it, then retry"

# dist/ listing with checksums (same as just status).
[group('meta')]
artifacts:
    @just status
