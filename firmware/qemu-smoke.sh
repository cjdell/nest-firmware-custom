#!/usr/bin/env sh
# Boot the QEMU bring-up image and assert the server answers over HTTP.
#
# This does NOT flash or emulate the Nest: it builds the same 2.6.37 kernel
# tree + the same injected rootfs (server + /etc/init.d/nest-ondevice) for a
# RealView PB-A8, boots it under qemu-system-arm and hits the server through
# qemu's user-net port forwards. See firmware/README.md ("QEMU smoke test").
#
#   bash firmware/qemu-smoke.sh
#
# Requires NEST_ATTACK_DIR (or a NestDFUAttack/ checkout next to the flake).
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
: "${NEST_ATTACK_DIR:=$root/NestDFUAttack}"
export NEST_ATTACK_DIR

# Pre-flight: qemu forwards 18000/18082 from the guest to the host, so anything
# already listening there answers the checks below and the test proves nothing —
# it happily passes against a stale host-side nest-ondevice while qemu sits there
# unable to bind. Fail loudly instead. (This bit us: a leftover
# SERVER_PORT=18000 run made a whole smoke run pass vacuously.)
for p in 18000 18082; do
    if curl -s -m 1 -o /dev/null "http://127.0.0.1:$p/"; then
        echo "qemu-smoke: 127.0.0.1:$p already answers — stop whatever holds it first" >&2
        echo "  (a stale server would answer these checks; the guest never would)" >&2
        exit 1
    fi
done

echo "==> building .#nestQemuKernel"
# The filtered flake source, same as ./build (bin/flake-src.sh): the checkout
# itself is 1.3 GB and getFlake copies all of it.
flake=$(sh bin/flake-src.sh)
K=$(nix build --impure --no-link --print-out-paths \
    --expr "let f = builtins.getFlake \"$flake\"; in f.packages.$(uname -m)-linux.nestQemuKernel")
echo "    $K"

log=$(mktemp)
fifo=$(mktemp -u)
mkfifo "$fifo"
exec 9<>"$fifo" # hold a writer open so the guest's PID 1 never sees stdin EOF
echo "==> booting (console -> $log)"
"$K/run.sh" <"$fifo" >"$log" 2>&1 &
qpid=$!
trap 'kill "$qpid" 2>/dev/null || true; exec 9>&-; rm -f "$fifo"' EXIT

entry=""
i=0
while [ "$i" -lt 40 ]; do
    sleep 3
    entry=$(curl -s -m 2 http://127.0.0.1:18000/nest/entry 2>/dev/null || true)
    [ -n "$entry" ] && break
    i=$((i + 1))
done

health=$(curl -s -m 2 http://127.0.0.1:18082/health 2>/dev/null || true)
devices=$(curl -s -m 2 http://127.0.0.1:18082/api/devices 2>/dev/null || true)
dbg=$(curl -s -m 3 http://127.0.0.1:18082/debug/status 2>/dev/null || true)
rep=$(curl -s -m 5 http://127.0.0.1:18082/debug/report?n=5 2>/dev/null || true)

rc=0
check() {
    if printf '%s' "$3" | grep -q -- "$2"; then
        echo "PASS  $1"
    else
        echo "FAIL  $1"
        rc=1
    fi
}
check "GET /nest/entry"  'transport_url'  "$entry"
check "GET /health"      '"status":"ok"'  "$health"
check "GET /api/devices" '"devices"'      "$devices"
check "GET /debug/status" '"server":"nest-ondevice"' "$dbg"
check "GET /debug/report" '"system"' "$rep"

echo
echo "==> guest boot log (tail)"
tail -n 30 "$log"
exit "$rc"
