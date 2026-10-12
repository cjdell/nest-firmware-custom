#!/bin/sh
# QEMU-only bring-up init (passed as rdinit=/qemu-init). NOT part of the
# shipped firmware — the real device runs /etc/init.d/rcS.
#
# The Nest rcS path probes hardware that does not exist under qemu (mtdblock7,
# tiwlan, the OMAP watchdog) and etc/init.d/rootme reboots on boot, so this
# script skips it and just brings up the server. Everything else (kernel tree,
# rootfs, the injected server binary and its init script) is the real thing.
#
# Networking note: qemu's realview-pb-a8 only models a lan9118 (smsc911x), but
# the 2.6.37 realview_pba8.c board file instantiates the smc91x AMBA device, so
# no NIC driver binds. The server is therefore exercised over the guest's
# loopback, which needs no hardware.
/bin/sleep 2
/bin/mount -t proc proc /proc 2>/dev/null
/bin/mount -t sysfs sysfs /sys 2>/dev/null

echo "=== nest-ondevice qemu bring-up ==="
cat /proc/version
/bin/grep -E "Processor|Features" /proc/cpuinfo | head -2

# ifconfig/route live in /sbin on this rootfs (busybox symlinks), not /bin.
/sbin/ifconfig lo 127.0.0.1 up
# qemu user-net default subnet (10.0.2.0/24) so the host can also reach the
# server through -nic hostfwd; the loopback self-test below works either way.
/sbin/ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up
/sbin/route add default gw 10.0.2.2
echo "--- interfaces ---"
/sbin/ifconfig -a

mkdir -p /media/data/nest-ondevice 2>/dev/null
API_ORIGIN=http://127.0.0.1:8000 \
SERVER_PORT=8000 \
CONTROL_PORT=8082 \
DATA_DIR=/media/data/nest-ondevice \
REQUIRE_DEVICE_PAIRING=false \
/usr/bin/nest-ondevice >/tmp/nest-ondevice.log 2>&1 &
SRV=$!
echo "=== nest-ondevice pid $SRV ==="
/bin/sleep 2
echo "--- /tmp/nest-ondevice.log ---"
cat /tmp/nest-ondevice.log

if kill -0 "$SRV" 2>/dev/null; then
    echo "=== SERVER ALIVE ==="
else
    echo "=== SERVER DIED ==="
fi

# The rootfs's /usr/bin/curl is dynamically linked against libcurl.so.4, which
# is not in the initramfs, so speak HTTP/1.0 over busybox nc instead.
http_get() {
    printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n' "$2" | /usr/bin/nc -w 3 127.0.0.1 "$1"
}

echo "--- GET /nest/entry (device port 8000) ---"
http_get 8000 /nest/entry
echo
echo "--- GET /health (control port 8082) ---"
http_get 8082 /health
echo
echo "--- GET /api/devices (control port 8082) ---"
http_get 8082 /api/devices
echo
echo "--- GET /debug/status (control port 8082) ---"
http_get 8082 /debug/status
echo
echo "--- GET /debug/report (control port 8082) ---"
http_get 8082 /debug/report?n=5
echo
echo "=== SELF-TEST DONE — dropping to shell (PID 1) ==="
exec /bin/sh
