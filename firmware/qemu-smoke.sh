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

echo "==> building .#nestQemuKernel"
K=$(nix build --impure .#nestQemuKernel --print-out-paths)
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
