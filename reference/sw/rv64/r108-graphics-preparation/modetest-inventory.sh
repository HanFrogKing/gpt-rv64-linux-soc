#!/bin/sh
# Future target only. Inventory without SETCRTC, planes, flips or test patterns.
set -eu
d=/opt/debian-graphics/usr
l=$d/lib/riscv64-linux-gnu
test -c /dev/dri/card0
test -f "$d/bin/modetest"
test -f "$l/ld-linux-riscv64-lp64d.so.1"
exec "$l/ld-linux-riscv64-lp64d.so.1" --library-path "$l" \
    "$d/bin/modetest" -M rv64lab -c -e -p
